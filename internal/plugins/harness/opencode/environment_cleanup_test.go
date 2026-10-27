package opencode

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestTemporaryCleanupRecoversFromLateCacheWrites(t *testing.T) {
	root := filepath.Join(t.TempDir(), "environment")
	cache := filepath.Join(root, "tmp", "node-compile-cache")
	if err := os.MkdirAll(cache, 0700); err != nil {
		t.Fatal(err)
	}
	attempts := 0
	err := cleanupTemporaryEnvironment(func() error {
		attempts++
		if attempts <= 2 {
			// Deterministically model a cache entry arriving after a directory
			// scan. Real filesystem races would make this regression flaky.
			if err := os.WriteFile(filepath.Join(cache, "late-entry"), []byte("cache"), 0600); err != nil {
				t.Fatal(err)
			}
			return &os.PathError{Op: "unlinkat", Path: cache, Err: syscall.ENOTEMPTY}
		}
		return os.RemoveAll(root)
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("temporary environment remains after cleanup: %v", err)
	}
}

func TestTemporaryCleanupPreservesFailures(t *testing.T) {
	permission := &os.PathError{Op: "unlinkat", Path: "cache", Err: syscall.EACCES}
	notEmpty := &os.PathError{Op: "unlinkat", Path: "cache", Err: syscall.ENOTEMPTY}
	for _, scenario := range []struct {
		name      string
		lateWrite bool
	}{{"permission", false}, {"permission-after-late-write", true}} {
		t.Run(scenario.name, func(t *testing.T) {
			attempts := 0
			err := cleanupTemporaryEnvironment(func() error {
				attempts++
				if attempts == 1 && scenario.lateWrite {
					return notEmpty
				}
				if attempts > 2 || (!scenario.lateWrite && attempts > 1) {
					t.Fatal("retried a non-transient failure")
				}
				return permission
			})
			if err != permission {
				t.Fatalf("lost final cleanup cause: %v", err)
			}
		})
	}
	t.Run("persistent-late-writes", func(t *testing.T) {
		start := time.Now()
		err := cleanupTemporaryEnvironment(func() error { return notEmpty })
		if err != notEmpty {
			t.Fatalf("lost persistent cleanup cause: %v", err)
		}
		if elapsed := time.Since(start); elapsed < time.Second || elapsed > 5*time.Second {
			t.Fatalf("cleanup retry window was not bounded: %v", elapsed)
		}
	})
}

func TestEnvironmentCleanupPreservesExternalData(t *testing.T) {
	root := t.TempDir()
	data := filepath.Join(root, "native-data")
	values, cleanup, err := PrepareEnvironment(Options{
		CWD: root, Environment: map[string]string{"HOME": root, "XDG_DATA_HOME": data}, IsolateConfig: true,
	}, filepath.Join(root, "bridge"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cleanup() })
	tmp := ""
	for _, entry := range values {
		if value, ok := strings.CutPrefix(entry, "TMPDIR="); ok {
			tmp = value
		}
	}
	if tmp == "" {
		t.Fatal("missing private temporary directory")
	}
	if err := os.MkdirAll(data, 0700); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(data, "session-proof")
	if err := os.WriteFile(sentinel, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(data, filepath.Join(tmp, "external-data")); err != nil {
		t.Fatal(err)
	}
	if err := cleanup(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Dir(tmp)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("owned temporary directory remains: %v", err)
	}
	if contents, err := os.ReadFile(sentinel); err != nil || string(contents) != "preserved" {
		t.Fatalf("external data changed: %q, %v", contents, err)
	}
	if err := cleanup(); err != nil {
		t.Fatalf("repeated cleanup failed: %v", err)
	}
}
