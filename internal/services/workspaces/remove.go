package workspaces

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Chief/internal/core/model"
	"github.com/hupao-creator/Chief/internal/core/plugin"
)

// RemoveManaged leaves the proof in place until Runtime has durably retired
// the Thread's execution cwd. A retry after Git succeeded can finish that
// metadata write, but can never remove a replacement at the old path.
func (m *Manager) RemoveManaged(ctx context.Context, t model.ThreadRecord, protected []string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.usable(); err != nil {
		return "", err
	}
	if t.Worktree == nil || t.Worktree.Cwd == "" {
		return "", errors.New("thread has no managed worktree to remove")
	}
	var proof ownershipProof
	for _, p := range m.proofs {
		if p.OwnerThreadID == t.ID && p.Snapshot.ExecutionCwd == t.Worktree.Cwd {
			proof = p
			break
		}
	}
	if proof.OwnerThreadID == "" {
		return "", plugin.CallerError(errors.New("managed worktree lacks matching Thread ownership"))
	}
	if _, err := os.Lstat(proof.Snapshot.Root); errors.Is(err, os.ErrNotExist) {
		return confirmAbsent(ctx, t.Cwd, proof.Snapshot)
	}
	if err := m.validatePaths(ctx, t); err != nil {
		return "", err
	}
	request := requestFor(t)
	s, _, err := m.inspectOwned(ctx, request, "observe")
	if err != nil {
		return "", err
	}
	if err := checkWorkspaceUsers(s, protected); err != nil {
		return "", err
	}
	if err := removableContents(ctx, s); err != nil {
		return "", err
	}
	if _, err := inspect(ctx, t.Cwd, *t.Worktree, s.HeadOID, &s); err != nil {
		return "", err
	}
	// Git rechecks registration, the lock and ordinary dirty state. Never
	// escalate to --force or prune a missing/locked sibling.
	if _, err := runGit(ctx, s.BaseRoot, "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "status.showUntrackedFiles=all", "worktree", "remove", "--", s.Root); err != nil {
		return "", err
	}
	return confirmAbsent(context.WithoutCancel(ctx), t.Cwd, s)
}

// Git may have finished before the database commit or before cancellation
// was observed. Only reconcile absence against the recorded base repository.
func confirmAbsent(ctx context.Context, cwd string, s snapshot) (string, error) {
	base, err := repositoryContext(ctx, cwd)
	if err != nil {
		return "", err
	}
	if base.Root != s.BaseRoot || base.CommonDirectory != s.CommonDirectory {
		return "", errors.New("recorded base repository changed")
	}
	if err := assertIdentity(base.Root, s.BaseRootIdentity); err != nil {
		return "", err
	}
	if err := assertIdentity(base.CommonDirectory, s.CommonDirectoryIdentity); err != nil {
		return "", err
	}
	listed, err := registered(ctx, base.Root, s.Root)
	if err != nil {
		return "", err
	}
	metadata, err := exists(s.GitDirectory)
	if err != nil {
		return "", err
	}
	present, err := exists(s.Root)
	if err != nil {
		return "", err
	}
	if listed || metadata || present {
		return "", fmt.Errorf("worktree directory or Git registration still present: %s", s.Root)
	}
	return s.Root, nil
}

// Thread paths are canonical at admission, but the filesystem may be
// case-insensitive. Check ancestor identities before retiring a shared root.
func checkWorkspaceUsers(s snapshot, paths []string) error {
	seen := map[string]bool{}
	for _, path := range paths {
		if path == "" {
			continue
		}
		if within(s.Root, path) {
			return plugin.CallerError(fmt.Errorf("worktree is still used by another workspace: %s", path))
		}
		resolved, err := filepath.EvalSymlinks(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		for dir := resolved; !seen[dir]; dir = filepath.Dir(dir) {
			seen[dir] = true
			id, err := directoryID(dir)
			if err != nil {
				return err
			}
			if id == s.Identity {
				return plugin.CallerError(fmt.Errorf("worktree is still used by another workspace: %s", path))
			}
		}
	}
	return nil
}

func removableContents(ctx context.Context, s snapshot) error {
	for _, name := range []string{"locked", "index.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_START", "rebase-apply", "rebase-merge", "sequencer"} {
		present, err := exists(filepath.Join(s.GitDirectory, name))
		if err != nil {
			return err
		}
		if present {
			return plugin.CallerError(fmt.Errorf("worktree is locked or has Git work in progress (%s)", name))
		}
	}
	files, err := runGit(ctx, s.Root, "ls-files", "-v", "-z")
	if err != nil {
		return err
	}
	for file := range strings.SplitSeq(files, "\x00") {
		if file != "" && (file[0] == 'S' || file[0] >= 'a' && file[0] <= 'z') {
			return plugin.CallerError(errors.New("worktree index hides changes with skip-worktree or assume-unchanged"))
		}
	}
	status, err := runGit(ctx, s.Root, "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none")
	if err != nil {
		return err
	}
	if status != "" {
		return plugin.CallerError(errors.New("worktree contains uncommitted, untracked or ignored files"))
	}
	// The worktree's private HEAD reflog disappears on removal, including a
	// previous tip after an amend or reset. Shared branches and tags survive.
	reflog, err := runGit(ctx, s.Root, "reflog", "show", "--no-show-signature", "--format=%H", "HEAD")
	if err != nil {
		return err
	}
	args := []string{"--no-replace-objects", "rev-list", "--max-count=1", s.HeadOID}
	for _, oid := range strings.Fields(reflog) {
		if !oidPattern.MatchString(oid) {
			return errors.New("cannot verify worktree HEAD reflog")
		}
		args = append(args, oid)
	}
	args = append(args, "--glob=refs/worktree/*", "--not", "--branches", "--tags", "--remotes", "--")
	unreachable, err := runGit(ctx, s.Root, args...)
	if err != nil {
		return err
	}
	if unreachable != "" {
		return plugin.CallerError(fmt.Errorf("worktree commit %s is not retained by a branch or tag", unreachable))
	}
	return nil
}
