// Independent source and production Runtime/HTTP host for the foreground CI replay.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

type options struct {
	ready, output, condition string
	warmup, seconds          float64
	seed                     int64
	parentPID                int
}

type schedule struct {
	SourceProtocolVersion     int     `json:"sourceProtocolVersion"`
	SourceQueueCapacity       int     `json:"sourceQueueCapacity"`
	WarmupStartUnixNano       int64   `json:"warmupStartUnixNano"`
	FormalStartUnixNano       int64   `json:"formalStartUnixNano"`
	FormalEndUnixNano         int64   `json:"formalEndUnixNano"`
	WarmupSeconds             float64 `json:"warmupSeconds"`
	FormalSeconds             float64 `json:"formalSeconds"`
	SourceIntervalNanoseconds int64   `json:"sourceIntervalNanoseconds"`
}

type benchmark struct {
	options      options
	db           *store.Store
	adapter      plugin.SessionStateAdapter
	origin       time.Time
	ctx          context.Context
	cancel       context.CancelFunc
	mu           sync.Mutex
	state        string
	schedule     *schedule
	records      []model.ThreadRecord
	expected     []cardExpectation
	events       []sourceEvent
	publications []publication
	boundaries   map[string]boundary
	errors       []string
	sourceDone   bool
	enqueueDone  bool
	producerDone bool
	inputQueue   *sourceQueue
	wireOverhead int
	workers      sync.WaitGroup
	warmupReady  chan struct{}
	finish       chan struct{}
	finishOnce   sync.Once
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() (returned error) {
	var o options
	flag.StringVar(&o.ready, "ready-file", "", "private ready JSON written once the production server is available")
	flag.StringVar(&o.output, "output", "", "final Core evidence JSON")
	flag.StringVar(&o.condition, "condition", "", "R0, S4 rewrite, or A4 cumulative message update")
	flag.Float64Var(&o.warmup, "warmup", 5, "source warmup seconds")
	flag.Float64Var(&o.seconds, "seconds", 20, "formal seconds")
	flag.Int64Var(&o.seed, "seed", 198, "nonnegative deterministic public fixture seed")
	flag.IntVar(&o.parentPID, "parent-pid", os.Getppid(), "owning Swift process; exit if its parent relationship is lost")
	flag.Parse()
	if !filepath.IsAbs(o.ready) || !filepath.IsAbs(o.output) || o.ready == o.output || flag.NArg() != 0 {
		return errors.New("--ready-file and --output must be distinct absolute paths")
	}
	if (o.condition != "R0" && o.condition != "S4" && o.condition != "A4") || o.seed < 0 || o.parentPID <= 1 {
		return errors.New("invalid condition, seed, or parent PID")
	}
	if o.warmup != 5 || o.seconds != 20 {
		return errors.New("this evidence contract fixes warmup=5 and seconds=20")
	}
	if err := os.MkdirAll(filepath.Dir(o.output), 0700); err != nil {
		return err
	}
	root, err := os.MkdirTemp(filepath.Dir(o.output), "overview-core-profile-")
	if err != nil {
		return err
	}
	defer func() { returned = errors.Join(returned, os.RemoveAll(root)) }()
	workspace := filepath.Join(root, "overview-workspace")
	if err := os.Mkdir(workspace, 0700); err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	ctx, lifetimeCancel := context.WithTimeout(ctx, 2*time.Minute)
	defer lifetimeCancel()
	b := &benchmark{options: o, ctx: ctx, cancel: lifetimeCancel, origin: time.Now(), state: "idle",
		boundaries: make(map[string]boundary), errors: []string{}, warmupReady: make(chan struct{}), finish: make(chan struct{})}
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(root, "data"), HomeDir: root})
	if err != nil {
		return err
	}
	owner, err := profile.Acquire(p)
	if err != nil {
		return err
	}
	defer func() { returned = errors.Join(returned, owner.Release()) }()
	db, err := store.Open(filepath.Join(p.DataDir, "state.sqlite"))
	if err != nil {
		return err
	}
	defer func() { returned = errors.Join(returned, db.Close()) }()
	b.db = db
	// Discovery normally scans applications as well as PATH. An explicit missing
	// capability prevents this synthetic replay from opening a real provider or
	// reading a user's credentials, while settings requests keep their real route.
	adapter := codex.New(plugin.HostContext{Environment: func(context.Context) (map[string]string, error) {
		return nil, errors.New("Overview CI synthetic source has no external Codex environment")
	}, HarnessDataRoot: filepath.Join(root, "harness"), TemporaryWorkspaceRoot: filepath.Join(root, "workspaces")})
	b.adapter = adapter.SessionState()
	b.records, err = seedStore(ctx, db, workspace, adapter)
	if err != nil {
		return err
	}
	if err := b.prepareExpectations(); err != nil {
		return err
	}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"codex": adapter},
		DataDir: p.DataDir, DefaultCwd: workspace, Plugins: []model.RuntimePlugin{{Key: "harness:codex", Enabled: true}},
		Log: func(kind string, err error) { b.fail(kind + ": " + err.Error()) }})
	if err != nil {
		return err
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		returned = errors.Join(returned, r.Close(cleanup))
	}()
	epoch := fmt.Sprintf("overview-ci-%d-%d", os.Getpid(), time.Now().UnixNano())
	envelope, err := json.Marshal(map[string]any{"type": "mutation", "epoch": epoch, "mutation": json.RawMessage(`{}`)})
	if err != nil {
		return err
	}
	b.wireOverhead = len(envelope) + 1 - 2
	unsubscribe := r.SubscribeMutations(b.recordPublication)
	defer unsubscribe()
	server, err := transport.Start(transport.Options{Profile: p, Epoch: epoch, Host: r})
	if err != nil {
		return err
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		returned = errors.Join(returned, server.Close(cleanup))
	}()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	control := &http.Server{Handler: b.control(server.Connection.Token), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		returned = errors.Join(returned, control.Shutdown(cleanup))
	}()
	go func() {
		if err := control.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			b.fail("control server: " + err.Error())
			lifetimeCancel()
		}
	}()
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if err := writeJSON(o.ready, map[string]any{
		"schemaVersion": 1, "pid": os.Getpid(), "parentPID": o.parentPID, "executable": executable,
		"sourceProtocolVersion": sourceProtocolVersion, "sourceQueueCapacity": sourceQueueCapacity,
		"connection": server.Connection, "controlURL": "http://" + listener.Addr().String(),
		"controlToken": server.Connection.Token, "condition": o.condition, "n": cardCount, "k": activeCount,
		"seed": o.seed, "expectedCards": b.expected,
	}); err != nil {
		return err
	}
	go b.watchParent()
	select {
	case <-b.finish:
	case <-ctx.Done():
		b.fail("runtime stopped before /finish: " + ctx.Err().Error())
	}
	lifetimeCancel()
	b.mu.Lock()
	b.state = "closing"
	b.mu.Unlock()
	b.workers.Wait()
	b.mu.Lock()
	b.state = "finished"
	b.mu.Unlock()
	result := b.result()
	if err := writeJSON(o.output, result); err != nil {
		return err
	}
	if result["valid"] != true {
		return errors.New("Core measurement incomplete; inspect the retained result")
	}
	return nil
}

