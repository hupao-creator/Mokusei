package sessioncache

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func TestCacheReuseGenerationAndStaleBuild(t *testing.T) {
	cache := NewCacheWithLimits(1<<20, 1<<19, 8)
	builds := atomic.Int64{}
	build := func(_ context.Context, _ any, _ *Projections) (any, int64, error) {
		builds.Add(1)
		return builds.Load(), 64, nil
	}
	first, err := cache.Acquire(context.Background(), "thread", "content-a", 1, build)
	if err != nil {
		t.Fatal(err)
	}
	first.Release()
	second, err := cache.Acquire(context.Background(), "thread", "content-a", 2, build)
	if err != nil {
		t.Fatal(err)
	}
	if builds.Load() != 1 {
		t.Fatalf("same content rebuilt: builds=%d", builds.Load())
	}
	second.Release()

	newer, err := cache.Acquire(context.Background(), "thread", "content-b", 3, build)
	if err != nil {
		t.Fatal(err)
	}
	if newer.Value != int64(2) {
		t.Fatalf("new content value = %v", newer.Value)
	}
	newer.Release()
	stale, err := cache.Acquire(context.Background(), "thread", "content-old", 2, build)
	if err != nil {
		t.Fatal(err)
	}
	if stale.Value != int64(3) {
		t.Fatalf("stale build value = %v", stale.Value)
	}
	stale.Release()
	fresh, err := cache.Acquire(context.Background(), "thread", "content-b", 4, build)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Value != int64(2) || builds.Load() != 3 {
		t.Fatalf("stale build replaced newer content: value=%v builds=%d", fresh.Value, builds.Load())
	}
	fresh.Release()
}

func TestCacheCancellationDuringBuild(t *testing.T) {
	cache := NewCacheWithLimits(1<<20, 1<<19, 8)
	blocked := make(chan struct{})
	build := func(ctx context.Context, _ any, _ *Projections) (any, int64, error) {
		close(blocked)
		<-ctx.Done()
		return nil, 0, ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := cache.Acquire(ctx, "thread", "content", 1, build)
		done <- err
	}()
	<-blocked
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled build error = %v", err)
	}
	value, err := cache.Acquire(context.Background(), "thread", "content", 1, func(context.Context, any, *Projections) (any, int64, error) {
		return "ok", 1, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if value.Value != "ok" {
		t.Fatalf("later build value = %v", value.Value)
	}
	value.Release()
}

func TestCachePanicRecovery(t *testing.T) {
	cache := NewCacheWithLimits(1<<20, 1<<19, 8)
	_, err := cache.Acquire(context.Background(), "thread", "panic", 1, func(context.Context, any, *Projections) (any, int64, error) {
		panic("boom")
	})
	if err == nil || !strings.Contains(err.Error(), "panicked") {
		t.Fatalf("panic error = %v", err)
	}
	value, err := cache.Acquire(context.Background(), "thread", "ok", 2, func(context.Context, any, *Projections) (any, int64, error) {
		return "ok", 1, nil
	})
	if err != nil || value.Value != "ok" {
		t.Fatalf("build after panic = %v, %v", value, err)
	}
	value.Release()
}

func TestCacheEntryAndThreadLimits(t *testing.T) {
	cache := NewCacheWithLimits(1024, 512, 2)
	large := func(context.Context, any, *Projections) (any, int64, error) { return "large", 4096, nil }
	value, err := cache.Acquire(context.Background(), "large", "large", 1, large)
	if err != nil {
		t.Fatal(err)
	}
	if value.account {
		t.Fatal("oversized entry was retained")
	}
	value.Release()
	rebuilt, err := cache.Acquire(context.Background(), "large", "large", 1, large)
	if err != nil {
		t.Fatal(err)
	}
	if rebuilt.account {
		t.Fatal("oversized entry was retained on retry")
	}
	rebuilt.Release()

	for _, id := range []string{"one", "two", "three"} {
		handle, err := cache.Acquire(context.Background(), id, "content", 1, func(context.Context, any, *Projections) (any, int64, error) {
			return id, 32, nil
		})
		if err != nil {
			t.Fatal(err)
		}
		handle.Release()
	}
	if stats := cache.Stats(); stats.Threads > 2 {
		t.Fatalf("empty/small Threads exceeded limit: %+v", stats)
	}
	if _, err := cache.Acquire(context.Background(), "failed", "failed", 1, func(context.Context, any, *Projections) (any, int64, error) {
		return nil, 0, errors.New("build failed")
	}); err == nil {
		t.Fatal("failed build succeeded")
	}
	if stats := cache.Stats(); stats.Threads > 2 {
		t.Fatalf("failed build retained a Thread: %+v", stats)
	}

}

func TestProjectionsSingleflightAndPanic(t *testing.T) {
	projections := NewProjections()
	fingerprint := Fingerprint([]byte("scope"))
	var builds atomic.Int64
	start := make(chan struct{})
	results := make(chan Projection, 8)
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			value, _, err := projections.Do(context.Background(), Key("scope"), fingerprint, func() (json.RawMessage, error) {
				builds.Add(1)
				time.Sleep(10 * time.Millisecond)
				return json.RawMessage(`{"ok":true}`), nil
			})
			if err != nil {
				panic(err)
			}
			results <- value
		}()
	}
	close(start)
	group.Wait()
	close(results)
	for value := range results {
		if string(value.Value) != `{"ok":true}` {
			t.Fatalf("projection value = %s", value.Value)
		}
	}
	if builds.Load() != 1 {
		t.Fatalf("concurrent projection builds = %d", builds.Load())
	}
	_, _, err := projections.Do(context.Background(), Key("panic"), fingerprint, func() (json.RawMessage, error) {
		panic("boom")
	})
	if err == nil {
		t.Fatal("projection panic succeeded")
	}
	value, _, err := projections.Do(context.Background(), Key("panic"), fingerprint, func() (json.RawMessage, error) {
		return json.RawMessage(`{"recovered":true}`), nil
	})
	if err != nil || string(value.Value) != `{"recovered":true}` {
		t.Fatalf("projection after panic = %s, %v", value.Value, err)
	}
}

