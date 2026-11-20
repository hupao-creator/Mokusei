package runtime_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hupao-creator/Chief/internal/core/model"
	"github.com/hupao-creator/Chief/internal/core/plugin"
	core "github.com/hupao-creator/Chief/internal/core/runtime"
	"github.com/hupao-creator/Chief/internal/core/store"
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
		check(err)
		check(coordinator.Start(ctx, plugin.RuntimeStartContext{}))
		defer coordinator.Stop(ctx)
		check(coordinator.Submit(ctx, moku.SubmitRequest{Input: input}))
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
		args := map[string]any{"threadId": id}
		call := func(a any) (json.RawMessage, error) { return tool.Execute(ctx, plugin.ToolCall{Arguments: raw(a)}) }
		refuse := func(a any, want string) {
			t.Helper()
			_, err := call(a)
			if err == nil || !strings.Contains(err.Error(), want) {
				t.Fatalf("expected refusal containing %q, got %v", want, err)
			}
			if _, err := os.Stat(cwd); err != nil {
				t.Fatalf("refusal lost checkout: %v", err)
			}
		}
		refuse(map[string]any{"threadId": id, "path": repo}, "path")
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

		// Every generated sequence tests each blocker in isolation on the same
		// checkout. A refusal must keep its contents and allow later retries.
		untracked := filepath.Join(cwd, "new")
		tracked := filepath.Join(cwd, "tracked")
		ignored := filepath.Join(cwd, "ignored")
		blockers := rapid.Permutation([]string{"untracked", "tracked", "ignored", "locked", "masked"}).Draw(t, "order")

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
			case "locked":
				git(repo, "worktree", "unlock", root)
			}
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
		if git(repo, "worktree", "list", "--porcelain", "-z") != original || git(repo, "rev-parse", "saved") != resultHead || git(repo, "rev-parse", "main") != mainHead {
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
		// Reproduce the filesystem/metadata boundary after a lost final write.
		git(repo, "worktree", "remove", "--", root)
		_, err = call(map[string]any{"threadId": next.Record.ID})
		check(err)
		retired, err := r.Thread(next.Record.ID)
		check(err)
		if retired.Worktree == nil || retired.Worktree.RemovedCwd != cwd || git(repo, "worktree", "list", "--porcelain", "-z") != original {
			t.Fatal("retry failed to reconcile the recorded checkout")
		}
	})
}