func (b *benchmark) prepareExpectations() error {
	for card := 0; card < activeCount; card++ {
		record := b.records[card]
		if b.options.condition != "R0" {
			var err error
			record, err = updateRecord(record, b.options.condition, b.options.seed, card, 249, time.Now().UnixMilli(), b.adapter)
			if err != nil {
				return err
			}
		}
		expected, err := expectedCard(record, b.adapter)
		if err != nil {
			return err
		}
		b.expected = append(b.expected, expected)
	}
	return nil
}

func (b *benchmark) control(token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if request.Header.Get("Origin") != "" || subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte("Bearer "+token)) != 1 {
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": "private benchmark control requires its ready token"})
			return
		}
		var value any
		switch request.Method + " " + request.URL.Path {
		case "POST /start":
			b.mu.Lock()
			if b.schedule != nil || b.ctx.Err() != nil || b.state == "closing" || b.state == "finished" {
				b.mu.Unlock()
				w.WriteHeader(http.StatusConflict)
				value = map[string]any{"error": "source already started"}
				break
			}
			start := time.Now().Add(time.Second)
			plan := schedule{SourceProtocolVersion: sourceProtocolVersion, SourceQueueCapacity: sourceQueueCapacity,
				WarmupStartUnixNano: start.UnixNano(), FormalStartUnixNano: start.Add(5 * time.Second).UnixNano(),
				FormalEndUnixNano: start.Add(25 * time.Second).UnixNano(), WarmupSeconds: 5, FormalSeconds: 20,
				SourceIntervalNanoseconds: int64(sourceInterval)}
			b.schedule, b.state = &plan, "scheduled"
			count := 0
			if b.options.condition != "R0" {
				count = 1000
			}
			b.events = make([]sourceEvent, count)
			for index := range b.events {
				deadline := start.Add(time.Duration(index) * sourceInterval)
				b.events[index] = sourceEvent{Index: index, CardID: fmt.Sprintf("card-%d", index%activeCount), Sequence: index / activeCount,
					PlannedUnixNano: deadline.UnixNano(), PlannedElapsedNanoseconds: deadline.Sub(b.origin).Nanoseconds()}
			}
			b.inputQueue = newSourceQueue(b.origin, sourceQueueCapacity)
			b.workers.Add(3)
			b.mu.Unlock()
			go b.measure(start)
			go b.produce(start)
			go b.consume()
			value = plan
		case "GET /status":
			b.mu.Lock()
			sequences := make([]int64, activeCount)
			for index := range sequences {
				sequences[index] = b.records[index].Revision - 1
			}
			_, formalComplete := b.boundaries["formalEnd"]
			queue := b.inputQueue
			value = map[string]any{"state": b.state, "sourceComplete": b.sourceDone, "enqueueComplete": b.enqueueDone,
				"producerFinished": b.producerDone, "sourceProtocolVersion": sourceProtocolVersion, "sourceQueueCapacity": sourceQueueCapacity,
				"formalComplete": formalComplete,
				"currentSeqs":    sequences, "errors": append([]string{}, b.errors...)}
			b.mu.Unlock()
			if queue != nil {
				value.(map[string]any)["queue"] = queue.snapshot()
			}
		case "GET /result":
			b.mu.Lock()
			_, complete := b.boundaries["formalEnd"]
			b.mu.Unlock()
			if !complete {
				w.WriteHeader(http.StatusConflict)
			}
			value = b.result()
		case "POST /finish":
			b.finishOnce.Do(func() { close(b.finish) })
			value = map[string]any{"ok": true}
		default:
			w.WriteHeader(http.StatusNotFound)
			value = map[string]any{"error": "unknown benchmark control"}
		}
		_ = json.NewEncoder(w).Encode(value)
	})
}

