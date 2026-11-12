package embedding

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

type NativeOptions struct {
	Executable, ModelDirectory string
	IdleTimeout                time.Duration
}

type Native struct {
	options            NativeOptions
	ctx                context.Context
	cancel             context.CancelFunc
	done               chan struct{}
	queries, documents chan job
	retry              chan struct{}
	mu                 sync.Mutex
	descriptor         Descriptor
	status             Status
	closeErr           error
}

type job struct {
	ctx   context.Context
	kind  Kind
	texts []string
	done  chan answer
}
type answer struct {
	vectors [][]float32
	err     error
}

func NewNative(ctx context.Context, options NativeOptions) *Native {
	if options.IdleTimeout <= 0 {
		options.IdleTimeout = 90 * time.Second
	}
	life, cancel := context.WithCancel(ctx)
	n := &Native{options: options, ctx: life, cancel: cancel, done: make(chan struct{}),
		queries: make(chan job, 16), documents: make(chan job, 1), retry: make(chan struct{}, 1),
		status: Status{Phase: "preparing"}}
	go n.run()
	return n
}
func (n *Native) Descriptor() Descriptor { n.mu.Lock(); defer n.mu.Unlock(); return n.descriptor }
func (n *Native) Status() Status         { n.mu.Lock(); defer n.mu.Unlock(); return n.status }
func (n *Native) Retry() {
	select {
	case n.retry <- struct{}{}:
	default:
	}
}
func (n *Native) Close() error { n.cancel(); <-n.done; return n.closeErr }
func (n *Native) Embed(ctx context.Context, kind Kind, texts []string) ([][]float32, error) {
	if !n.Status().Ready {
		return nil, ErrNotReady
	}
	if kind != Query && kind != Document || len(texts) == 0 || len(texts) > 4 {
		return nil, errors.New("invalid embedding batch")
	}
	limit := n.Descriptor().DocumentBytes
	if kind == Query {
		limit = 4096
	}
	for _, text := range texts {
		if strings.TrimSpace(text) == "" || len(text) > limit {
			return nil, errors.New("embedding input exceeds its byte budget")
		}
	}
	request := job{ctx, kind, append([]string(nil), texts...), make(chan answer, 1)}
	queue := n.documents
	if kind == Query {
		queue = n.queries
	}
	select {
	case queue <- request:
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-n.ctx.Done():
		return nil, n.ctx.Err()
	}
	select {
	case response := <-request.done:
		return response.vectors, response.err
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-n.ctx.Done():
		return nil, n.ctx.Err()
	}
}
func (n *Native) update(status Status) { n.mu.Lock(); n.status = status; n.mu.Unlock() }

