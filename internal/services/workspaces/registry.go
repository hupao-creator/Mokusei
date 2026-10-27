package workspaces

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const maxRegistryBytes = 4 * 1024 * 1024
const maxRegistryEntries = 10000

type registry struct {
	Version int              `json:"version"`
	Entries []ownershipProof `json:"entries"`
}

func cloneProofs(in map[string]ownershipProof) map[string]ownershipProof {
	out := make(map[string]ownershipProof, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
func (m *Manager) persist(proofs map[string]ownershipProof) error {
	if len(proofs) > maxRegistryEntries {
		return errors.New("worktree registry exceeds entry limit")
	}
	if m.paths.RegistryPath == "" {
		return nil
	}
	entries := make([]ownershipProof, 0, len(proofs))
	for _, p := range proofs {
		entries = append(entries, p)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Snapshot.Root == entries[j].Snapshot.Root {
			return entries[i].OwnerThreadID < entries[j].OwnerThreadID
		}
		return entries[i].Snapshot.Root < entries[j].Snapshot.Root
	})
	body, err := json.Marshal(registry{Version: 1, Entries: entries})
	if err != nil {
		return err
	}
	if len(body) > maxRegistryBytes {
		return errors.New("worktree registry exceeds byte limit")
	}
	return atomicPrivate(m.paths.RegistryPath, body)
}
func (m *Manager) load() (registry, error) {
	empty := registry{Version: 1, Entries: []ownershipProof{}}
	if m.paths.RegistryPath == "" {
		return empty, nil
	}
	body, err := readRegular(m.paths.RegistryPath, maxRegistryBytes)
	if errors.Is(err, os.ErrNotExist) {
		return empty, nil
	}
	if err != nil {
		return empty, err
	}
	info, err := os.Lstat(m.paths.RegistryPath)
	if err != nil {
		return empty, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
		return empty, errors.New("ownership registry is not private")
	}
	var result registry
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err = dec.Decode(&result); err != nil {
		return empty, err
	}
	if dec.Decode(&struct{}{}) != io.EOF {
		return empty, errors.New("ownership registry has trailing JSON")
	}
	if result.Version != 1 || result.Entries == nil || len(result.Entries) > maxRegistryEntries {
		return empty, errors.New("invalid current worktree registry format/entry count")
	}
	// Require all authority fields, including the false-valued initial-grant flag.
	var raw struct {
		Entries []map[string]json.RawMessage `json:"entries"`
	}
	if err = json.Unmarshal(body, &raw); err != nil {
		return empty, err
	}
	for i, p := range result.Entries {
		if len(raw.Entries[i]) != 5 {
			return empty, fmt.Errorf("proof %d has missing authority fields", i)
		}
		if err = validateProof(p); err != nil {
			return empty, fmt.Errorf("proof %d: %w", i, err)
		}
	}
	return result, nil
}

var identityPattern = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+)?$`)
var oidPattern = regexp.MustCompile(`(?i)^[0-9a-f]{40,64}$`)

func validateProof(p ownershipProof) error {
	if err := ownerID(p.OwnerThreadID); err != nil {
		return err
	}
	s := p.Snapshot
	for _, path := range []string{s.Root, s.ExecutionCwd, s.BaseRoot, s.StagingRoot, s.CommonDirectory, s.GitDirectory, s.ObjectDirectory, s.PackedRefsLock} {
		if len(path) > 16384 || !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.ContainsRune(path, 0) {
			return errors.New("invalid canonical proof path")
		}
	}
	for _, id := range []directoryIdentity{s.Identity, s.ExecutionCwdIdentity, s.BaseRootIdentity, s.StagingRootIdentity, s.CommonDirectoryIdentity, s.GitDirectoryIdentity, s.ObjectDirectoryIdentity} {
		for _, part := range []string{id.Dev, id.Ino, id.Birthtime} {
			if len(part) > 128 || !identityPattern.MatchString(part) {
				return errors.New("invalid directory identity")
			}
		}
	}
	if !oidPattern.MatchString(p.CreationHeadOID) || !oidPattern.MatchString(p.CurrentHeadOID) || !oidPattern.MatchString(s.HeadOID) {
		return errors.New("invalid proof commit OID")
	}
	if s.RepositoryIdentity == "" || len(s.RepositoryIdentity) > 32768 || strings.ContainsRune(s.RepositoryIdentity, 0) {
		return errors.New("invalid repository identity")
	}
	if !within(s.Root, s.ExecutionCwd) || filepath.Dir(s.Root) != s.StagingRoot || s.PackedRefsLock != filepath.Join(s.CommonDirectory, "packed-refs.lock") {
		return errors.New("proof path relationship invalid")
	}
	return nil
}

// Startup loads only the persisted Thread/proof intersection. Git identity and
// restart HEAD recovery are deferred until inspectOwned first uses each root.
// A candidate is never a grant: every observation/admission/write still inspects
// the actual workspace before returning authority.
func (m *Manager) RehydratePersistedOwners(ctx context.Context, threads []model.ThreadRecord) []RecoveryFailure {
	records := make([]PersistedOwner, 0, len(threads))
	for _, t := range threads {
		if t.Worktree != nil {
			records = append(records, PersistedOwner{OwnerThreadID: t.ID, BaseCwd: t.Cwd, Worktree: *t.Worktree})
		}
	}
	return m.loadRecoveryCandidates(ctx, records)
}

// RehydrateOwners explicitly completes full recovery. Unlike normal startup,
// it inspects every supplied owner, with bounded parallelism and ordered errors.
func (m *Manager) RehydrateOwners(ctx context.Context, records []PersistedOwner) []RecoveryFailure {
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
		out := []RecoveryFailure{{Err: fmt.Errorf("ownership registry unavailable: %w", err)}}
		for _, r := range records {
			out = append(out, RecoveryFailure{r.OwnerThreadID, err})
		}
		return out
	}
	var failures []RecoveryFailure
	type inspected struct {
		owner    PersistedOwner
		snapshot snapshot
		valid    bool
		err      error
	}
	all := make([]inspected, len(records))
	// Each inspection is read-only and owns its Git processes. Keep the
	// manager locked until every worker is joined and the complete recovery
	// is validated/persisted; no authority may observe partial results.
	workers := min(4, len(records))
	var pending sync.WaitGroup
	for worker := range workers {
		pending.Add(1)
		go func() {
			defer pending.Done()
			for i := worker; i < len(records); i += workers {
				r := records[i]
				entry := &all[i]
				entry.owner = r
				entry.err = ownerID(r.OwnerThreadID)
				if entry.err == nil {
					entry.snapshot, entry.err = inspect(ctx, r.BaseCwd, r.Worktree, "", nil)
				}
				entry.valid = entry.err == nil
			}
		}()
	}
	pending.Wait()
	ownerCounts := map[string]int{}
	rootCounts := map[string]int{}
	// Inspection failures do not cancel other owners. Aggregate in input
	// order, independently of worker completion order.
	for _, entry := range all {
		ownerCounts[entry.owner.OwnerThreadID]++
		if entry.err != nil {
			failures = append(failures, RecoveryFailure{entry.owner.OwnerThreadID, entry.err})
			continue
		}
		rootCounts[entry.snapshot.Root]++
	}
	proofOwnerCounts := map[string]int{}
	proofRootCounts := map[string]int{}
	byOwner := map[string]ownershipProof{}
	for _, p := range loaded.Entries {
		proofOwnerCounts[p.OwnerThreadID]++
		proofRootCounts[p.Snapshot.Root]++
		byOwner[p.OwnerThreadID] = p
	}
	next := map[string]ownershipProof{}
	for _, entry := range all {
		if !entry.valid {
			continue
		}
		r, s := entry.owner, entry.snapshot
		p, ok := byOwner[r.OwnerThreadID]
		err = nil
		if ownerCounts[r.OwnerThreadID] != 1 || rootCounts[s.Root] != 1 {
			err = errors.New("trusted managed owner/root is not unique")
		} else if !ok || proofOwnerCounts[r.OwnerThreadID] != 1 || proofRootCounts[s.Root] != 1 || p.Snapshot.Root != s.Root {
			err = errors.New("managed worktree lacks unique exact owner/root proof")
		} else if err = proofMatches(s, p); err == nil && p.InitialGrantPending && p.CreationHeadOID != s.HeadOID {
			err = errors.New("managed worktree HEAD changed before first execution admission")
		}
		if err != nil {
			failures = append(failures, RecoveryFailure{r.OwnerThreadID, err})
			continue
		}
		p.CurrentHeadOID = s.HeadOID
		next[s.Root] = p
	}
	if err = ctx.Err(); err != nil {
		m.registryErr = err
		return append(failures, RecoveryFailure{Err: err})
	}
	if err = m.persist(next); err != nil {
		m.registryErr = err
		return append(failures, RecoveryFailure{Err: fmt.Errorf("ownership registry recovery prune/update: %w", err)})
	}
	m.proofs = next
	return failures
}
