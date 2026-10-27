//go:build !darwin

package moku

import (
	"context"
	"errors"
	"testing"
)

func TestClipboardUnsupportedPlatform(t *testing.T) {
	if _, err := readSystemClipboardText(context.Background(), 4); !errors.Is(err, errClipboardUnsupported) {
		t.Fatalf("unsupported error = %v", err)
	}
}
