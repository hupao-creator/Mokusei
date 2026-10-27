package moku

import (
	"os"
	"path/filepath"
	"testing"
)

func TestThreadDirectoryTagFoldsManagedWorktree(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "directorytag-moku-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	worktree := filepath.Join(root, ".MokuRepo-mokusei-worktrees", "task-fd71335e-bfa")
	if err := os.MkdirAll(worktree, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := ThreadDirectoryTag(worktree); got != "MokuRepo" {
		t.Fatalf("ThreadDirectoryTag(%q) = %q, want MokuRepo", worktree, got)
	}
}

// Workspace-hint grouping still uses the cwd basename for an ordinary
// repository subdirectory; only linked worktrees fold onto the repository.
func TestThreadDirectoryTagKeepsOrdinaryRepositorySubdirectory(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "directorytag-moku-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	repository := filepath.Join(root, "MokuRepo")
	subdirectory := filepath.Join(repository, "app")
	if err := os.MkdirAll(filepath.Join(repository, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(subdirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := ThreadDirectoryTag(subdirectory); got != "app" {
		t.Fatalf("ThreadDirectoryTag(%q) = %q, want app", subdirectory, got)
	}
}