func TestScopesSingleflightLRUAndPanic(t *testing.T) {
	scopes := NewScopes(2, 256)
	var builds atomic.Int64
	value, _, err := scopes.Do(context.Background(), Key("one"), func(context.Context) (json.RawMessage, error) {
		builds.Add(1)
		return json.RawMessage(`1`), nil
	})
	if err != nil || string(value) != "1" {
		t.Fatalf("scope one = %s, %v", value, err)
	}
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, _, err := scopes.Do(context.Background(), Key("one"), func(context.Context) (json.RawMessage, error) {
				builds.Add(1)
				return json.RawMessage(`1`), nil
			})
			if err != nil {
				panic(err)
			}
		}()
	}
	group.Wait()
	if builds.Load() != 1 {
		t.Fatalf("scope builds = %d", builds.Load())
	}
	for _, key := range []Key{"two", "three"} {
		_, _, err := scopes.Do(context.Background(), key, func(context.Context) (json.RawMessage, error) {
			return json.RawMessage(`1234`), nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	scopes.mu.Lock()
	entries, bytes := len(scopes.entries), scopes.bytes
	scopes.mu.Unlock()
	if entries > 2 || bytes > 256 {
		t.Fatalf("scope LRU exceeded limits: entries=%d bytes=%d", entries, bytes)
	}
	large, _, err := scopes.Do(context.Background(), Key("large"), func(context.Context) (json.RawMessage, error) {
		return json.RawMessage(`"` + strings.Repeat("x", 1024) + `"`), nil
	})
	if err != nil || len(large) == 0 {
		t.Fatalf("transient scope value = %d, %v", len(large), err)
	}
	scopes.mu.Lock()
	_, retained := scopes.entries[Key("large")]
	scopes.mu.Unlock()
	if retained {
		t.Fatal("scope value above the per-session byte limit was retained")
	}
	if _, _, err := scopes.Do(context.Background(), Key("panic"), func(context.Context) (json.RawMessage, error) {
		panic("boom")
	}); err == nil {
		t.Fatal("scope panic succeeded")
	}
	if _, _, err := scopes.Do(context.Background(), Key("panic"), func(context.Context) (json.RawMessage, error) {
		return json.RawMessage(`ok`), nil
	}); err != nil {
		t.Fatalf("scope after panic: %v", err)
	}
}

func TestScopeKeyUsesCompleteScope(t *testing.T) {
	one := ScopeKey(model.RendererScope{Kind: "turn", Key: "same"})
	two := ScopeKey(model.RendererScope{Kind: "turn", Key: "same"})
	if one != two {
		t.Fatal("same scope produced different keys")
	}
	other := ScopeKey(model.RendererScope{Kind: "execution", Key: "same"})
	if one == other {
		t.Fatal("different scope kinds shared a key")
	}
}

func TestCacheReleaseThreadAndCloseDoNotWaitForBuild(t *testing.T) {
	cache := NewCacheWithLimits(1<<20, 1<<19, 8)
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = cache.Acquire(context.Background(), "thread", "content", 1, func(context.Context, any, *Projections) (any, int64, error) {
			close(started)
			<-release
			return "ok", 1, nil
		})
	}()
	<-started
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		cache.ReleaseThread("thread")
	}()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("ReleaseThread waited for an in-flight build")
	}
	cache.Close()
	if _, err := cache.Acquire(context.Background(), "closed", "content", 1, func(context.Context, any, *Projections) (any, int64, error) {
		return "unexpected", 1, nil
	}); !errors.Is(err, ErrClosed) {
		t.Fatalf("closed cache error = %v", err)
	}
	close(release)
	<-done
}

