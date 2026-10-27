package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
)

// A Report persisted while its task lived in a linked worktree must be repaired
// by the real startup refresh, and a Report whose source thread disappeared
// must not retain the private task label forever.
func TestRefreshApplicationDirectoryTagsTracksWorktreeAndRemovedSource(t *testing.T) {
	git := findGit(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	h, err := openHarness(ctx, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer h.close()
	root, err := os.MkdirTemp("/tmp", "applicationhost-directorytag-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	main := filepath.Join(root, "Mokusei")
	initGitRepository(t, git, main)
	worktree := filepath.Join(root, ".Mokusei-mokusei-worktrees", "task-fd71335e-bfa")
	runGitCommand(t, git, main, "worktree", "add", "--detach", worktree)

	const stale = "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"
	ref := model.ThreadRef{ThreadID: "worktree-source", TypeID: "agent"}
	reportID := "report-worktree"
	value := report.Data{
		Scope:           main,
		Title:           "Worktree report",
		HTML:            "<p>ok</p>",
		ContentRevision: "content-1",
		RelatedExecutions: []model.ExecutionRef{
			{Thread: ref, ExecutionID: "execution-1"},
		},
		TagSources: map[string]report.TagSource{
			ref.ThreadID: {TagEmojis: map[string]string{"Keep": "👩🏽‍💻"}, SemanticTags: []string{"Keep"}, DirectoryTags: []string{stale}},
		},
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	reportRecord := model.ApplicationThreadRecord{
		VersionedRecord: model.VersionedRecord{ID: reportID, Revision: 1, Value: encoded, CreatedAt: fixtureAt, UpdatedAt: fixtureAt},
		Ref:             model.ThreadRef{ThreadID: reportID, TypeID: report.ThreadTypeID},
	}
	threadRecord := model.ThreadRecord{SessionRecord: model.SessionRecord{
		ID: ref.ThreadID, Cwd: worktree, SessionState: encode(nil), Settings: encode(map[string]any{}),
		CreatedAt: fixtureAt, UpdatedAt: fixtureAt,
	}, Tags: []string{"Keep"}, TagEmojis: map[string]string{"Keep": "👩🏽‍💻"}}
	_, err = h.store.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("thread:"+ref.ThreadID, threadRecord); err != nil {
			return err
		}
		return tx.Put("application:"+report.CollectionID+":"+reportID, reportRecord)
	})
	if err != nil {
		t.Fatal(err)
	}

	if err = h.runtime.RefreshApplicationDirectoryTags(ctx); err != nil {
		t.Fatal(err)
	}
	assertReportTags(t, ctx, h, reportID, []string{"Mokusei"}, stale)

	// Delete the source thread through the runtime path. Deleting a thread must
	// refresh Report directory tags after its transaction commits, without a
	// restart or an explicit refresh call.
	if err = h.runtime.DeleteThread(ctx, ref.ThreadID); err != nil {
		t.Fatal(err)
	}
	assertReportTags(t, ctx, h, reportID, []string{"Mokusei"}, stale)
	afterDelete := readReportRecord(t, h, reportID)

	// Repeated refreshes are idempotent: the catalog must not bump revisions or
	// rewrite an unchanged Report.
	for attempt := 0; attempt < 2; attempt++ {
		if err = h.runtime.RefreshApplicationDirectoryTags(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if repeated := readReportRecord(t, h, reportID); !reflect.DeepEqual(repeated, afterDelete) {
		t.Fatalf("repeated directory refresh rewrote the Report: %+v -> %+v", afterDelete, repeated)
	}
}

func readReportRecord(t *testing.T, h *harness, reportID string) model.VersionedRecord {
	t.Helper()
	var record model.VersionedRecord
	exists, err := h.store.Snapshot().Get("application:"+report.CollectionID+":"+reportID, &record)
	if err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("Report record disappeared")
	}
	return record
}

func assertReportTags(t *testing.T, ctx context.Context, h *harness, reportID string, want []string, forbidden string) {
	t.Helper()
	var record model.VersionedRecord
	exists, err := h.store.Snapshot().Get("application:"+report.CollectionID+":"+reportID, &record)
	if err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("refresh lost the Report record")
	}
	value, err := report.ParseData(record.Value)
	if err != nil {
		t.Fatal(err)
	}
	projection := report.ProjectTags(value)
	if len(projection.DirectoryTags) != len(want) {
		t.Fatalf("DirectoryTags = %v, want %v", projection.DirectoryTags, want)
	}
	for index := range want {
		if projection.DirectoryTags[index] != want[index] {
			t.Fatalf("DirectoryTags = %v, want %v", projection.DirectoryTags, want)
		}
	}
	for _, tag := range projection.DirectoryTags {
		if tag == forbidden {
			t.Fatalf("stale worktree tag survived: %v", projection.DirectoryTags)
		}
	}
	// The catalog is the Overview's read path; it must agree with report.read.
	catalog, err := h.host.Catalog(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, entry := range catalog {
		if entry.ID != reportID {
			continue
		}
		found = true
		if len(entry.Tags.DirectoryTags) != len(want) {
			t.Fatalf("catalog DirectoryTags = %v, want %v", entry.Tags.DirectoryTags, want)
		}
		for index := range want {
			if entry.Tags.DirectoryTags[index] != want[index] {
				t.Fatalf("catalog DirectoryTags = %v, want %v", entry.Tags.DirectoryTags, want)
			}
		}
	}
	if !found {
		t.Fatal("refresh lost the Report")
	}
}

func findGit(t *testing.T) string {
	t.Helper()
	path, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	return path
}

func initGitRepository(t *testing.T, git, root string) {
	t.Helper()
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitCommand(t, git, root, "init", "-q")
	runGitCommand(t, git, root, "config", "user.email", "test@example.com")
	runGitCommand(t, git, root, "config", "user.name", "Mokusei Test")
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGitCommand(t, git, root, "add", "README.md")
	runGitCommand(t, git, root, "commit", "-qm", "fixture")
}

func runGitCommand(t *testing.T, git, directory string, args ...string) {
	t.Helper()
	command := exec.Command(git, append([]string{"-C", directory}, args...)...)
	command.Env = append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, output)
	}
}
