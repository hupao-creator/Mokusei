package environment

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAutomaticEnvironmentReuseAndExplicitRefresh(t *testing.T) {
	root := t.TempDir()
	shell := filepath.Join(root, "login-shell")
	count := filepath.Join(root, "count")
	if err := os.WriteFile(shell, []byte("#!/bin/sh\nprintf x >> \"$MOKUSEI_SHELL_COUNT\"\n/usr/bin/env -0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", shell)
	t.Setenv("MOKUSEI_SHELL_COUNT", count)
	r := New(nil)
	defer r.Close()
	ctx := context.Background()
	for range 8 {
		if _, err := r.Environment(ctx); err != nil {
			t.Fatal(err)
		}
	}
	assertCount := func(n int) {
		t.Helper()
		raw, err := os.ReadFile(count)
		if err != nil || string(raw) != strings.Repeat("x", n) {
			t.Fatalf("shell invocations = %q, error %v, want %d", raw, err, n)
		}
	}
	assertCount(1)
	if err := r.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	assertCount(2)
	r.mu.Lock()
	r.cachedAt = time.Now().Add(-6 * time.Minute)
	r.mu.Unlock()
	if _, err := r.Environment(ctx); err != nil {
		t.Fatal(err)
	}
	assertCount(3)
}
