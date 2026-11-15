package sessioncache

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"
)

func TestParseDocumentContextCanceledSkipsLargeValue(t *testing.T) {
	raw := make([]byte, 0, 32<<20)
	raw = append(raw, []byte(`{"large":"`)...)
	raw = append(raw, bytes.Repeat([]byte("x"), 32<<20)...)
	raw = append(raw, []byte(`"}`)...)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Now()
	_, err := ParseDocumentContext(ctx, raw)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled parse error = %v", err)
	}
	if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
		t.Fatalf("canceled parse scanned the large value: %s", elapsed)
	}
}