func (n *Native) run() {
	defer close(n.done)
	var process *nativeProcess
	stop := func() error {
		if process == nil {
			return nil
		}
		err := process.close()
		process = nil
		return err
	}
	defer func() { n.closeErr = errors.Join(n.closeErr, stop()) }()
	prepare := func() error {
		if err := stop(); err != nil {
			return err
		}
		n.update(Status{Phase: "preparing"})
		var err error
		process, err = n.start()
		if err != nil {
			return err
		}
		_, err = process.call("prepare", "", nil, 11*time.Minute)
		if err == nil {
			n.update(Status{Phase: "idle", Ready: true})
		}
		return err
	}
	backoff := 5 * time.Second
	retryAt := time.Time{}
	fail := func(err error) {
		cleanup := stop()
		n.update(Status{Phase: "failed", Reason: failureCode(err)})
		if cleanup != nil {
			n.closeErr = cleanup
			n.cancel()
		}
		retryAt = time.Now().Add(backoff)
		backoff = min(5*time.Minute, backoff*2)
	}
	if err := prepare(); err != nil {
		fail(err)
	}
	lastUse := time.Now()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	var background *job
	for {
		var request job
		// One short native batch is non-preemptible. At each boundary, queued
		// queries get admission before any further background passage batch.
		select {
		case request = <-n.queries:
		default:
		}
		if request.done == nil && background != nil {
			request = *background
			background = nil
		}
		if request.done == nil {
			select {
			case <-n.ctx.Done():
				return
			case request = <-n.queries:
			case request = <-n.documents:
			case <-n.retry:
				if !n.Status().Ready {
					retryAt = time.Now()
				}
				continue
			case <-ticker.C:
				if !n.Status().Ready && !time.Now().Before(retryAt) {
					if err := prepare(); err != nil {
						fail(err)
					} else {
						backoff = 5 * time.Second
						lastUse = time.Now()
					}
				} else if process != nil && time.Since(lastUse) >= n.options.IdleTimeout {
					if err := stop(); err != nil {
						fail(err)
					} else {
						n.update(Status{Phase: "idle", Ready: true})
					}
				}
				continue
			}
		}
		if request.kind == Document {
			select {
			case priority := <-n.queries:
				waiting := request
				background, request = &waiting, priority
			default:
			}
		}
		if err := request.ctx.Err(); err != nil {
			request.done <- answer{err: err}
			continue
		}
		if !n.Status().Ready {
			request.done <- answer{err: ErrNotReady}
			continue
		}
		if process == nil {
			if err := prepare(); err != nil {
				fail(err)
				request.done <- answer{err: err}
				continue
			}
		}
		response, err := process.call("embed", request.kind, request.texts, 60*time.Second)
		lastUse = time.Now()
		if err == nil {
			err = validateVectors(response.Vectors, len(request.texts), n.Descriptor().Dimensions)
		}
		if err != nil {
			fail(err)
		}
		if request.ctx.Err() != nil {
			err = request.ctx.Err()
		}
		request.done <- answer{response.Vectors, err}
	}
}

type nativeEvent struct {
	ID             int         `json:"id"`
	Event          string      `json:"event"`
	Descriptor     *Descriptor `json:"descriptor"`
	Phase          string      `json:"phase"`
	CompletedBytes int64       `json:"completedBytes"`
	TotalBytes     int64       `json:"totalBytes"`
	Vectors        [][]float32 `json:"vectors"`
	Error          string      `json:"error"`
}
type nativeProcess struct {
	owner    *Native
	command  *exec.Cmd
	cancel   context.CancelFunc
	input    io.WriteCloser
	output   io.ReadCloser
	events   chan nativeEvent
	readDone chan struct{}
	wait     chan error
	id       int
}

