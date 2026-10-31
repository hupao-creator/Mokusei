package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStartupEvidenceRetainsBoundedOwnedFiles(t *testing.T) {
	root := t.TempDir()
	runtime := filepath.Join(root, "daemon", "runtime")
	if err := os.MkdirAll(runtime, 0700); err != nil {
		t.Fatal(err)
	}
	log := bytes.Repeat([]byte("x"), 2*1024*1024+1)
	if err := os.WriteFile(filepath.Join(runtime, "process.log"), log, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(runtime, "unrelated.txt"), []byte("not exported"), 0600); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside.json")
	if err := os.WriteFile(outside, []byte(`{"unrelated":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(runtime, "owner.json")); err != nil {
		t.Fatal(err)
	}
	e := helperStartupEvidence{root: root, directory: t.TempDir()}
	if err := e.retain("concurrent-launch"); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(e.directory, "concurrent-launch")
	data, err := os.ReadFile(filepath.Join(output, "daemon", "runtime", "process.log"))
	if err != nil || len(data) != 2*1024*1024 || !bytes.Equal(data, log[:len(data)]) {
		t.Fatalf("log prefix was not retained at its declared bound: bytes=%d error=%v", len(data), err)
	}
	for _, name := range []string{"owner.json", "unrelated.txt"} {
		if _, err := os.Stat(filepath.Join(output, "daemon", "runtime", name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("unowned link or unlisted file was exported: %s, %v", name, err)
		}
	}
	data, err = os.ReadFile(filepath.Join(output, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Files []map[string]any `json:"files"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	var bounded, rejected, missing bool
	digest := sha256.Sum256(log[:2*1024*1024])
	for _, file := range manifest.Files {
		switch file["path"] {
		case "daemon/runtime/process.log":
			bounded = file["truncated"] == true && file["copiedBytes"] == float64(2*1024*1024) && file["copiedSHA256"] == hex.EncodeToString(digest[:])
		case "daemon/runtime/owner.json":
			rejected = file["error"] != nil
		case "daemon/runtime/startup-error.json":
			missing = file["error"] != nil
		}
	}
	if !bounded || !rejected || !missing {
		t.Fatal("manifest hid truncation, rejected link or missing startup diagnostic")
	}
}

func TestStartupEvidencePrecedesRemovalAndPreservesPanic(t *testing.T) {
	root := filepath.Join(t.TempDir(), "owned")
	runtime := filepath.Join(root, "daemon", "runtime")
	if err := os.MkdirAll(runtime, 0700); err != nil {
		t.Fatal(err)
	}
	message := []byte("fixture child could not acquire its guard\n")
	if err := os.WriteFile(filepath.Join(runtime, "process.log"), message, 0600); err != nil {
		t.Fatal(err)
	}
	e := helperStartupEvidence{root: root, directory: t.TempDir()}
	failure := errors.New("original concurrent launch failure")
	var caught any
	func() {
		defer func() { caught = recover() }()
		func() {
			defer os.RemoveAll(root)
			defer e.onPanic()
			panic(failure)
		}()
	}()
	if caught != failure {
		t.Fatalf("capture replaced the original panic: %v", caught)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("fixture cleanup did not execute: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(e.directory, "panic", "daemon", "runtime", "process.log"))
	if err != nil || !bytes.Equal(data, message) {
		t.Fatalf("failure log disappeared before capture: %v", err)
	}
}

func TestStartupEvidenceRetainsInvalidLaunchMetadataWithinLimit(t *testing.T) {
	root := t.TempDir()
	runtime := filepath.Join(root, "daemon", "runtime")
	if err := os.MkdirAll(runtime, 0700); err != nil {
		t.Fatal(err)
	}
	for i := range 62 {
		if err := os.WriteFile(filepath.Join(runtime, fmt.Sprintf("launch-%d.json", 1000+i)), []byte(`{invalid`), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"launch-0.json", "launch-invalid.json", "launch-zz-overflow.json"} {
		if err := os.WriteFile(filepath.Join(runtime, name), []byte(`{}`), 0600); err != nil {
			t.Fatal(err)
		}
	}
	e := helperStartupEvidence{root: root, directory: t.TempDir()}
	if err := e.retain("invalid-metadata"); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(e.directory, "invalid-metadata")
	data, err := os.ReadFile(filepath.Join(output, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Files []map[string]any `json:"files"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	var copied, invalidNames, invalidJSON int
	var bounded bool
	for _, record := range manifest.Files {
		path, _ := record["path"].(string)
		if path == "daemon/runtime" && record["launchFiles"] == float64(65) {
			bounded = record["launchLimit"] == float64(64) && record["directoryReadError"] == nil
		}
		if !strings.HasPrefix(path, "daemon/runtime/launch-") {
			continue
		}
		if record["error"] != nil {
			t.Fatalf("metadata bytes were not retained: %v", record)
		}
		copied++
		if record["filenameMetadataError"] != nil {
			invalidNames++
			if record["launchFilenamePID"] != nil {
				t.Fatal("invalid filename was interpreted as a process ID")
			}
		}
		if record["jsonDecodeError"] != nil {
			invalidJSON++
		}
		retained, err := os.ReadFile(filepath.Join(output, path))
		if err != nil || len(retained) == 0 {
			t.Fatalf("diagnostic metadata absent: %s: %v", path, err)
		}
	}
	if copied != 64 || invalidNames != 2 || invalidJSON != 62 || !bounded {
		t.Fatalf("launch evidence was silently omitted or unbounded: copied=%d invalid names=%d invalid JSON=%d limit=%v", copied, invalidNames, invalidJSON, bounded)
	}
	if _, err := os.Stat(filepath.Join(output, "daemon/runtime/launch-zz-overflow.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("65th launch receipt exceeded the evidence bound: %v", err)
	}
}
