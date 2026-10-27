package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// RPCError preserves app-server error codes and structured diagnostic data.
type RPCError struct {
	Code    int
	Message string
	Data    any
}

func (e *RPCError) Error() string { return fmt.Sprintf("Codex app-server (%d): %s", e.Code, e.Message) }

type rpcReply struct {
	result Map
	err    error
}
type LaunchOptions struct {
	Executable, Cwd              string
	Environment, ConfigOverrides []string
	Dispose                      func() error
	Identity                     string
	Version                      string
}

// AppServer owns one native Codex process group and its JSONL channel. Each
// thread uses an independent server so native configuration cannot leak across
// provider, exclusive-tool or permission boundaries.
type AppServer struct {
	mu                 sync.Mutex
	writeSlot          chan struct{}
	cmd                *exec.Cmd
	stdin              io.WriteCloser
	pending            map[string]chan rpcReply
	next               uint64
	closed             bool
	terminalErr        error
	exited             chan struct{}
	notifications      chan Map
	done               chan struct{}
	closeOnce          sync.Once
	cleanupOnce        sync.Once
	launch             LaunchOptions
	stderr             string
	handler            func(string, Map, any)
	onExit             func(error)
	initialized        Map
	terminateOnce      sync.Once
	terminated         chan struct{}
	terminateErr       error
	stdout, stderrPipe io.ReadCloser
}

