package composition

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRemoveLegacyEmbeddingArtifactsPreservesUnrelatedFiles(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"search-index.sqlite", "search-index.sqlite-wal", "search-index.sqlite-shm", "search-index.sqlite-journal"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("derived"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	models := filepath.Join(root, "search-models")
	if err := os.MkdirAll(models, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(models, "weights.bin"), []byte("model"), 0600); err != nil {
		t.Fatal(err)
	}
	keep := filepath.Join(root, "state.sqlite")
	if err := os.WriteFile(keep, []byte("authored"), 0600); err != nil {
		t.Fatal(err)
	}
	removeLegacyEmbeddingArtifacts(root, nil)
	for _, name := range []string{"search-index.sqlite", "search-index.sqlite-wal", "search-index.sqlite-shm", "search-index.sqlite-journal", "search-models"} {
		if _, err := os.Stat(filepath.Join(root, name)); !os.IsNotExist(err) {
			t.Fatalf("legacy asset survived: %s", name)
		}
	}
	if data, err := os.ReadFile(keep); err != nil || string(data) != "authored" {
		t.Fatalf("unrelated file changed: %q %v", data, err)
	}
}

func TestRemoveLegacyEmbeddingArtifactsUnlinksSymlinkWithoutFollowing(t *testing.T) {
	root := t.TempDir()
	target := t.TempDir()
	if err := os.WriteFile(filepath.Join(target, "weights.bin"), []byte("model"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "search-models")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	removeLegacyEmbeddingArtifacts(root, nil)
	if _, err := os.Lstat(link); !os.IsNotExist(err) {
		t.Fatalf("legacy symlink survived: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(target, "weights.bin")); err != nil || string(data) != "model" {
		t.Fatalf("symlink target changed: %q %v", data, err)
	}
}

func TestRemoveLegacyEmbeddingArtifactsLogsFailureAndContinues(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission failures are unavailable as root")
	}
	root := t.TempDir()
	blocked := filepath.Join(root, "search-index.sqlite", "blocked")
	if err := os.MkdirAll(blocked, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(blocked, "weights.bin"), []byte("model"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(blocked, 0500); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Chmod(blocked, 0700) }()
	models := filepath.Join(root, "search-models")
	if err := os.MkdirAll(models, 0700); err != nil {
		t.Fatal(err)
	}
	var logged []string
	removeLegacyEmbeddingArtifacts(root, func(kind string, err error) {
		if kind != "search.legacy-embedding" || err == nil {
			t.Errorf("unexpected log: %q %v", kind, err)
		}
		logged = append(logged, kind)
	})
	if len(logged) != 1 || !strings.HasPrefix(logged[0], "search.legacy-embedding") {
		t.Fatalf("removal failure was not logged: %v", logged)
	}
	if _, err := os.Stat(models); !os.IsNotExist(err) {
		t.Fatalf("later legacy asset was not removed after failure: %v", err)
	}
}
