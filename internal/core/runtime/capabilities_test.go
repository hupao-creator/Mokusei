package runtime

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// Explicit cwd values may point at a managed task worktree even when thread
// creation used worktree:false. The served task projection must still fold the
// directory label onto the owning repository.
func TestThreadTagsFoldLinkedWorktreeCwd(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "directorytag-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	main := filepath.Join(root, "ServingRepo")
	worktree := filepath.Join(root, ".ServingRepo-mokusei-worktrees", "task-fd71335e-bfa")
	gitdir := filepath.Join(main, ".git", "worktrees", "task-fd71335e-bfa")
	for _, path := range []string{gitdir, worktree} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(gitdir, "commondir"), []byte("../..\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: "+gitdir+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{Cwd: worktree}, Tags: []string{"Keep"}}
	projection := threadTags(thread)
	if !reflect.DeepEqual(projection.DirectoryTags, []string{"ServingRepo"}) {
		t.Fatalf("DirectoryTags = %v, want [ServingRepo]", projection.DirectoryTags)
	}
	if !reflect.DeepEqual(projection.SemanticTags, []string{"Keep"}) {
		t.Fatalf("SemanticTags = %v, want [Keep]", projection.SemanticTags)
	}
}

// An ordinary repository subdirectory keeps its own directory label.
func TestThreadTagsKeepOrdinaryRepositorySubdirectory(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "directorytag-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	repository := filepath.Join(root, "ServingRepo")
	subdirectory := filepath.Join(repository, "app")
	if err := os.MkdirAll(filepath.Join(repository, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(subdirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{Cwd: subdirectory}, Tags: []string{"Keep"}}
	projection := threadTags(thread)
	if !reflect.DeepEqual(projection.DirectoryTags, []string{"app"}) {
		t.Fatalf("DirectoryTags = %v, want [app]", projection.DirectoryTags)
	}
	if !reflect.DeepEqual(projection.SemanticTags, []string{"Keep"}) {
		t.Fatalf("SemanticTags = %v, want [Keep]", projection.SemanticTags)
	}
}
