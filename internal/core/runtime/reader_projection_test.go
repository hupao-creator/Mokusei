package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type blockingReaderHarness struct {
	started     chan struct{}
	startedOnce *sync.Once
	active      *atomic.Int64
	peak        *atomic.Int64
}

func (h *blockingReaderHarness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "fake", DisplayName: "Fake"}
}
func (*blockingReaderHarness) DefaultSettings() json.RawMessage { return json.RawMessage(`{}`) }
func (*blockingReaderHarness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "installed"}, nil
}
func (*blockingReaderHarness) Settings() plugin.HarnessSettings { return blockingSettings{} }
func (h *blockingReaderHarness) SessionState() plugin.SessionStateAdapter {
	return blockingReader{started: h.started, startedOnce: h.startedOnce, active: h.active, peak: h.peak}
}
func (*blockingReaderHarness) Metadata() plugin.ThreadMetadataAdapter { return blockingMetadata{} }
func (*blockingReaderHarness) Open(context.Context, plugin.OpenContext) (plugin.Handle, error) {
	return nil, errors.New("not used")
}

type blockingSettings struct{ plugin.HarnessSettings }

type blockingMetadata struct{ plugin.ThreadMetadataAdapter }

type blockingReader struct {
	started     chan struct{}
	startedOnce *sync.Once
	active      *atomic.Int64
	peak        *atomic.Int64
}

func (blockingReader) Project(json.RawMessage) (model.PublicObservation, error) {
	return model.PublicObservation{}, nil
}
func (blockingReader) ProjectRenderer(json.RawMessage, model.RendererScope) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (blockingReader) ReadContext(json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (blockingReader) ResolveExecution(json.RawMessage, string) (*model.PublicExecution, error) {
	return nil, nil
}
func (blockingReader) Settle(request plugin.SettleRequest) (json.RawMessage, error) {
	return request.SessionState, nil
}
func (r blockingReader) ProjectReader(ctx context.Context, request plugin.ReaderRequest) (*plugin.ReaderSnapshot, error) {
	if request.Scope.Kind == "execution" {
		if r.active != nil {
			active := r.active.Add(1)
			defer r.active.Add(-1)
			for old := r.peak.Load(); active > old && !r.peak.CompareAndSwap(old, active); old = r.peak.Load() {
			}
		}
		if r.started != nil && r.startedOnce != nil {
			r.startedOnce.Do(func() { close(r.started) })
		}
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return &plugin.ReaderSnapshot{Revision: 1, Value: json.RawMessage(`{}`)}, nil
}
func (blockingReader) EvictThread(string) {}

func TestReadThreadContentUsesComputeAdmission(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		return tx.Put("thread:thread", model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fake", Revision: 1, SessionState: json.RawMessage(`{}`)}})
	})
	if err != nil {
		t.Fatal(err)
	}
	var active, peak atomic.Int64
	harness := &blockingReaderHarness{started: make(chan struct{}, 1), startedOnce: &sync.Once{}, active: &active, peak: &peak}
	r, err := New(context.Background(), Config{Store: db, DataDir: dir, Harnesses: map[string]plugin.Harness{"fake": harness}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var group sync.WaitGroup
	errs := make(chan error, 5)
	for i := 0; i < 5; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, err := r.ReadThreadContent(ctx, "thread", transport.ContentScope{Kind: "execution", Key: "target"}, nil)
			errs <- err
		}()
	}
	deadline := time.Now().Add(2 * time.Second)
	for active.Load() < 4 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 4 || peak.Load() > 4 {
		t.Fatalf("reader admission active=%d peak=%d", active.Load(), peak.Load())
	}
	cancel()
	group.Wait()
	close(errs)
	for err := range errs {
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled admission error = %v", err)
		}
	}
}

func TestReadThreadContentCancelsReaderBuild(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		return tx.Put("thread:thread", model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fake", Revision: 1, SessionState: json.RawMessage(`{}`)}})
	})
	if err != nil {
		t.Fatal(err)
	}
	harness := &blockingReaderHarness{started: make(chan struct{}), startedOnce: &sync.Once{}}
	r, err := New(context.Background(), Config{Store: db, DataDir: dir, Harnesses: map[string]plugin.Harness{"fake": harness}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err = r.ReadThreadContent(ctx, "thread", transport.ContentScope{Kind: "execution", Key: "target"}, nil)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("blocked reader error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("blocked reader did not cancel promptly: %s", elapsed)
	}
}

func TestRendererContentScopePreservesEveryWireDimension(t *testing.T) {
	scope := transport.ContentScope{Kind: "body", Key: "execution", Items: []string{"row"}, Slot: "result", Cursor: "cursor", Offset: 3, Limit: 7, Purpose: "agent-summary", Target: json.RawMessage(`{"messageId":"message"}`)}
	// Check the DTO boundary, independent of per-kind validation at transport entry.
	wire, err := json.Marshal(scope)
	if err != nil {
		t.Fatal(err)
	}
	projected, err := json.Marshal(rendererContentScope(scope))
	if err != nil {
		t.Fatal(err)
	}
	var want, got map[string]any
	if err := json.Unmarshal(wire, &want); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(projected, &got); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("renderer scope dropped dimensions: got %v want %v", got, want)
	}
}