func StartAppServer(ctx context.Context, opt LaunchOptions) (*AppServer, error) {
	transferred := false
	defer func() {
		// Prepared isolated homes already contain copied configuration/auth.
		// Until an AppServer owns them, every startup exit must dispose them.
		if !transferred && opt.Dispose != nil {
			_ = opt.Dispose()
		}
	}()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	args := []string{}
	for _, o := range opt.ConfigOverrides {
		args = append(args, "-c", o)
	}
	args = append(args, "app-server", "--listen", "stdio://")
	cmd := exec.Command(opt.Executable, args...)
	cmd.Dir = opt.Cwd
	cmd.Env = opt.Environment
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, stdoutWriter, err := os.Pipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	stderr, stderrWriter, err := os.Pipe()
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stdoutWriter.Close()
		return nil, err
	}
	cmd.Stdout = stdoutWriter
	cmd.Stderr = stderrWriter

	s := &AppServer{cmd: cmd, stdin: stdin, writeSlot: make(chan struct{}, 1), pending: map[string]chan rpcReply{}, exited: make(chan struct{}), notifications: make(chan Map, 4096), done: make(chan struct{}), launch: opt, terminated: make(chan struct{}), stdout: stdout, stderrPipe: stderr}
	transferred = true
	if err = cmd.Start(); err != nil {
		_ = stdoutWriter.Close()
		_ = stderrWriter.Close()
		_ = stdout.Close()
		_ = stderr.Close()
		_ = stdin.Close()
		s.cleanup()
		return nil, err
	}
	_ = stdoutWriter.Close()
	_ = stderrWriter.Close()
	readDone := make(chan struct{})
	errDone := make(chan struct{})
	go func() {
		defer close(readDone)
		defer stdout.Close()
		scan := bufio.NewScanner(stdout)
		scan.Buffer(make([]byte, 64*1024), 16*1024*1024)
		for scan.Scan() {
			var frame Map
			if e := json.Unmarshal(scan.Bytes(), &frame); e != nil {
				s.fail(fmt.Errorf("invalid Codex JSONL frame: %w", e))
				continue
			}
			s.route(frame)
		}
		if e := scan.Err(); e != nil {
			s.fail(e)
		}
	}()
	go func() {
		defer close(errDone)
		defer stderr.Close()
		b := make([]byte, 8192)
		for {
			n, e := stderr.Read(b)
			if n > 0 {
				s.mu.Lock()
				s.stderr = tail(s.stderr+string(b[:n]), 32*1024)
				s.mu.Unlock()
			}
			if e != nil {
				return
			}
		}
	}()
	go func() {
		e := cmd.Wait()
		// Exit can leave descendants holding inherited pipes. Retire the whole
		// owned group before draining; wait never depends on their pipe lifetime.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		drained := make(chan struct{})
		go func() { <-readDone; <-errDone; close(drained) }()
		select {
		case <-drained:
		case <-time.After(2 * time.Second):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			_ = stdout.Close()
			_ = stderr.Close()
			<-drained
		}
		s.mu.Lock()
		detail := strings.TrimSpace(s.stderr)
		s.mu.Unlock()
		if e == nil {
			e = errors.New("Codex app-server exited")
		}
		if detail != "" {
			e = fmt.Errorf("%w: %s", e, detail)
		}
		select {
		case s.notifications <- Map{"method": "_mokusei/processExit", "params": Map{"message": e.Error()}}:
		case <-s.done:
		}
		close(s.exited)
	}()
	go func() {
		for {
			select {
			case f := <-s.notifications:
				if f["method"] == "_mokusei/processExit" {
					s.fail(errors.New(str(obj(f["params"])["message"])))
					return
				}
				s.mu.Lock()
				h := s.handler
				s.mu.Unlock()
				if h != nil {
					h(str(f["method"]), obj(f["params"]), f["id"])
				}
			case <-s.done:
				return
			}
		}
	}()
	initCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	s.initialized, err = s.Call(initCtx, "initialize", Map{"clientInfo": Map{"name": "mokusei_desktop", "title": "Mokusei", "version": "0.2.0"}, "capabilities": Map{"experimentalApi": true, "requestAttestation": false, "extensions": Map{"openai/form": Map{}}}})
	if err == nil {
		err = s.Notify("initialized", nil)
	}
	if err != nil {
		_ = s.Close()
		return nil, err
	}
	return s, nil
}
func (s *AppServer) SetHandler(h func(string, Map, any), onExit func(error)) {
	s.mu.Lock()
	s.handler = h
	s.onExit = onExit
	err := s.terminalErr
	s.mu.Unlock()
	if err != nil && onExit != nil {
		onExit(err)
	}
}
func (s *AppServer) route(f Map) {
	if _, ok := f["method"]; ok {
		select {
		case s.notifications <- f:
		case <-s.done:
		default:
			s.fail(errors.New("Codex notification queue exceeded bound"))
			_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGTERM)
		}
		return
	}
	id := wireKey(f["id"])
	s.mu.Lock()
	ch := s.pending[id]
	delete(s.pending, id)
	s.mu.Unlock()
	if ch == nil {
		return
	}
	reply := rpcReply{result: obj(f["result"])}
	if e, ok := f["error"].(map[string]any); ok {
		reply.err = &RPCError{Code: int(num(e["code"])), Message: str(e["message"]), Data: e["data"]}
	}
	ch <- reply
}
func wireKey(v any) string {
	switch x := v.(type) {
	case string:
		return "s:" + x
	case float64:
		return "n:" + strconv.FormatFloat(x, 'f', -1, 64)
	case uint64:
		return "n:" + strconv.FormatUint(x, 10)
	case int:
		return "n:" + strconv.Itoa(x)
	case json.Number:
		return "n:" + string(x)
	}
	return ""
}
func (s *AppServer) Call(ctx context.Context, method string, params any) (Map, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if _, ok := ctx.Deadline(); !ok {
		var c context.CancelFunc
		ctx, c = context.WithTimeout(ctx, 30*time.Second)
		defer c()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	if s.closed {
		e := s.terminalErr
		s.mu.Unlock()
		return nil, e
	}
	s.next++
	id := s.next
	key := wireKey(id)
	ch := make(chan rpcReply, 1)
	s.pending[key] = ch
	s.mu.Unlock()
	if err := s.writeContext(ctx, Map{"id": id, "method": method, "params": params}); err != nil {
		s.mu.Lock()
		delete(s.pending, key)
		s.mu.Unlock()
		return nil, err
	}
	select {
	case r := <-ch:
		return r.result, r.err
	case <-ctx.Done():
		s.mu.Lock()
		delete(s.pending, key)
		s.mu.Unlock()
		return nil, ctx.Err()
	}
}
func (s *AppServer) Notify(method string, params any) error {
	m := Map{"method": method}
	if params != nil {
		m["params"] = params
	}
	return s.write(m)
}
func (s *AppServer) Reply(id any, result Map, err error) error {
	m := Map{"id": id}
	if err != nil {
		code := -32000
		var rpc *RPCError
		if errors.As(err, &rpc) {
			code = rpc.Code
		}
		m["error"] = Map{"code": code, "message": err.Error()}
	} else {
		m["result"] = result
	}
	return s.write(m)
}
func (s *AppServer) write(v Map) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return s.writeContext(ctx, v)
}
func (s *AppServer) writeContext(ctx context.Context, v Map) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	select {
	case s.writeSlot <- struct{}{}:
		defer func() { <-s.writeSlot }()
	case <-ctx.Done():
		return ctx.Err()
	case <-s.done:
		s.mu.Lock()
		defer s.mu.Unlock()
		return s.terminalErr
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	closed := s.closed
	err := s.terminalErr
	s.mu.Unlock()
	if closed {
		return err
	}
	b = append(b, '\n')
	// Native stdin is an os.Pipe. Interrupt a blocked write with its deadline
	// so cancellation cannot retire a frame that already completed in full.
	deadline, supportsDeadline := s.stdin.(interface{ SetWriteDeadline(time.Time) error })
	cancelled := make(chan struct{})
	closedOnCancel := false
	stop := context.AfterFunc(ctx, func() {
		if !supportsDeadline || deadline.SetWriteDeadline(time.Now()) != nil {
			closedOnCancel = true
			_ = s.stdin.Close()
		}
		close(cancelled)
	})
	written, e := s.stdin.Write(b)
	if !stop() {
		<-cancelled
		if closedOnCancel || written != len(b) || e != nil {
			e = ctx.Err()
		} else {
			e = deadline.SetWriteDeadline(time.Time{})
		}
	}
	if e == nil && written != len(b) {
		e = io.ErrShortWrite
	}
	if e != nil {
		s.fail(e)
	}
	return e
}
func (s *AppServer) fail(e error) {
	s.closeOnce.Do(func() {
		s.mu.Lock()
		s.closed = true
		s.terminalErr = e
		pending := s.pending
		s.pending = map[string]chan rpcReply{}
		callback := s.onExit
		s.mu.Unlock()
		for _, ch := range pending {
			ch <- rpcReply{err: e}
		}
		close(s.done)
		if callback != nil {
			go callback(e)
		}
		go s.terminate()
	})
}
func (s *AppServer) cleanup() {
	s.cleanupOnce.Do(func() {
		if s.launch.Dispose != nil {
			_ = s.launch.Dispose()
		}
	})
}
func (s *AppServer) terminate() error {
	s.terminateOnce.Do(func() {
		defer close(s.terminated)
		_ = s.stdin.Close()
		pid := s.cmd.Process.Pid
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		select {
		case <-s.exited:
		case <-time.After(2 * time.Second):
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			select {
			case <-s.exited:
			case <-time.After(2 * time.Second):
				_ = s.stdout.Close()
				_ = s.stderrPipe.Close()
				s.terminateErr = errors.New("Codex app-server process did not exit")
			}
		}
		if s.terminateErr == nil {
			s.terminateErr = processgroup.DrainAfterExit(pid)
		}
		if s.terminateErr == nil {
			s.cleanup()
		}
	})
	<-s.terminated
	return s.terminateErr
}
func (s *AppServer) Close() error {
	s.fail(errors.New("Codex app-server closed"))
	return s.terminate()
}
