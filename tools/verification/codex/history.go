package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

// Real Runtime/SQLite plus an external protocol peer and a real background child.
// No user profile, installed CLI, account or model request is involved.
func verifyBackgroundHistory(ctx context.Context, root, binary string) error {
	for _, mode := range []string{"hook", "live", "natural", "fail", "pending", "unknown", "crash"} {
		if err := verifyBackgroundCase(ctx, filepath.Join(root, mode), binary, mode); err != nil {
			return fmt.Errorf("background %s: %w", mode, err)
		}
	}
	return verifyStaleHistory(ctx, filepath.Join(root, "stale"))
}

func backgroundRuntime(ctx context.Context, root string) (*core.Runtime, *store.Store, *codex.Adapter, error) {
	env, err := isolatedEnvironment(root)
	if err != nil {
		return nil, nil, nil, err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	adapter := codex.New(host(root, env))
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		return nil, nil, nil, err
	}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"codex": adapter}, DataDir: root, DefaultCwd: filepath.Join(root, "work")})
	return r, db, adapter, err
}
func waitBackground(ctx context.Context, r *core.Runtime, id string, expected bool) (model.ThreadRecord, error) {
	for {
		t, err := r.Thread(id)
		if err != nil {
			return t, err
		}
		if t.Observation.LatestExecution != nil && t.Observation.LatestExecution.Terminal() && (t.Observation.BackgroundWork != nil) == expected {
			return t, nil
		}
		select {
		case <-ctx.Done():
			return t, ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}
func backgroundChild(root string) (int, error) {
	b, err := os.ReadFile(filepath.Join(root, "background.pid"))
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(string(b))
}
func childStopped(ctx context.Context, pid int) error {
	for {
		err := syscall.Kill(pid, 0)
		if errors.Is(err, syscall.ESRCH) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("cannot confirm fixture child exit: %w", err)
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("background child %d survived cleanup", pid)
		case <-time.After(10 * time.Millisecond):
		}
	}
}
func verifyBackgroundCase(ctx context.Context, root, binary, mode string) error {
	lifetime := ctx
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	r, db, a, err := backgroundRuntime(lifetime, root)
	if err != nil {
		return err
	}
	defer db.Close()
	defer a.Close()
	defer r.Close(context.Background())
	settings := object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "ask-for-approval"}
	c, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "codex", Cwd: filepath.Join(root, "work"), Settings: encoded(settings), Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "fixture-background:" + mode}}}})
	if err != nil {
		return err
	}
	t, err := waitBackground(ctx, r, c.Record.ID, mode != "hook")
	if err != nil {
		return err
	}
	// Hook is turn scoped. A listed background command remains live after the turn.
	activities := list(record(list(decoded(t.SessionState)["turns"])[0])["activities"])
	if len(activities) == 0 || record(activities[0])["status"] != "cancelled" {
		return fmt.Errorf("terminal Hook was not retired: %s", t.SessionState)
	}
	if mode == "hook" {
		_, err = r.Invoke(ctx, "history:clear", nil)
		return err
	}
	pid, err := backgroundChild(root)
	if err != nil {
		return err
	}
	if err = check(syscall.Kill(pid, 0) == nil, "live background fixture was retired prematurely"); err != nil {
		return err
	}
	before := t.Observation.LatestExecution
	switch mode {
	case "natural":
		if err = os.WriteFile(filepath.Join(root, "complete-background"), []byte("done"), 0600); err != nil {
			return err
		}
		for {
			t, err = r.Thread(t.ID)
			if err != nil {
				return err
			}
			e := t.Observation.LatestExecution
			if e != nil && e.ExecutionID != before.ExecutionID && e.Terminal() && t.Observation.BackgroundWork == nil {
				break
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(10 * time.Millisecond):
			}
		}
		if t.Observation.LatestExecution.Summary == nil || *t.Observation.LatestExecution.Summary != "Background reported" {
			return fmt.Errorf("natural completion did not continue the task")
		}
	case "live":
		if err = r.InterruptThread(ctx, t.ID); err != nil {
			return err
		}
		t, err = waitBackground(ctx, r, t.ID, false)
		if err != nil {
			return err
		}
		if err = childStopped(ctx, pid); err != nil {
			return err
		}
		// Give the completion queue an opportunity to attempt a forbidden successor.
		time.Sleep(100 * time.Millisecond)
		t, err = r.Thread(t.ID)
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(before, t.Observation.LatestExecution) {
			return fmt.Errorf("explicit stop admitted a successor or rewrote terminal execution")
		}
		// The same owner can accept fresh user work after the stop.
		if _, err = r.SendThread(ctx, t.ID, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "fixture-background:hook"}}}); err != nil {
			return err
		}
		if _, err = waitBackground(ctx, r, t.ID, false); err != nil {
			return err
		}
	case "fail", "pending", "unknown":
		stopCtx, cancel := context.WithTimeout(ctx, 250*time.Millisecond)
		err = r.InterruptThread(stopCtx, t.ID)
		cancel()
		if err == nil {
			return fmt.Errorf("unconfirmed cancellation returned success")
		}
		t, err = r.Thread(t.ID)
		if err != nil {
			return err
		}
		if t.Observation.BackgroundWork == nil || syscall.Kill(pid, 0) != nil {
			return fmt.Errorf("failed cancellation discarded live work")
		}
		if !reflect.DeepEqual(before, t.Observation.LatestExecution) {
			return fmt.Errorf("failed cancellation changed terminal execution")
		}
	case "crash":
		if err = os.WriteFile(filepath.Join(root, "crash-background"), []byte("exit"), 0600); err != nil {
			return err
		}
		retireCtx, retireCancel := context.WithTimeout(ctx, 6*time.Second)
		_, err = waitBackground(retireCtx, r, t.ID, false)
		retireCancel()
		if err != nil {
			// macOS can deny a group probe even after the fixture child exited.
			// A permission error is uncertainty, never evidence authorizing deletion.
			stopErr := r.InterruptThread(lifetime, t.ID)
			if stopErr == nil || !errors.Is(stopErr, syscall.EPERM) {
				return fmt.Errorf("crash retirement: %w; native close: %v", err, stopErr)
			}
			if err = childStopped(lifetime, pid); err != nil {
				return err
			}
			clearErr := r.ClearHistory(lifetime)
			if clearErr == nil || !errors.Is(clearErr, syscall.EPERM) {
				return fmt.Errorf("uncertain process cleanup allowed clear: %v", clearErr)
			}
			retained, readErr := r.Thread(t.ID)
			if readErr != nil || retained.Observation.BackgroundWork == nil {
				return fmt.Errorf("uncertain crash cleanup discarded history")
			}
			fmt.Println("PASS crash with EPERM liveness uncertainty: native close/clear preserve cause and history despite fixture child exit")
			return nil
		}
		if err = childStopped(ctx, pid); err != nil {
			return err
		}
	}
	// Clear stops even a cancellation-refusing peer by joining its owned process.
	if _, err = r.Invoke(ctx, "history:clear", nil); err != nil {
		return err
	}
	if err = childStopped(ctx, pid); err != nil {
		return err
	}
	if _, err = r.Thread(t.ID); err == nil {
		return fmt.Errorf("successful clear retained old thread")
	}
	threads, err := r.Threads()
	if err != nil {
		return err
	}
	if len(threads) != 1 || !threads[0].Moku {
		return fmt.Errorf("clear did not atomically replace history with Moku shell")
	}
	fmt.Println("PASS native background", mode, "through real Runtime/SQLite: stop confirmation, owned child drain, history replacement")
	return nil
}

