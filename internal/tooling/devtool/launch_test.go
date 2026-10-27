package devtool

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRotateDevelopmentDataMovesCurrentAside(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "data")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "state.sqlite"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	previous, err := rotateDevelopmentData(directory)
	if err != nil {
		t.Fatal(err)
	}
	if previous != directory+".previous" {
		t.Fatalf("previous = %q, want %q", previous, directory+".previous")
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatalf("current data directory still exists: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(previous, "state.sqlite")); err != nil || string(data) != "old" {
		t.Fatalf("previous data = %q, %v", data, err)
	}

	// A second clean start replaces the saved backup.
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "state.sqlite"), []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := rotateDevelopmentData(directory); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(previous, "state.sqlite")); err != nil || string(data) != "new" {
		t.Fatalf("replaced previous data = %q, %v", data, err)
	}
}

func TestRotateDevelopmentDataWithoutCurrentKeepsPrevious(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "data")
	previous := directory + ".previous"
	if err := os.MkdirAll(previous, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(previous, "keep")
	if err := os.WriteFile(marker, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := rotateDevelopmentData(directory)
	if err != nil {
		t.Fatal(err)
	}
	if got != "" {
		t.Fatalf("previous = %q, want empty", got)
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "keep" {
		t.Fatalf("existing backup was removed: %q, %v", data, err)
	}
}
