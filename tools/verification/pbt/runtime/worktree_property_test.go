package runtime_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/hupao-creator/Chief/internal/core/model"
	"github.com/hupao-creator/Chief/internal/core/plugin"
	core "github.com/hupao-creator/Chief/internal/core/runtime"
	"github.com/hupao-creator/Chief/internal/core/store"
	"github.com/hupao-creator/Chief/internal/platform/sqlite"
	"github.com/hupao-creator/Chief/internal/services/moku"
	"github.com/hupao-creator/Chief/internal/services/workspaces"
	"github.com/hupao-creator/Chief/tools/verification/pbt/rapidcheck"
	"pgregory.net/rapid"
)

// The peer only supplies a model catalog and captures the tools actually
// injected at Open. Tool selection, authorization, persistence and Git are real.
type worktreePeer struct {
	harness
	tools *plugin.ToolInjection
}

func (h *worktreePeer) DiscoverMokuTarget(context.Context, plugin.SettingsRequest) (json.RawMessage, plugin.Availability, error) {
	schema, err := plugin.ModelCatalogSchema(map[string]any{"type": "object"}, []plugin.ModelCatalogEntry{{ID: "fixture"}}, "fixture", plugin.CatalogSourceEvidence{})
	return schema, plugin.Availability{Available: true}, err
}
func (h *worktreePeer) Open(ctx context.Context, o plugin.OpenContext) (plugin.Handle, error) {
	if o.Injection != nil {
		h.tools = o.Injection.Tools
	}
	return &handle{open: o, ctx: ctx}, nil
}