func TestCacheWaiterObservesCancellation(t *testing.T) {
	cache := NewCacheWithLimits(1<<20, 1<<19, 8)
	started := make(chan struct{})
	release := make(chan struct{})
	firstDone := make(chan error, 1)
	go func() {
		_, err := cache.Acquire(context.Background(), "thread", "first", 1, func(context.Context, any, *Projections) (any, int64, error) {
			close(started)
			<-release
			return "first", 1, nil
		})
		firstDone <- err
	}()
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := cache.Acquire(ctx, "thread", "second", 2, func(context.Context, any, *Projections) (any, int64, error) {
		return "second", 1, nil
	}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("waiter cancellation error = %v", err)
	}
	close(release)
	if err := <-firstDone; err != nil {
		t.Fatal(err)
	}
}

func TestCacheGrowthCrossesEntryLimit(t *testing.T) {
	cache := NewCacheWithLimits(2<<20, 2<<20, 4)
	builds := atomic.Int64{}
	build := func(context.Context, any, *Projections) (any, int64, error) {
		builds.Add(1)
		return "value", 256, nil
	}
	handle, err := cache.Acquire(context.Background(), "grow", "grow", 1, build)
	if err != nil {
		t.Fatal(err)
	}
	if !handle.account {
		t.Fatal("initial value was not retained")
	}
	handle.AddSize(2 << 20) // crosses the 2 MiB per-entry cap
	if stats := cache.Stats(); stats.Threads != 0 || stats.Bytes != 0 {
		t.Fatalf("growth past per-entry cap remained retained: %+v", stats)
	}
	handle.Release()
	if stats := cache.Stats(); stats.Threads != 0 || stats.Bytes != 0 {
		t.Fatalf("released oversized entry remained: %+v", stats)
	}
	next, err := cache.Acquire(context.Background(), "grow", "grow", 1, build)
	if err != nil {
		t.Fatal(err)
	}
	if builds.Load() != 2 {
		t.Fatalf("entry was not rebuilt after cap eviction: builds=%d", builds.Load())
	}
	next.Release()
}

