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

const (
	removing     = "removing"
	unregistered = "unregistered"
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
	if m.paths.RegistryPath == "" {
		return "", errors.New("durable worktree ownership registry required for removal")
	}
	if t.Worktree == nil {
		return "", errors.New("thread has no managed worktree to remove")
	}
	cwd := t.Worktree.Cwd
	retired := t.Worktree.RemovedCwd != ""
	if retired {
		cwd = t.Worktree.RemovedCwd
	}
	var proof ownershipProof
	for _, p := range m.proofs {
		if p.OwnerThreadID == t.ID && p.Snapshot.ExecutionCwd == cwd {
			proof = p
			break
		}
	}
	if retired && proof.RemovalStage == "" {
		return "", plugin.CallerError(fmt.Errorf("managed worktree already removed for %s", cwd))
	}
	if proof.OwnerThreadID == "" {
		return "", plugin.CallerError(errors.New("managed worktree lacks matching Thread ownership"))
	}
	s := proof.Snapshot
	rel, err := filepath.Rel(s.Root, cwd)
	if err != nil || !within(s.Root, cwd) || filepath.Join(s.BaseRoot, rel) != t.Cwd {
		return "", errors.New("Thread base directory differs from worktree ownership proof")
	}
	if proof.RemovalStage != "" {
		root, err := m.removalOutcome(ctx, proof)
		if root != "" || err != nil {
			return root, err
		}
		if retired {
			return "", errors.New("a Git registration occupies the retired path; retained")
		}
	}
	if err := checkWorkspaceUsers(s, protected); err != nil {
		return "", err
	}
	present, err := exists(s.Root)
	if err != nil {
		return "", err
	}
	if present {
		// Removal belongs to the proven root, even if a commit renamed the
		// original execution subdirectory. Normal execution still needs its cwd.
		rootTree := model.Worktree{Cwd: s.Root}
		t.Cwd, t.Worktree = s.BaseRoot, &rootTree
		if err := m.validatePaths(ctx, t); err != nil {
			return "", err
		}
		expected := s
		expected.ExecutionCwd, expected.ExecutionCwdIdentity = s.Root, s.Identity
		head := ""
		if proof.InitialGrantPending {
			head = proof.CreationHeadOID
		}
		s, err = inspect(ctx, s.BaseRoot, rootTree, head, &expected)
	} else if proof.RemovalStage == removing {
		s.HeadOID, err = inspectRemainingRegistration(ctx, s)
	} else {
		return "", errors.New("checkout missing without a recorded removal intent; registration retained")
	}
	if err != nil {
		return "", err
	}
	intentHead := s.HeadOID
	if proof.RemovalStage == removing {
		intentHead = proof.CurrentHeadOID
	}
	if err := verifyRecoveryHistory(ctx, s, intentHead); err != nil {
		return "", err
	}
	if err := verifyCheckout(ctx, s, proof.CreatedDirectories, present); err != nil {
		return "", err
	}
	if present {
		if _, err := inspect(ctx, s.BaseRoot, model.Worktree{Cwd: s.Root}, s.HeadOID, &s); err != nil {
			return "", err
		}
	} else {
		head, err := inspectRemainingRegistration(ctx, s)
		if err != nil {
			return "", err
		}
		if head != s.HeadOID {
			return "", errors.New("private HEAD changed during registration recovery; retained")
		}
	}

	if proof.RemovalStage == "" {
		proof.RemovalStage = removing
		proof.CurrentHeadOID = s.HeadOID
		if err := m.recordRemoval(proof); err != nil {
			return "", err
		}
	}
	// A nonzero exit can still mean Git removed the registration. Reconcile
	// before deciding whether this Thread still has an execution workspace.
	_, gitErr := runGit(ctx, s.BaseRoot, "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "status.showUntrackedFiles=all", "worktree", "remove", "--", s.Root)
	root, err := m.removalOutcome(context.WithoutCancel(ctx), proof)
	if root != "" && err == nil {
		return root, nil
	}
	if root == "" && err == nil {
		err = errors.New("Git still registers the worktree; resolve any reported access error and retry this Thread")
	}
	return root, errors.Join(err, gitErr)
}

// Git may remove the checkout before it can unlink its admin files. Without
// the forward .git pointer, authority comes from the persisted intent, exact
// private directory identity, unique registration and surviving backlinks.
func inspectRemainingRegistration(ctx context.Context, s snapshot) (string, error) {
	if present, err := exists(s.Root); err != nil || present {
		return "", errors.Join(err, errors.New("checkout absence cannot be confirmed; registration retained"))
	}
	if err := privateDirectory(s.StagingRoot); err != nil {
		return "", err
	}
	if filepath.Dir(s.GitDirectory) != filepath.Join(s.CommonDirectory, "worktrees") || filepath.Dir(s.Root) != s.StagingRoot {
		return "", errors.New("unexpected linked worktree registration path")
	}
	for _, entry := range []struct {
		path string
		id   directoryIdentity
	}{
		{s.GitDirectory, s.GitDirectoryIdentity}, {s.CommonDirectory, s.CommonDirectoryIdentity},
		{s.StagingRoot, s.StagingRootIdentity}, {s.BaseRoot, s.BaseRootIdentity}, {s.ObjectDirectory, s.ObjectDirectoryIdentity},
	} {
		real, err := canonical(entry.path)
		if err != nil {
			return "", err
		}
		if real != entry.path {
			return "", fmt.Errorf("registration path changed; retained: %s", entry.path)
		}
		if err := assertIdentity(entry.path, entry.id); err != nil {
			return "", err
		}
	}
	for _, pointer := range []struct{ name, target string }{{"gitdir", filepath.Join(s.Root, ".git")}, {"commondir", s.CommonDirectory}} {
		body, err := readRegular(filepath.Join(s.GitDirectory, pointer.name), 64<<10)
		if err != nil {
			return "", err
		}
		value := strings.TrimSuffix(string(body), "\n")
		if filepath.Clean(value) != value || resolve(s.GitDirectory, value) != pointer.target {
			return "", fmt.Errorf("private %s pointer changed; registration retained", pointer.name)
		}
	}
	if present, err := exists(s.PackedRefsLock); err != nil || present {
		return "", errors.Join(err, errors.New("cannot verify unlocked shared refs"))
	}
	if err := assertRegistered(ctx, s.BaseRoot, s.Root); err != nil {
		return "", err
	}
	head, err := readRegular(filepath.Join(s.GitDirectory, "HEAD"), 128)
	if err != nil {
		return "", err
	}
	oid := strings.TrimSuffix(string(head), "\n")
	if len(oid) != len(s.HeadOID) || !oidPattern.MatchString(oid) {
		return "", errors.New("remaining registration lacks a detached HEAD")
	}
	return oid, nil
}

func (m *Manager) recordRemoval(p ownershipProof) error {
	next := cloneProofs(m.proofs)
	next[p.Snapshot.Root] = p
	if err := m.persist(next); err != nil {
		return err
	}
	m.proofs = next
	return nil
}

// A nonempty root means the proven Git registration and admin directory are
// gone: retire execution even if the filesystem retained a checkout remnant.
// No recovery path removes anything from an unregistered directory.
func (m *Manager) removalOutcome(ctx context.Context, p ownershipProof) (string, error) {
	s := p.Snapshot
	base, err := repositoryContext(ctx, s.BaseRoot)
	if err != nil {
		return "", err
	}
	if base.Root != s.BaseRoot || base.CommonDirectory != s.CommonDirectory {
		return "", errors.New("recorded base repository changed")
	}
	for _, entry := range []struct {
		path string
		id   directoryIdentity
	}{
		{base.Root, s.BaseRootIdentity}, {base.CommonDirectory, s.CommonDirectoryIdentity}, {s.StagingRoot, s.StagingRootIdentity},
	} {
		if err := assertIdentity(entry.path, entry.id); err != nil {
			return "", err
		}
	}
	listed, err := registered(ctx, base.Root, s.Root)
	if err != nil {
		return "", err
	}
	metadata, err := exists(s.GitDirectory)
	if err != nil {
		return "", err
	}
	if p.RemovalStage == unregistered && (listed || metadata) {
		return s.Root, fmt.Errorf("Git previously unregistered this worktree; replacement registration or metadata retained for %s", s.Root)
	}
	if listed && metadata {
		return "", nil
	}
	if listed || metadata {
		return "", errors.New("Git registration and admin directory disagree; retained pending removal")
	}
	var stageErr error
	if p.RemovalStage != unregistered {
		p.RemovalStage = unregistered
		if err := m.recordRemoval(p); err != nil {
			stageErr = fmt.Errorf("Git unregistered worktree %s; retry to finish recording removal: %w", s.Root, err)
		}
	}
	present, err := exists(s.Root)
	if err != nil {
		return s.Root, errors.Join(stageErr, err)
	}
	if present {
		return s.Root, errors.Join(stageErr, fmt.Errorf("Git unregistered the worktree; residual path retained at %s. Inspect and relocate the remaining path, then retry", s.Root))
	}
	return s.Root, stageErr
}

// Thread paths are canonical at admission, but the filesystem may be
// case-insensitive. Check ancestor identities before retiring a shared root.
func checkWorkspaceUsers(s snapshot, paths []string) error {
	seen := map[string]bool{}
	for _, path := range paths {
		if path == "" {
			continue
		}
		if within(s.Root, path) || within(s.GitDirectory, path) {
			return plugin.CallerError(fmt.Errorf("worktree is still used by another workspace: %s", path))
		}
		// An absent leaf may still have an existing parent reached by alias.
		var resolved string
		var err error
		for ancestor := path; ; ancestor = filepath.Dir(ancestor) {
			resolved, err = filepath.EvalSymlinks(ancestor)
			if !errors.Is(err, os.ErrNotExist) || ancestor == filepath.Dir(ancestor) {
				break
			}
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
			if id == s.Identity || id == s.GitDirectoryIdentity {
				return plugin.CallerError(fmt.Errorf("worktree is still used by another workspace: %s", path))
			}
		}
	}
	return nil
}
