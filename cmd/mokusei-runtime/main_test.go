package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type failedCleanup struct{}

func (failedCleanup) Initialize(context.Context) (transport.Host, error) { return nil, nil }
func (failedCleanup) Close(context.Context) error                        { return errors.New("durable flush failed") }

func TestCleanupFailureIsLoggedBeforeDiagnosticsClose(t *testing.T) {
	directory := t.TempDir()
	b := &loggedBootstrap{directory: directory, inner: failedCleanup{}}
	if _, err := b.Initialize(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := b.Close(context.Background()); err == nil {
		t.Fatal("cleanup failure was lost")
	}
	data, err := os.ReadFile(filepath.Join(directory, "service.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"event":"runtime.shutdown.failed"`) || !strings.Contains(string(data), "durable flush failed") {
		t.Fatal("cleanup failure was not persisted before closing diagnostics")
	}
}