func (b *benchmark) watchParent() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if os.Getppid() != b.options.parentPID || syscall.Kill(b.options.parentPID, 0) != nil {
				b.fail("owning Swift parent exited")
				b.cancel()
				return
			}
		case <-b.ctx.Done():
			return
		}
	}
}

func waitUntil(ctx context.Context, deadline time.Time) bool {
	timer := time.NewTimer(max(0, time.Until(deadline)))
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func (b *benchmark) measure(start time.Time) {
	defer b.workers.Done()
	for _, mark := range []struct {
		name, state string
		offset      time.Duration
	}{
		{"warmupStart", "warmup", 0}, {"formalStart", "formal", 5 * time.Second}, {"formalEnd", "tail", 25 * time.Second},
	} {
		deadline := start.Add(mark.offset)
		if !waitUntil(b.ctx, deadline) {
			return
		}
		measured, err := sampleBoundary(b.origin, deadline.UnixNano())
		if err != nil {
			b.fail(err.Error())
			b.cancel()
			return
		}
		b.mu.Lock()
		b.boundaries[mark.name], b.state = measured, mark.state
		b.mu.Unlock()
		if mark.name == "warmupStart" {
			close(b.warmupReady)
		}
	}
}

func (b *benchmark) produce(start time.Time) {
	defer b.workers.Done()
	defer func() {
		b.inputQueue.close()
		b.mu.Lock()
		b.producerDone = true
		b.mu.Unlock()
	}()
	// The sampler opens the first interval before event zero can commit. The
	// producer still follows its own predeclared monotonic deadlines thereafter.
	select {
	case <-b.warmupReady:
	case <-b.ctx.Done():
		b.fail("source enqueue: " + b.ctx.Err().Error())
		return
	}
	err := produceSource(b.ctx, start, len(b.events), sourceInterval, b.inputQueue, func(index int, task sourceTask, err error) {
		b.mu.Lock()
		defer b.mu.Unlock()
		if err != nil {
			b.events[index].Error = err.Error()
			return
		}
		b.events[index].EnqueuedUnixNano = task.Enqueued.UnixNano
		b.events[index].EnqueuedElapsedNanoseconds = task.Enqueued.ElapsedNano
	})
	b.mu.Lock()
	b.enqueueDone = err == nil
	b.mu.Unlock()
	if err != nil {
		b.fail("source enqueue: " + err.Error())
	}
}

func (b *benchmark) consume() {
	defer b.workers.Done()
	err := consumeSource(b.ctx, b.inputQueue, func(task sourceTask) error {
		b.mu.Lock()
		event := b.events[task.Index]
		record := b.records[task.Index%activeCount]
		b.mu.Unlock()
		// The worker always starts from the latest accepted record. Queued inputs
		// contain identities/sequences only, never an obsolete session snapshot.
		event.EnqueuedUnixNano, event.EnqueuedElapsedNanoseconds = task.Enqueued.UnixNano, task.Enqueued.ElapsedNano
		event.DequeuedUnixNano, event.DequeuedElapsedNanoseconds = task.Dequeued.UnixNano, task.Dequeued.ElapsedNano
		var updated model.ThreadRecord
		_, err := executeSourceEvent(b.ctx, b.origin, event, func() error {
			var err error
			updated, err = updateRecord(record, b.options.condition, b.options.seed, task.Index%activeCount, event.Sequence, time.Now().UnixMilli(), b.adapter)
			return err
		}, func() error {
			_, err := b.db.Update(b.ctx, func(tx *store.Tx) error { return tx.Put("thread:"+updated.ID, updated) })
			return err
		}, func(receipt sourceEvent) {
			b.mu.Lock()
			b.events[task.Index] = receipt
			if receipt.AcceptedUnixNano != 0 {
				b.records[task.Index%activeCount] = updated
			}
			b.mu.Unlock()
		})
		return err
	})
	b.mu.Lock()
	allAccepted := true
	for _, event := range b.events {
		allAccepted = allAccepted && event.AcceptedUnixNano != 0
	}
	b.sourceDone = err == nil && allAccepted
	b.mu.Unlock()
	if err != nil {
		b.fail("source worker: " + err.Error())
		b.cancel()
	}
}

func (b *benchmark) fail(message string) {
	b.mu.Lock()
	b.errors = append(b.errors, message)
	b.mu.Unlock()
}

func writeJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".overview-json-")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(append(raw, '\n'))
	}
	err = errors.Join(err, file.Close())
	if err != nil {
		return err
	}
	return os.Rename(name, path)
}
