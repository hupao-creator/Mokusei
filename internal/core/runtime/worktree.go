package runtime

import (
	"context"
	"errors"
	"fmt"

	"github.com/hupao-creator/Chief/internal/core/model"
	"github.com/hupao-creator/Chief/internal/core/plugin"
)

func (r *Runtime) RemoveWorktree(ctx context.Context, id string) (string, error) {
	if err := r.begin(); err != nil {
		return "", err
	}
	defer r.operations.Done()
	ctx, cancel := r.operationContext(ctx)
	defer cancel()
	if r.config.Workspaces == nil {
		return "", errors.New("managed workspace authority unavailable")
	}

	lock := r.threadLock(id)
	if !lock.TryLock() {
		return "", plugin.CallerError(errors.New("thread has a command in progress; retry when it finishes"))
	}
	defer lock.Unlock()
	t, err := r.Thread(id)
	if err != nil {
		return "", err
	}
	if t.Worktree != nil && t.Worktree.RemovedCwd != "" {
		return "", plugin.CallerError(fmt.Errorf("managed worktree already removed for %s", t.Worktree.RemovedCwd))
	}
	if t.Moku || t.MokuHistory || t.Worktree == nil || t.Worktree.Cwd == "" {
		return "", plugin.CallerError(errors.New("select an ordinary Thread with a managed worktree"))
	}
	busy := func(t model.ThreadRecord) bool {
		return t.PendingInput || t.Observation.BackgroundWork != nil || t.Observation.LatestExecution != nil && !t.Observation.LatestExecution.Terminal()
	}
	if busy(t) {
		return "", plugin.CallerError(errors.New("thread still has active work or pending input"))
	}
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	if owner != nil {
		if err := r.retireIdleHandle(ctx, owner, "WORKTREE_BUSY", "worktree owner"); err != nil {
			return "", err
		}
	}
	// Check again after native Close has drained its last callbacks. The
	// command lock excludes opening a successor; this gate excludes new claims.
	state, release := r.cancellationState(id)
	defer release()
	state.mu.Lock()
	defer state.mu.Unlock()
	t, err = r.Thread(id)
	if err != nil {
		return "", err
	}
	if busy(t) || state.cancelling || state.pending() || r.IsDeleting(id) {
		return "", plugin.CallerError(errors.New("thread still has active work or a pending operation"))
	}
	if !r.workspaceMu.TryLock() {
		return "", plugin.CallerError(errors.New("workspace creation or removal is in progress; retry when it finishes"))
	}
	defer r.workspaceMu.Unlock()

	protected, err := r.otherWorkspacePaths(id)
	if err != nil {
		return "", err
	}
	root, err := r.config.Workspaces.RemoveManaged(ctx, t, protected)
	if err != nil {
		return "", err
	}
	finish := context.WithoutCancel(ctx)
	err = r.UpdateThread(finish, id, func(current *model.ThreadRecord) error {
		current.Worktree = &model.Worktree{RemovedCwd: t.Worktree.Cwd}
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("worktree %s is absent; retry to record removal: %w", root, err)
	}
	if err := r.config.Workspaces.Unregister(finish, id, t.Worktree); err != nil {
		return "", fmt.Errorf("worktree %s removed; could not retire ownership proof: %w", root, err)
	}
	return root, nil
}

// Read only workspace references. Unrelated conversation payloads are opaque
// and can be large, especially for archived Threads.
func (r *Runtime) otherWorkspacePaths(id string) ([]string, error) {
	type workspace struct {
		Cwd      string
		Worktree *model.Worktree
	}
	paths := []string{r.config.DataDir, r.config.DefaultCwd}
	view := r.config.Store.Snapshot()
	for _, key := range view.Keys("thread:") {
		if key == "thread:"+id {
			continue
		}
		var other workspace
		if _, err := view.Get(key, &other); err != nil {
			return nil, err
		}
		paths = append(paths, other.Cwd)
		if other.Worktree != nil {
			paths = append(paths, other.Worktree.Cwd)
		}
	}
	for _, key := range view.Keys("private-session:") {
		var session struct{ Record workspace }
		if _, err := view.Get(key, &session); err != nil {
			return nil, err
		}
		paths = append(paths, session.Record.Cwd)
	}
	return paths, nil
}