func TestCacheReleaseThreadDuringBuildStaysTransient(t *testing.T) {
	cache := NewCacheWithLimits(1<<20, 1<<20, 4)
	started := make(chan struct{})
	release := make(chan struct{})
	result := make(chan *Handle, 1)
	go func() {
		handle, _ := cache.Acquire(context.Background(), "thread", "content", 1, func(context.Context, any, *Projections) (any, int64, error) {
			close(started)
			<-release
			return "value", 5120, nil
		})
		result <- handle
	}()
	<-started
	cache.ReleaseThread("thread")
	if stats := cache.Stats(); stats.Bytes != 0 || stats.Threads != 0 {
		t.Fatalf("release during build retained bytes: %+v", stats)
	}
	close(release)
	handle := <-result
	if stats := cache.Stats(); stats.Bytes != 0 || stats.Threads != 0 {
		t.Fatalf("completed build installed into removed entry: %+v", stats)
	}
	handle.Release()
	if stats := cache.Stats(); stats.Bytes != 0 || stats.Threads != 0 {
		t.Fatalf("transient handle release changed retained stats: %+v", stats)
	}
	next, err := cache.Acquire(context.Background(), "thread", "content", 1, func(context.Context, any, *Projections) (any, int64, error) {
		return "next", 1, nil
	})
	if err != nil || next.Value != "next" {
		t.Fatalf("next build = %v, %v", next, err)
	}
	next.Release()
}

func TestCacheCloseDuringBuildStaysTransient(t *testing.T) {
	cache := NewCacheWithLimits(1<<20, 1<<20, 4)
	started := make(chan struct{})
	release := make(chan struct{})
	result := make(chan *Handle, 1)
	go func() {
		handle, _ := cache.Acquire(context.Background(), "thread", "content", 1, func(context.Context, any, *Projections) (any, int64, error) {
			close(started)
			<-release
			return "value", 5120, nil
		})
		result <- handle
	}()
	<-started
	cache.Close()
	close(release)
	handle := <-result
	if handle == nil || handle.account {
		t.Fatalf("closed cache installed build: %+v", handle)
	}
	if stats := cache.Stats(); stats.Bytes != 0 || stats.Threads != 0 {
		t.Fatalf("closed cache retained build: %+v", stats)
	}
	handle.Release()
}

func TestCacheRetainsEntryLargerThanOld64MiBCap(t *testing.T) {
	cache := NewCache(128 << 20)
	builds := atomic.Int64{}
	build := func(context.Context, any, *Projections) (any, int64, error) {
		builds.Add(1)
		return "large", 70 << 20, nil
	}
	handle, err := cache.Acquire(context.Background(), "large", "content", 1, build)
	if err != nil {
		t.Fatal(err)
	}
	if !handle.account {
		t.Fatal("70 MiB entry was not retained under a 128 MiB budget")
	}
	if stats := cache.Stats(); stats.LiveEntries != 1 || stats.LiveBytes < 70<<20 {
		t.Fatalf("live entry accounting = %+v", stats)
	}
	handle.Release()
	if stats := cache.Stats(); stats.LiveEntries != 0 || stats.RetainedBytes < 70<<20 {
		t.Fatalf("retained/live accounting = %+v", stats)
	}
	again, err := cache.Acquire(context.Background(), "large", "content", 2, build)
	if err != nil {
		t.Fatal(err)
	}
	if builds.Load() != 1 {
		t.Fatalf("large entry was rebuilt: builds=%d", builds.Load())
	}
	if stats := cache.Stats(); stats.Bytes < 70<<20 {
		t.Fatalf("large entry missing from retained stats: %+v", stats)
	}
	again.Release()
}

