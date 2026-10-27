package workspaces

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// loadRecoveryCandidates performs no Git commands or filesystem traversal of
// worktrees. Only the private registry itself is read/atomically pruned. Missing
// directories and changed identities are checked at the first real use.
func (m *Manager) loadRecoveryCandidates(ctx context.Context, records []PersistedOwner) []RecoveryFailure {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.loaded {
		if len(m.proofs) > 0 {
			return []RecoveryFailure{{Err: errors.New("ownership registry already initialized")}}
		}
		return nil
	}
	loaded, err := m.load()
	m.loaded = true
	if err != nil {
		m.registryErr = err
		return []RecoveryFailure{{Err: fmt.Errorf("ownership registry unavailable: %w", err)}}
	}
	proofOwners := map[string]int{}
	proofRoots := map[string]int{}
	byOwner := map[string]ownershipProof{}
	for _, p := range loaded.Entries {
		proofOwners[p.OwnerThreadID]++
		proofRoots[p.Snapshot.Root]++
		byOwner[p.OwnerThreadID] = p
	}
	ownerCounts := map[string]int{}
	rootCounts := map[string]int{}
	claimedRoots := make([]string, len(records))
	for i, r := range records {
		ownerCounts[r.OwnerThreadID]++
		if !recoveryPath(r.Worktree.Cwd) {
			continue
		}
		// Walk lexical parents, never resolve symlinks or query Git here. A
		// conflicting claim to a subdirectory must still count against its root.
		for path := r.Worktree.Cwd; ; path = filepath.Dir(path) {
			if proofRoots[path] > 0 {
				claimedRoots[i] = path
				rootCounts[path]++
				break
			}
			if filepath.Dir(path) == path {
				break
			}
		}
	}
	var failures []RecoveryFailure
	next := map[string]ownershipProof{}
	pending := map[string]bool{}
	for i, r := range records {
		p, exists := byOwner[r.OwnerThreadID]
		err = ownerID(r.OwnerThreadID)
		if err == nil && (ownerCounts[r.OwnerThreadID] != 1 || rootCounts[claimedRoots[i]] != 1) {
			err = errors.New("trusted managed owner/root is not unique")
		}
		if err == nil && (!exists || proofOwners[r.OwnerThreadID] != 1 || proofRoots[p.Snapshot.Root] != 1 || claimedRoots[i] != p.Snapshot.Root) {
			err = errors.New("managed worktree lacks unique exact owner/root proof")
		}
		if err == nil && (!recoveryPath(r.BaseCwd) || r.Worktree.Cwd != p.Snapshot.ExecutionCwd || !within(p.Snapshot.BaseRoot, r.BaseCwd)) {
			err = errors.New("persisted worktree paths differ from Core ownership proof")
		}
		if err != nil {
			failures = append(failures, RecoveryFailure{r.OwnerThreadID, err})
			continue
		}
		next[p.Snapshot.Root] = p
		pending[p.Snapshot.Root] = true
	}
	if err = ctx.Err(); err != nil {
		m.registryErr = err
		return append(failures, RecoveryFailure{Err: err})
	}
	if err = m.persist(next); err != nil {
		m.registryErr = err
		return append(failures, RecoveryFailure{Err: fmt.Errorf("ownership candidate prune: %w", err)})
	}
	m.proofs, m.pendingRecovery = next, pending
	return failures
}

func recoveryPath(path string) bool {
	return len(path) <= 16384 && filepath.IsAbs(path) && filepath.Clean(path) == path && !strings.ContainsRune(path, 0)
}