func verifyStaleHistory(ctx context.Context, root string) error {
	r, db, a, err := backgroundRuntime(ctx, root)
	if err != nil {
		return err
	}
	defer db.Close()
	defer a.Close()
	defer r.Close(context.Background())
	at := time.Now().UnixMilli()
	state := codex.StageExecution(codex.EmptyState(at), "old-execution", object{"parts": []any{object{"kind": "text", "text": "old task"}}}, at+1, object{})
	state = codex.ReduceEvent(state, "old-execution", object{"type": "activity-start", "activity": object{"id": "stale-hook", "kind": "hook", "label": "PreToolUse"}, "at": at + 2})
	state = codex.ReduceEvent(state, "old-execution", object{"type": "done", "outcome": "interrupted", "at": at + 3})
	// Reproduce the exact old shape: interrupted execution, no terminals, running Hook.
	record(list(record(list(state["turns"])[0])["activities"])[0])["status"] = "running"
	observation, err := a.SessionState().Project(encoded(state))
	if err != nil {
		return err
	}
	if observation.BackgroundWork == nil {
		return fmt.Errorf("stale screenshot fixture did not reproduce running background projection")
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "stale-thread", HarnessID: "codex", CreatedAt: at, UpdatedAt: at + 3, Settings: encoded(object{}), SessionState: encoded(state), Observation: observation}, Title: "stale task", Tags: []string{}}
	private := plugin.PrivateSessionSnapshot{Ref: plugin.PrivateSessionRef{Owner: plugin.BackgroundAgentRef{PluginID: "fixture", AgentID: "tag-agent", Binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}, SessionKey: "fixture", SessionID: "stale-private"}, Record: thread.SessionRecord}
	private.Record.ID = private.Ref.SessionID
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("thread:"+thread.ID, thread); err != nil {
			return err
		}
		if err := tx.SetOrder("threads", []string{thread.ID}); err != nil {
			return err
		}
		if err := tx.Put("private-session:tag-agent:fixture", private); err != nil {
			return err
		}
		if err := tx.Put("private-session-index:stale-private", "private-session:tag-agent:fixture"); err != nil {
			return err
		}
		return tx.Put("tag-receipt:old", object{"fixture": true})
	})
	if err != nil {
		return err
	}
	settingsBefore, rev, err := r.Settings()
	if err != nil {
		return err
	}
	// The context was cancelled before any preparation: all records stay intact.
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if err = r.ClearHistory(cancelled); err == nil {
		return fmt.Errorf("cancelled clear succeeded")
	}
	if !db.Snapshot().Has("thread:stale-thread") || !db.Snapshot().Has("private-session:tag-agent:fixture") {
		return fmt.Errorf("cancelled clear partially deleted history")
	}
	if _, err = r.Invoke(ctx, "history:clear", nil); err != nil {
		return err
	}
	for _, prefix := range []string{"private-session:", "private-session-index:", "tag-receipt:"} {
		if len(db.Snapshot().Keys(prefix)) != 0 {
			return fmt.Errorf("clear left %s", prefix)
		}
	}
	if db.Snapshot().Has("thread:stale-thread") {
		return fmt.Errorf("stale public thread survived clear")
	}
	settingsAfter, afterRev, err := r.Settings()
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(settingsBefore, settingsAfter) || rev != afterRev {
		return fmt.Errorf("history clear changed user settings")
	}
	// Unknown Harness ownership is uncertain, so never simply remove its guard.
	thread.ID = "unknown-owner"
	thread.HarnessID = "missing"
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("thread:"+thread.ID, thread); err != nil {
			return err
		}
		return tx.SetOrder("threads", append(tx.Order("threads"), thread.ID))
	})
	if err != nil {
		return err
	}
	if err = r.ClearHistory(ctx); err == nil || !strings.Contains(err.Error(), "history was kept") {
		return fmt.Errorf("unknown owner did not fail safely: %v", err)
	}
	if !db.Snapshot().Has("thread:unknown-owner") {
		return fmt.Errorf("unknown ownership history was deleted")
	}
	fmt.Println("PASS screenshot-shaped stale Hook and lost private session reclaimed; cancelled/unknown-owner clear preserves history and settings")
	return nil
}