func TestProjectionsWaiterObservesCancellation(t *testing.T) {
	projections := NewProjections()
	fingerprint := Fingerprint([]byte("scope"))
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, _, err := projections.Do(context.Background(), Key("scope"), fingerprint, func() (json.RawMessage, error) {
			close(started)
			<-release
			return json.RawMessage(`{"ok":true}`), nil
		})
		done <- err
	}()
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, _, err := projections.Do(ctx, Key("scope"), fingerprint, func() (json.RawMessage, error) {
		return json.RawMessage(`{"other":true}`), nil
	}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("projection waiter cancellation = %v", err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestScopesWaiterObservesCancellation(t *testing.T) {
	scopes := NewScopes(4, 1024)
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, _, err := scopes.Do(context.Background(), Key("scope"), func(context.Context) (json.RawMessage, error) {
			close(started)
			<-release
			return json.RawMessage(`{"ok":true}`), nil
		})
		done <- err
	}()
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, _, err := scopes.Do(ctx, Key("scope"), func(context.Context) (json.RawMessage, error) {
		return json.RawMessage(`{"other":true}`), nil
	}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("scope waiter cancellation = %v", err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestScopesOversizedValueIsRebuilt(t *testing.T) {
	scopes := NewScopes(4, 128)
	builds := atomic.Int64{}
	build := func(context.Context) (json.RawMessage, error) {
		builds.Add(1)
		return json.RawMessage(`"` + strings.Repeat("x", 256) + `"`), nil
	}
	for i := 0; i < 2; i++ {
		value, _, err := scopes.Do(context.Background(), Key("large"), build)
		if err != nil || len(value) <= 256 {
			t.Fatalf("oversized scope value = %d, %v", len(value), err)
		}
	}
	if builds.Load() != 2 {
		t.Fatalf("oversized scope value was retained: builds=%d", builds.Load())
	}
}

func TestScopesDefaultLimitDoesNotRetainAboveLimit(t *testing.T) {
	scopes := NewScopes(4, DefaultScopeBytes)
	builds := atomic.Int64{}
	build := func(context.Context) (json.RawMessage, error) {
		builds.Add(1)
		value := make([]byte, DefaultScopeBytes+1)
		value[0] = '"'
		value[len(value)-1] = '"'
		return json.RawMessage(value), nil
	}
	for i := 0; i < 2; i++ {
		value, _, err := scopes.Do(context.Background(), Key("above-default"), build)
		if err != nil || len(value) != int(DefaultScopeBytes+1) {
			t.Fatalf("above-limit scope value = %d, %v", len(value), err)
		}
	}
	if builds.Load() != 2 {
		t.Fatalf("above-limit scope value was retained: builds=%d", builds.Load())
	}
	scopes.mu.Lock()
	bytes := scopes.bytes
	scopes.mu.Unlock()
	if bytes != 0 {
		t.Fatalf("above-limit scope value retained bytes=%d", bytes)
	}
}

func TestScopeKeyDistinguishesReadingPurposeAndTarget(t *testing.T) {
	detail := ScopeKey(model.RendererScope{Kind: "turn", Key: "target"})
	summary := ScopeKey(model.RendererScope{Kind: "turn", Key: "target", Purpose: model.RendererPurposeAgentSummary})
	if detail == summary {
		t.Fatal("detail and agent-summary shared a projection key")
	}
	first := ScopeKey(model.RendererScope{Kind: "turn", Key: "target", Purpose: model.RendererPurposeAgentSummary, Target: json.RawMessage(`{"messageId":"one"}`)})
	second := ScopeKey(model.RendererScope{Kind: "turn", Key: "target", Purpose: model.RendererPurposeAgentSummary, Target: json.RawMessage(`{"messageId":"two"}`)})
	if first == second {
		t.Fatal("different reading targets shared a projection key")
	}
}

func TestScopeKeySeparatesBodySelectionsAndCursors(t *testing.T) {
	scopes := []model.RendererScope{
		{Kind: "detail", Key: "execution", Items: []string{"one"}},
		{Kind: "detail", Key: "execution", Items: []string{"two"}},
		{Kind: "body", Key: "execution", Items: []string{"one"}, Slot: "arguments"},
		{Kind: "body", Key: "execution", Items: []string{"one"}, Slot: "result"},
		{Kind: "body", Key: "execution", Items: []string{"one"}, Slot: "result", Cursor: "next-page"},
	}
	keys := map[Key]bool{}
	for _, scope := range scopes {
		key := ScopeKey(scope)
		if keys[key] {
			t.Fatalf("scope aliased another selection: %+v", scope)
		}
		keys[key] = true
	}
}