func openWorktreeChief(t *rapid.T, ctx context.Context, r *core.Runtime, chiefCwd string, harnesses map[string]plugin.Harness, peer *worktreePeer, input model.AgentInput) (*moku.Coordinator, plugin.ToolBinding) {
	t.Helper()
	coordinator, err := moku.New(moku.Configuration{
		Workspace: chiefCwd, Harnesses: harnesses, Settings: r.Settings, Threads: r.Threads, Thread: r.Thread, UpdateThread: r.UpdateThread,
		OpenSession: r.OpenMokuThread, CloseSession: r.CloseMokuThread, SendSession: r.SendMokuThread, SubscribeCommitted: r.OnThreadCommitted,
		RemoveWorktree: r.RemoveWorktree, PendingDeliveries: r.ReadyMokuDeliveries, SendDelivery: r.SendMokuDelivery,
		EnsureSession: func(ctx context.Context, c moku.SessionConfiguration) (model.ThreadRecord, error) {
			return r.EnsureMokuThread(ctx, c.HarnessID, c.Settings, c.Cwd)
		},
		ReplaceSession: func(context.Context, string, moku.SessionConfiguration) (model.ThreadRecord, error) {
			return model.ThreadRecord{}, errors.New("unexpected replacement")
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Start(ctx, plugin.RuntimeStartContext{}); err != nil {
		t.Fatal(err)
	}

	if err := coordinator.Submit(ctx, moku.SubmitRequest{Input: input}); err != nil {
		t.Fatal(err)
	}
	var tool plugin.ToolBinding
	if peer.tools == nil || peer.tools.Mode != "exclusive" {
		t.Fatal("missing Chief injection")
	}
	for _, binding := range peer.tools.Bindings {
		if binding.Name == "remove_worktree" {
			tool = binding
		}
	}
	if tool.Execute == nil {
		t.Fatal("remove_worktree missing from Chief injection")
	}
	return coordinator, tool
}

func TestRemoveWorktreeProperties(t *testing.T) {
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	rapidcheck.Check(t, func(t *rapid.T) {
		ctx := context.Background()
		check := func(err error) {
			t.Helper()
			if err != nil {
				t.Fatal(err)
			}
		}
		tmp, err := os.MkdirTemp("", "mokusei-remove-worktree-")
		check(err)
		defer os.RemoveAll(tmp)
		tmp, err = filepath.EvalSymlinks(tmp)
		check(err)
		git := func(cwd string, args ...string) string {
			t.Helper()
			cmd := exec.Command("git", args...)
			cmd.Dir = cwd
			cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=" + os.DevNull}
			out, err := cmd.Output()
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				t.Fatalf("git %q: %v: %s", args, err, exit.Stderr)
			}
			check(err)
			return strings.TrimSuffix(string(out), "\n")
		}
		write := func(path, value string) { check(os.WriteFile(path, []byte(value), 0600)) }
		repo := filepath.Join(tmp, "repo")
		base := filepath.Join(repo, "sub")
		check(os.MkdirAll(base, 0700))
		git(repo, "init", "-q", "-b", "main")
		git(repo, "config", "user.name", "Fixture")
		git(repo, "config", "user.email", "fixture@example.invalid")
		write(filepath.Join(base, "tracked"), "base\n")
		write(filepath.Join(repo, ".gitignore"), "ignored\n")
		check(os.Symlink("sub/tracked", filepath.Join(repo, "link")))
		git(repo, "add", ".")
		git(repo, "commit", "-qm", "base")
		mainHead := git(repo, "rev-parse", "HEAD")
		sibling := filepath.Join(tmp, "sibling")
		git(repo, "worktree", "add", "-qb", "sibling", sibling)
		original := git(repo, "worktree", "list", "--porcelain", "-z")

		chiefCwd := filepath.Join(tmp, "chief")
		check(os.Mkdir(chiefCwd, 0700))
		db, err := store.Open(filepath.Join(tmp, "state.sqlite"))
		check(err)
		defer db.Close()
		manager := workspaces.New(workspaces.Paths{MokuCwd: chiefCwd, RegistryPath: filepath.Join(tmp, "owners.json")})
		peer := &worktreePeer{}
		harnesses := map[string]plugin.Harness{"fixture": peer}
		r, err := core.New(ctx, core.Config{Store: db, Harnesses: harnesses, Workspaces: manager, DataDir: tmp, DefaultCwd: tmp})
		check(err)
		defer r.Close(ctx)
		input := model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "fixture"}}}
		enabled := true
		child, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: input, Cwd: base, Worktree: &model.WorktreeOptions{Enabled: &enabled, Name: "review"}})
		check(err)
		id := child.Record.ID
		cwd := child.Record.Worktree.Cwd
		root := filepath.Dir(cwd)

		chief, err := r.EnsureMokuThread(ctx, "fixture", raw(map[string]any{}), chiefCwd)
		check(err)
		coordinator, tool := openWorktreeChief(t, ctx, r, chiefCwd, harnesses, peer, input)
		defer coordinator.Stop(ctx)
		args := map[string]any{"threadId": id}
		call := func(a any) (json.RawMessage, error) { return tool.Execute(ctx, plugin.ToolCall{Arguments: raw(a)}) }
		admin := git(root, "rev-parse", "--absolute-git-dir")
		indexPath := filepath.Join(admin, "index")
		refuse := func(a any, want string) {
			t.Helper()
			before, err := os.Stat(indexPath)
			check(err)
			index, err := os.ReadFile(indexPath)
			check(err)
			_, err = call(a)
			if err == nil || !strings.Contains(err.Error(), want) {
				t.Fatalf("expected refusal containing %q, got %v", want, err)
			}
			after, err := os.ReadFile(indexPath)
			check(err)
			stat, err := os.Stat(indexPath)
			check(err)
			if !bytes.Equal(index, after) || !os.SameFile(before, stat) || !before.ModTime().Equal(stat.ModTime()) {
				t.Fatal("refusal changed the target index")
			}
			if _, err := os.Stat(cwd); err != nil {
				t.Fatalf("refusal lost checkout: %v", err)
			}
		}
		refuse(map[string]any{"threadId": id, "path": repo}, "path")
		refuse(map[string]any{"threadId": id, "force": true}, "force")
		refuse(map[string]any{"threadId": chief.ID}, "ordinary Thread")
		refuse(map[string]any{"threadId": "missing"}, "unknown thread")
		refuse(args, "active work")
		check(r.InterruptThread(ctx, id))

		_, releaseClaim, err := r.ClaimThreadInput(ctx, id)
		check(err)
		refuse(args, "active work")
		releaseClaim()
		check(r.UpdateThread(ctx, id, func(t *model.ThreadRecord) error {
			t.Observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
			return nil
		}))
		refuse(args, "active work")
		check(r.UpdateThread(ctx, id, func(t *model.ThreadRecord) error {
			t.Observation.BackgroundWork = nil
			return nil
		}))

		// A different Thread can explicitly select a subdirectory of this
		// checkout without owning its managed proof.
		other, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: input, Cwd: cwd})
		check(err)
		refuse(map[string]any{"threadId": other.Record.ID}, "ordinary Thread")
		refuse(args, "another workspace")
		check(r.DeleteThread(ctx, other.Record.ID))

		// Git removes private metadata too. Admit a real peer through an alias
		// into the admin tree. Some filesystems also accept a case-only alias.
		adminAlias := filepath.Join(tmp, "peer-alias")
		check(os.Symlink(filepath.Join(admin, "logs"), adminAlias))
		peerDirs := []string{adminAlias}
		upper := filepath.Join(filepath.Dir(admin), strings.ToUpper(filepath.Base(admin)), "logs")
		if _, err := os.Stat(upper); err == nil {
			peerDirs = append(peerDirs, upper)
		}
		for _, dir := range peerDirs {
			peer, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: input, Cwd: dir})
			check(err)
			refuse(args, "another workspace")
			check(r.DeleteThread(ctx, peer.Record.ID))
		}

		// A stale path can name the main checkout or a sibling. A persisted
		// Thread id alone cannot authorize either directory.
		for _, wrong := range []string{repo, sibling} {
			check(r.UpdateThread(ctx, id, func(t *model.ThreadRecord) error {
				t.Worktree = &model.Worktree{Cwd: wrong}
				return nil
			}))
			refuse(args, "ownership")
		}
		check(r.UpdateThread(ctx, id, func(t *model.ThreadRecord) error {
			t.Worktree = child.Record.Worktree
			return nil
		}))

		moved := filepath.Join(tmp, "original-checkout")
		check(os.Rename(root, moved))
		check(os.Symlink(repo, root))
		refuse(args, "canonical identity changed")
		check(os.Remove(root))
		check(os.Rename(moved, root))

		// Snapshot a distinct detached result and keep it reachable by name.
		git(cwd, "commit", "-q", "--allow-empty", "-m", "task result")
		resultHead := git(cwd, "rev-parse", "HEAD")
		refuse(args, "not retained")
		git(cwd, "branch", "saved", resultHead)

		// Recovery sources can be independent of both HEAD and its reflog.
		recoverable := git(repo, "commit-tree", mainHead+"^{tree}", "-p", mainHead, "-m", "private recovery")
		for _, ref := range []string{"ORIG_HEAD", "refs/bisect/review", "refs/rewritten/review", "refs/worktree/review"} {
			git(root, "update-ref", ref, recoverable)
			refuse(args, "not retained")
			if got := git(root, "rev-parse", ref); got != recoverable {
				t.Fatal("lost recovery ref", ref)
			}
			git(root, "update-ref", "-d", ref)
		}
		git(root, "update-ref", "--create-reflog", "refs/worktree/review", recoverable)
		git(root, "update-ref", "refs/worktree/review", mainHead)
		git(root, "reflog", "delete", "refs/worktree/review@{1}")
		edge, err := os.ReadFile(filepath.Join(admin, "logs/refs/worktree/review"))
		check(err)
		if !strings.HasPrefix(string(edge), recoverable+" "+mainHead+" ") || bytes.Count(edge, []byte("\n")) != 1 {
			t.Fatal("fixture lacks an old-only private reflog endpoint")
		}
		refuse(args, "not retained")
		git(root, "update-ref", "-d", "refs/worktree/review")
		git(root, "update-ref", "refs/worktree/review", recoverable)
		git(root, "symbolic-ref", "refs/heads/indirect", "refs/worktree/review")
		refuse(args, "not retained")
		git(root, "symbolic-ref", "--delete", "refs/heads/indirect")
		git(repo, "tag", "-a", "saved-recovery", "-m", "retained", recoverable)
		git(repo, "pack-refs", "--all")

		// Every generated sequence tests each blocker in isolation on the same
		// checkout. A refusal must keep its contents and allow later retries.
		untracked := filepath.Join(cwd, "new")
		tracked := filepath.Join(cwd, "tracked")
		ignored := filepath.Join(cwd, "ignored")
		blob := git(root, "rev-parse", "HEAD:sub/tracked")
		loose := filepath.Join(repo, ".git", "objects", blob[:2], blob[2:])
		savedBlob := filepath.Join(tmp, "saved-blob")
		blockers := rapid.Permutation([]string{"untracked", "tracked", "ignored", "locked", "masked", "skip", "stat", "mode", "type", "filter", "missing-blob"}).Draw(t, "order")

		for _, blocker := range blockers {
			want := "uncommitted, untracked or ignored"
			switch blocker {
			case "untracked":
				write(untracked, "new")
			case "tracked":
				write(tracked, "changed")
				if rapid.Bool().Draw(t, "stage") {
					git(cwd, "add", "tracked")
				}
			case "ignored":
				write(ignored, "scratch")
			case "masked":
				git(cwd, "update-index", "--assume-unchanged", "tracked")
				write(tracked, "private edit")
				want = "index hides changes"
			case "skip":
				git(cwd, "update-index", "--skip-worktree", "tracked")
				want = "index hides changes"
			case "stat":
				git(repo, "config", "core.trustctime", "false")
				git(repo, "config", "core.checkStat", "minimal")
				old := time.Now().Add(-time.Hour).Truncate(time.Second)
				check(os.Chtimes(tracked, old, old))
				git(cwd, "update-index", "--really-refresh")
				write(tracked, "edit\n")
				check(os.Chtimes(tracked, old, old))
			case "mode":
				git(repo, "config", "core.filemode", "false")
				check(os.Chmod(tracked, 0755))
			case "type":
				git(repo, "config", "core.symlinks", "false")
				check(os.Remove(filepath.Join(root, "link")))
				write(filepath.Join(root, "link"), "sub/tracked")
			case "missing-blob":
				check(os.Rename(loose, savedBlob))
				want = "shared Git object store"
			case "filter":
				write(filepath.Join(repo, ".git", "info", "attributes"), "sub/tracked filter=fixture\n")
				want = "checkout conversion"
			case "locked":
				git(repo, "worktree", "lock", root)
				want = "locked"
			}
			refuse(args, want)
			switch blocker {
			case "untracked":
				check(os.Remove(untracked))
			case "tracked":
				git(cwd, "restore", "--staged", "--worktree", "tracked")
			case "ignored":
				check(os.Remove(ignored))
			case "masked":
				git(cwd, "update-index", "--no-assume-unchanged", "tracked")
				git(cwd, "restore", "tracked")
			case "skip":
				git(cwd, "update-index", "--no-skip-worktree", "tracked")
			case "stat":
				write(tracked, "base\n")
				git(repo, "config", "--unset", "core.trustctime")
				git(repo, "config", "--unset", "core.checkStat")
			case "mode":
				check(os.Chmod(tracked, 0644))
				git(repo, "config", "core.filemode", "true")
			case "type":
				check(os.Remove(filepath.Join(root, "link")))
				check(os.Symlink("sub/tracked", filepath.Join(root, "link")))
				git(repo, "config", "core.symlinks", "true")
			case "missing-blob":
				check(os.Rename(savedBlob, loose))
			case "filter":
				check(os.Remove(filepath.Join(repo, ".git", "info", "attributes")))
			case "locked":
				git(repo, "worktree", "unlock", root)
			}
		}
		// A failed intent write must leave Git registration and checkout intact.
		registry := manager.Paths().RegistryPath
		check(os.Chmod(registry, 0644))
		refuse(args, "unsafe registry")
		check(os.Chmod(registry, 0600))
		if git(root, "rev-parse", "HEAD") != resultHead {
			t.Fatal("Git ran without durable intent")
		}

		// Two calls can be in flight for the same Chief execution. Only one
		// may report the successful removal.
		type outcome struct {
			out json.RawMessage
			err error
		}
		outcomes := make(chan outcome, 2)
		for range 2 {
			go func() {
				out, err := call(args)
				outcomes <- outcome{out, err}
			}()
		}
		first, second := <-outcomes, <-outcomes
		if first.err != nil {
			first, second = second, first
		}
		check(first.err)
		if second.err == nil {
			t.Fatal("duplicate removal succeeded")
		}
		out := first.out
		var receipt struct {
			OK                   bool
			ThreadID, AbsentRoot string
		}
		check(json.Unmarshal(out, &receipt))
		if !receipt.OK || receipt.ThreadID != id || receipt.AbsentRoot != root {
			t.Fatalf("unexpected receipt %s", out)
		}
		if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("removed path still present: %v", err)
		}
		if git(repo, "worktree", "list", "--porcelain", "-z") != original || git(repo, "rev-parse", "saved") != resultHead || git(repo, "rev-parse", "main") != mainHead || git(repo, "rev-parse", "saved-recovery^{commit}") != recoverable {
			t.Fatal("lost a sibling, branch or commit")
		}
		after, err := r.Thread(id)
		check(err)
		if after.Cwd != base || after.Worktree == nil || after.Worktree.Cwd != "" || after.Worktree.RemovedCwd != cwd || after.Observation.LatestExecution.ExecutionID != child.Execution.ExecutionID {
			t.Fatal("lost Thread workspace or execution history")
		}
		if _, err = r.SendThread(ctx, id, input); err == nil {
			t.Fatal("removed Thread admitted a follow-up")
		}
		record, err := r.Thread(chief.ID)
		check(err)
		found := false
		for _, row := range record.Transcript {
			var op struct {
				Name, ExecutionID string
				Result            json.RawMessage
			}
			check(json.Unmarshal(row, &op))
			if op.Name == tool.Name && op.ExecutionID == record.Observation.LatestExecution.ExecutionID && string(op.Result) == string(out) {
				found = true
			}
		}
		if !found {
			t.Fatal("missing audited removal receipt")
		}

		// Reuse the name for a new owner. A historical id cannot act on it.
		next, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: input, Cwd: base, Worktree: &model.WorktreeOptions{Enabled: &enabled, Name: "review"}})
		check(err)
		if next.Record.Worktree.Cwd != cwd {
			t.Fatal("fixture did not reuse checkout name")
		}
		refuse(args, "already removed")
		check(r.InterruptThread(ctx, next.Record.ID))
		// Abort the actual retirement write. The name and admin directory
		// remain reserved across calls while the Thread row is still live.
		faults, err := sqlite.Open(db.Path(), false)
		check(err)
		defer faults.Close()
		check(faults.Exec(`CREATE TRIGGER fail_retire BEFORE UPDATE ON records
			WHEN NEW.key LIKE 'thread:%' AND json_extract(CAST(NEW.body AS TEXT),'$.worktree.removedCwd') IS NOT NULL
			BEGIN SELECT RAISE(ABORT,'injected retirement write'); END`))
		nextArgs := map[string]any{"threadId": next.Record.ID}
		expectError := func(args any, want string) {
			t.Helper()
			_, err := call(args)
			if err == nil || !strings.Contains(err.Error(), want) {
				t.Fatalf("expected %q, got %v", want, err)
			}
		}
		expectError(nextArgs, "retry to record removal")
		check(faults.Exec("DROP TRIGGER fail_retire"))
		live, err := r.Thread(next.Record.ID)
		check(err)
		if live.Worktree.Cwd != cwd || git(repo, "worktree", "list", "--porcelain", "-z") != original {
			t.Fatal("unexpected state after retirement write failure")
		}
		createNamed := func(name string) model.ThreadRecord {
			t.Helper()
			created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: input, Cwd: base, Worktree: &model.WorktreeOptions{Enabled: &enabled, Name: name}})
			check(err)
			return created.Record
		}
		concurrent := createNamed("REVIEW")
		if !strings.EqualFold(filepath.Base(filepath.Dir(concurrent.Worktree.Cwd)), "review-2") {
			t.Fatal("pending name was reused")
		}

		// Fail the registry write only after the retirement transaction commits.
		unsubscribe := r.OnThreadCommitted(func(record model.ThreadRecord) {
			if record.ID == next.Record.ID && record.Worktree.RemovedCwd != "" {
				check(os.Chmod(registry, 0644))
			}
		})
		expectError(nextArgs, "retry to retire ownership proof")
		unsubscribe()
		check(os.Chmod(registry, 0600))
		retired, err := r.Thread(next.Record.ID)
		check(err)
		if retired.Worktree.RemovedCwd != cwd || retired.Worktree.Cwd != "" {
			t.Fatal("retirement lost on proof write failure")
		}
		// Restart the actual Runtime, SQLite store and Chief injection. The
		// now-historical Thread must recover its pending proof for cleanup.
		check(coordinator.Stop(ctx))
		check(r.Close(ctx))
		check(db.Close())
		if _, staleErr := call(nextArgs); staleErr == nil {
			t.Fatal("stopped Chief binding authorized a retry")
		}
		db, err = store.Open(filepath.Join(tmp, "state.sqlite"))
		check(err)
		defer db.Close()
		manager = workspaces.New(manager.Paths())
		peer = &worktreePeer{}
		harnesses = map[string]plugin.Harness{"fixture": peer}
		r, err = core.New(ctx, core.Config{Store: db, Harnesses: harnesses, Workspaces: manager, DataDir: tmp, DefaultCwd: tmp})
		check(err)
		defer r.Close(ctx)
		coordinator, tool = openWorktreeChief(t, ctx, r, chiefCwd, harnesses, peer, input)
		defer coordinator.Stop(ctx)
		_, err = call(nextArgs)
		check(err)
		expectError(nextArgs, "already removed")
		if _, err := os.Stat(concurrent.Worktree.Cwd); err != nil {
			t.Fatal("retry touched another owner", err)
		}

		// A real non-force Git removal can unregister the checkout even when
		// it cannot unlink a tracked file. Keep the leftover and retire access.
		partial := createNamed("review")
		if partial.Worktree.Cwd != cwd {
			t.Fatal("completed proof cleanup did not release name")
		}
		check(r.InterruptThread(ctx, partial.ID))
		partialArgs := map[string]any{"threadId": partial.ID}
		check(os.Chmod(cwd, 0500))
		defer os.Chmod(cwd, 0700)
		expectError(partialArgs, "residual path retained")
		check(os.Chmod(cwd, 0700))
		if b, err := os.ReadFile(tracked); err != nil || string(b) != "base\n" {
			t.Fatal("lost partial checkout data", err)
		}
		partialThread, err := r.Thread(partial.ID)
		check(err)
		if partialThread.Worktree.RemovedCwd != cwd {
			t.Fatal("unregistered checkout still reported as executable")
		}
		expectError(partialArgs, "residual path retained")
		check(os.Rename(root, filepath.Join(tmp, "retained-remnant")))
		check(os.Mkdir(root, 0700))
		write(filepath.Join(root, "unrelated"), "new owner")
		expectError(partialArgs, "residual path retained")
		check(os.Rename(root, filepath.Join(tmp, "unrelated-directory")))
		git(repo, "worktree", "add", "--detach", root, mainHead)
		expectError(partialArgs, "replacement registration")
		if git(root, "rev-parse", "HEAD") != mainHead {
			t.Fatal("retry touched replacement registration")
		}
		git(repo, "worktree", "remove", "--", root)
		_, err = call(partialArgs)
		check(err)
		expectError(partialArgs, "already removed")
	})
}