func (n *Native) start() (*nativeProcess, error) {
	ctx, cancel := context.WithCancel(n.ctx)
	command := exec.CommandContext(ctx, n.options.Executable, "--model-directory", n.options.ModelDirectory)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGTERM) }
	command.WaitDelay = time.Second
	input, err := command.StdinPipe()
	if err != nil {
		cancel()
		return nil, err
	}
	output, err := command.StdoutPipe()
	if err != nil {
		input.Close()
		cancel()
		return nil, err
	}
	// The protocol carries stable failure codes. Never retain model input or
	// unbounded native-library diagnostics in application state.
	command.Stderr = io.Discard
	if err = command.Start(); err != nil {
		input.Close()
		output.Close()
		cancel()
		return nil, err
	}
	p := &nativeProcess{owner: n, command: command, cancel: cancel, input: input, output: output,
		events: make(chan nativeEvent, 2), readDone: make(chan struct{}), wait: make(chan error, 1)}
	go func() { p.wait <- command.Wait() }()
	go func() {
		defer close(p.readDone)
		defer close(p.events)
		scanner := bufio.NewScanner(output)
		// Four vectors at the descriptor's 4,096-dimension ceiling must fit
		// without coupling the protocol budget to Gemma's current 768 outputs.
		scanner.Buffer(make([]byte, 4096), 512*1024)
		for scanner.Scan() {
			var event nativeEvent
			decoder := json.NewDecoder(strings.NewReader(scanner.Text()))
			decoder.DisallowUnknownFields()
			if decoder.Decode(&event) != nil {
				return
			}
			if event.Event == "status" {
				switch event.Phase {
				case "downloading", "verifying", "loading", "idle", "ready":
				default:
					return
				}
				state := n.Status()
				state.Phase, state.CompletedBytes, state.TotalBytes = event.Phase, event.CompletedBytes, event.TotalBytes
				n.update(state)
				continue
			}
			select {
			case p.events <- event:
			case <-ctx.Done():
				return
			}
		}
	}()
	helloCtx, helloCancel := context.WithTimeout(ctx, 10*time.Second)
	defer helloCancel()
	hello, err := p.receive(helloCtx)
	if err == nil && (hello.Event != "hello" || hello.Descriptor == nil) {
		err = errors.New("invalid embedding handshake")
	}
	if err == nil {
		d := *hello.Descriptor
		if d.Space == "" || len(d.Space) > 512 || d.Name == "" || len(d.Name) > 128 || d.Dimensions < 1 || d.Dimensions > 4096 || d.DocumentBytes < 256 || d.DocumentBytes > 8192 {
			err = errors.New("invalid embedding descriptor")
		} else {
			n.mu.Lock()
			if n.descriptor.Space != "" && n.descriptor != d {
				err = errors.New("embedding descriptor changed within one provider")
			} else {
				n.descriptor = d
			}
			n.mu.Unlock()
		}
	}
	if err != nil {
		return nil, errors.Join(err, p.close())
	}
	return p, nil
}
func (p *nativeProcess) receive(ctx context.Context) (nativeEvent, error) {
	select {
	case event, ok := <-p.events:
		if !ok {
			return nativeEvent{}, errors.New("embedding process ended before its response")
		}
		return event, nil
	case <-ctx.Done():
		return nativeEvent{}, ctx.Err()
	}
}
func (p *nativeProcess) call(operation string, kind Kind, texts []string, timeout time.Duration) (nativeEvent, error) {
	p.id++
	ctx, cancel := context.WithTimeout(p.owner.ctx, timeout)
	defer cancel()
	request := struct {
		ID        int      `json:"id"`
		Operation string   `json:"operation"`
		Kind      Kind     `json:"kind,omitempty"`
		Texts     []string `json:"texts,omitempty"`
	}{p.id, operation, kind, texts}
	if err := json.NewEncoder(p.input).Encode(request); err != nil {
		return nativeEvent{}, err
	}
	event, err := p.receive(ctx)
	if err != nil {
		return event, err
	}
	if event.Event != "result" || event.ID != p.id {
		return event, errors.New("invalid embedding response identity")
	}
	if event.Error != "" {
		return event, modelError(event.Error)
	}
	return event, nil
}
func (p *nativeProcess) close() error {
	p.input.Close()
	// Idle retirement lets the helper close the engine and its caches first.
	// A blocked native call still has a bounded process-group cancellation path.
	select {
	case <-p.wait:
	case <-time.After(500 * time.Millisecond):
		p.cancel()
		<-p.wait
	}
	p.cancel()
	p.output.Close()
	<-p.readDone
	return processgroup.DrainAfterExit(p.command.Process.Pid)
}

type modelError string

func (e modelError) Error() string { return string(e) }
func failureCode(err error) string {
	var failure modelError
	if errors.As(err, &failure) {
		switch failure {
		case "download-failed", "model-checksum", "model-load-failed", "embedding-failed", "invalid-input", "invalid-vector":
			return string(failure)
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "model-timeout"
	}
	return "model-unavailable"
}
func validateVectors(vectors [][]float32, count, dimensions int) error {
	if len(vectors) != count {
		return errors.New("embedding vector count mismatch")
	}
	for _, vector := range vectors {
		if len(vector) != dimensions {
			return errors.New("embedding vector dimension mismatch")
		}
		var norm float64
		for _, value := range vector {
			v := float64(value)
			if math.IsNaN(v) || math.IsInf(v, 0) {
				return errors.New("non-finite embedding")
			}
			norm += v * v
		}
		if math.Abs(norm-1) > .01 {
			return fmt.Errorf("embedding is not normalized")
		}
	}
	return nil
}
