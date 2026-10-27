package discovery

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"
)

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("condition did not settle")
		}
		runtime.Gosched()
	}
}

func TestReadersOwnCancellationAndLastReaderDrains(t *testing.T) {
	var cache Cache[int]
	defer cache.Close()
	var starts atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	probe := func(ctx context.Context) (int, error) {
		starts.Add(1)
		close(started)
		select {
		case <-release:
			return 42, nil
		case <-ctx.Done():
			return 0, ctx.Err()
		}
	}
	first, cancel := context.WithCancel(context.Background())
	firstResult := make(chan error, 1)
	go func() { _, err := cache.Get(first, "one", false, time.Minute, time.Minute, probe); firstResult <- err }()
	<-started
	secondResult := make(chan int, 1)
	go func() {
		value, _ := cache.Get(context.Background(), "one", false, time.Minute, time.Minute, probe)
		secondResult <- value
	}()
	waitFor(t, func() bool { cache.mu.Lock(); defer cache.mu.Unlock(); return cache.pending["one"].readers == 2 })
	cancel()
	if !errors.Is(<-firstResult, context.Canceled) {
		t.Fatal("cancelled reader did not leave")
	}
	close(release)
	if <-secondResult != 42 || starts.Load() != 1 {
		t.Fatal("one reader cancelled the shared probe")
	}
	if value, err := cache.Get(context.Background(), "one", false, time.Minute, time.Minute, probe); err != nil || value != 42 || starts.Load() != 1 {
		t.Fatal("warm read started a probe")
	}

	last, cancelLast := context.WithCancel(context.Background())
	owned, cleanup, exited := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		_, _ = cache.Get(last, "two", false, time.Minute, time.Minute, func(ctx context.Context) (int, error) {
			close(owned)
			<-ctx.Done()
			<-cleanup
			close(exited)
			return 0, ctx.Err()
		})
	}()
	<-owned
	cancelLast()
	closed := make(chan struct{})
	go func() { _ = cache.Close(); close(closed) }()
	select {
	case <-closed:
		t.Fatal("Close returned before cleanup")
	default:
	}
	close(cleanup)
	<-closed
	<-exited
}

func TestRefreshFencesOldSuccessAndPreservesOtherKeys(t *testing.T) {
	var cache Cache[string]
	defer cache.Close()
	get := func(key string, refresh bool, probe func(context.Context) (string, error)) (string, error) {
		return cache.Get(context.Background(), key, refresh, time.Minute, time.Minute, probe)
	}
	_, _ = get("other", false, func(context.Context) (string, error) { return "untouched", nil })
	started, release, oldDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(oldDone)
		_, _ = get("key", false, func(context.Context) (string, error) { close(started); <-release; return "old", nil })
	}()
	<-started
	if value, err := get("key", true, func(context.Context) (string, error) { return "new", nil }); err != nil || value != "new" {
		t.Fatal("refresh failed")
	}
	close(release)
	<-oldDone
	fail := func(context.Context) (string, error) { t.Fatal("unexpected native read"); return "", nil }
	if value, _ := get("key", false, fail); value != "new" {
		t.Fatal("late old result won")
	}
	if value, _ := get("other", false, fail); value != "untouched" {
		t.Fatal("refresh invalidated another key")
	}
	_, _ = get("key", true, func(context.Context) (string, error) { return "", errors.New("offline") })
	cache.mu.Lock()
	retained := cache.entries["key"]
	cache.mu.Unlock()
	if retained.value != "new" || !retained.at.IsZero() {
		t.Fatal("failed refresh erased last good or kept it fresh")
	}
	value, _ := get("key", false, func(context.Context) (string, error) { return "recovered", nil })
	if value != "recovered" {
		t.Fatal("failed refresh poisoned later reads")
	}
}

func TestIdentitySeparatesProfilesAndNativeFileChanges(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	env := map[string]string{"HOME": "profile-a", "TOKEN": "synthetic-a"}
	first := Identity(env, path)
	if err := os.WriteFile(path, []byte("one"), 0600); err != nil {
		t.Fatal(err)
	}
	second := Identity(env, path)
	if first == second {
		t.Fatal("file creation did not invalidate")
	}
	env["HOME"] = "profile-b"
	third := Identity(env, path)
	if third == second {
		t.Fatal("profile change shared cache")
	}
	env["TOKEN"] = "synthetic-b"
	if Identity(env, path) == third {
		t.Fatal("credential environment change shared cache")
	}
}

func TestCleanupFailureSurvivesReaderAndFencesReplacement(t *testing.T) {
	var cache Cache[int]
	failure := errors.New("native child did not drain")
	_, err := cache.Get(context.Background(), "one", false, time.Minute, time.Minute, func(context.Context) (int, error) { return 0, Cleanup(failure) })
	if !errors.Is(err, failure) {
		t.Fatal("reader lost cleanup failure")
	}
	_, err = cache.Get(context.Background(), "two", true, time.Minute, time.Minute, func(context.Context) (int, error) { t.Fatal("uncertain native ownership was replaced"); return 1, nil })
	if !errors.Is(err, failure) {
		t.Fatal("cleanup fence lost its cause")
	}
	if !errors.Is(cache.Close(), failure) {
		t.Fatal("Close lost cleanup failure")
	}
}

func TestTimeoutCannotPublishSuccessfulLookingResult(t *testing.T) {
	var cache Cache[int]
	defer cache.Close()
	_, err := cache.Get(context.Background(), "one", false, time.Minute, time.Millisecond, func(ctx context.Context) (int, error) { <-ctx.Done(); return 17, nil })
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("probe deadline was lost", err)
	}
	value, err := cache.Get(context.Background(), "one", false, time.Minute, time.Second, func(context.Context) (int, error) { return 23, nil })
	if err != nil || value != 23 {
		t.Fatal("timed out result poisoned cache")
	}
}

func TestFailedRefreshFencesOlderCompletion(t *testing.T) {
	var cache Cache[int]
	defer cache.Close()
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		_, _ = cache.Get(context.Background(), "one", false, time.Minute, time.Second, func(context.Context) (int, error) { close(started); <-release; return 17, nil })
	}()
	<-started
	_, _ = cache.Get(context.Background(), "one", true, time.Minute, time.Second, func(context.Context) (int, error) { return 0, errors.New("refresh failed") })
	close(release)
	<-done
	value, err := cache.Get(context.Background(), "one", false, time.Minute, time.Second, func(context.Context) (int, error) { return 23, nil })
	if err != nil || value != 23 {
		t.Fatal("failed refresh allowed an older flight to repopulate the cache")
	}
}
