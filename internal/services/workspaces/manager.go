// Package workspaces owns Core managed checkout authority. Plugin-owned Git UI
// registration does not affect these execution and write authorization fences.
package workspaces

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"unicode"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Paths struct{ DefaultCwd, MokuCwd, TemporaryRoot, RegistryPath string }
type Config = Paths
type Manager struct {
	paths            Paths
	mu               sync.Mutex
	loaded           bool
	registryErr      error
	proofs           map[string]ownershipProof
	pendingRecovery  map[string]bool // root -> restart HEAD recovery awaits first use
	observationEpoch uint64
	temporary        map[string]directoryIdentity
}
type Preparation struct {
	Worktree               model.Worktree
	Created                bool
	BaseCwd, OwnerThreadID string
	// WorktreeName is the effective final staging directory component (including
	// any collision suffix). WorktreeNameAdjusted reports that it differs from
	// the caller's requested label because of sanitization, truncation, a
	// collision suffix or fallback; WorktreeNameNotice explains the change.
	WorktreeName         string
	WorktreeNameAdjusted bool
	WorktreeNameNotice   string
}
type Validation struct{ Kind, Cwd, HeadOID, RepositoryIdentity string }
type AuthorizationRequest struct {
	OwnerThreadID, BaseCwd                                   string
	Worktree                                                 model.Worktree
	ExpectedHeadOID, ExpectedCwd, ExpectedRepositoryIdentity string
}
type RecoveryFailure struct {
	OwnerThreadID string
	Err           error
}
type PersistedOwner struct {
	OwnerThreadID, BaseCwd string
	Worktree               model.Worktree
}

// Authority is private and tied to this Manager and generation. Keeping it on
// the observation avoids retaining every historical observation in the manager.
type Observation struct {
	Cwd       string
	manager   *Manager
	epoch     uint64
	authority observationAuthority
}
type observationAuthority struct {
	ThreadID, BaseCwd string
	Managed           *Validation
}
type ownershipProof struct {
	Snapshot            snapshot `json:"snapshot"`
	OwnerThreadID       string   `json:"ownerThreadId"`
	CreationHeadOID     string   `json:"creationHeadOid"`
	CurrentHeadOID      string   `json:"currentHeadOid"`
	InitialGrantPending bool     `json:"initialGrantPending"`
}

func New(paths Paths) *Manager {
	return &Manager{paths: paths, loaded: paths.RegistryPath == "", proofs: make(map[string]ownershipProof), pendingRecovery: make(map[string]bool), temporary: make(map[string]directoryIdentity)}
}
func (m *Manager) Paths() Paths { return m.paths }
func ownerID(id string) error {
	if id == "" || len(id) > 128 || strings.ContainsRune(id, 0) || strings.IndexFunc(id, unicode.IsSpace) >= 0 {
		return errors.New("invalid managed worktree owner ID")
	}
	return nil
}
func (m *Manager) usable() error {
	if !m.loaded {
		return errors.New("managed worktree ownership registry not initialized")
	}
	if m.registryErr != nil {
		return fmt.Errorf("managed worktree ownership registry unavailable: %w", m.registryErr)
	}
	return nil
}
func validation(s snapshot) Validation {
	return Validation{"managed-linked-worktree", s.ExecutionCwd, s.HeadOID, s.RepositoryIdentity}
}
func requestFor(t model.ThreadRecord) AuthorizationRequest {
	return AuthorizationRequest{OwnerThreadID: t.ID, BaseCwd: t.Cwd, Worktree: *t.Worktree}
}

// generatedLabel keeps the byte-identical task-<thread-id> prefix for UUID
// thread ids; createStaging appends the historical random 32-hex suffix.
func generatedLabel(threadID string) string {
	id := slug(threadID)
	if len(id) > 12 {
		id = id[:12]
	}
	return "task-" + id
}

// worktreeNameOutcome explains how a caller-supplied label became the effective
// directory name. An absent or blank label is not an adjustment: the generated
// name is the documented contract. Everything else that differs is reported so
// truncation, sanitization, collision suffixes and fallback are never silent.
func worktreeNameOutcome(requested, sanitized, effective string, fallbackUsed bool) (bool, string) {
	if requested == "" {
		return false, ""
	}
	if sanitized == "" {
		return true, fmt.Sprintf("worktreeName %q has no usable path-safe form; used the generated name %q. Retry with a different worktreeName if a readable directory is required", requested, effective)
	}
	if fallbackUsed {
		return true, fmt.Sprintf("all candidate directories for worktreeName %q were taken; used the generated name %q. Retry without worktreeName or choose another name", requested, effective)
	}
	if effective != sanitized {
		prefix := ""
		if sanitized != requested {
			prefix = fmt.Sprintf("worktreeName %q was sanitized to %q; ", requested, sanitized)
		}
		switch collisionSuffix(effective, sanitized) {
		case "deterministic":
			return true, fmt.Sprintf("%sdetected a name collision: %q already existed; used %q. Choose another worktreeName to avoid the suffix", prefix, sanitized, effective)
		case "random":
			return true, fmt.Sprintf("%sdetected a name collision: every deterministic -2..-8 candidate for %q was taken; used %q with a short random suffix. Choose another worktreeName to avoid the suffix", prefix, sanitized, effective)
		default:
			return true, fmt.Sprintf("%sdetected a name collision; used %q. Choose another worktreeName to avoid the suffix", prefix, effective)
		}
	}
	if sanitized != requested {
		return true, fmt.Sprintf("worktreeName %q was sanitized to %q (Unicode letters and digits are kept; other characters become '-' and the label is capped at %d runes)", requested, effective, directoryNameMaxRunes)
	}
	return false, ""
}

// collisionSuffix classifies the suffix createStaging appended: the
// deterministic -2..-8 ladder or the 4-hex random fallback.
func collisionSuffix(effective, sanitized string) string {
	suffix := strings.TrimPrefix(effective, sanitized+"-")
	if suffix == effective || suffix == "" {
		return ""
	}
	if n, err := strconv.Atoi(suffix); err == nil && n >= 2 && n <= 8 {
		return "deterministic"
	}
	if len(suffix) == 4 {
		for _, r := range suffix {
			if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
				return ""
			}
		}
		return "random"
	}
	return ""
}

func (m *Manager) PrepareForStart(ctx context.Context, baseCwd, threadID string, requested *model.WorktreeOptions, existing *model.Worktree) (Preparation, error) {
	p := Preparation{BaseCwd: baseCwd, OwnerThreadID: threadID}
	if err := ownerID(threadID); err != nil {
		return p, err
	}
	if existing != nil {
		_, err := m.ValidateManaged(ctx, AuthorizationRequest{OwnerThreadID: threadID, BaseCwd: baseCwd, Worktree: *existing})
		p.Worktree = *existing
		return p, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.usable(); err != nil {
		return p, err
	}
	if err := ctx.Err(); err != nil {
		return p, err
	}
	cwd, err := m.Validate(ctx, baseCwd)
	if err != nil {
		return p, err
	}
	repo, err := repositoryContext(ctx, cwd)
	if err != nil {
		return p, fmt.Errorf("worktree mode requires a committed Git checkout: %w", err)
	}
	subdir, err := filepath.Rel(repo.Root, cwd)
	if err != nil || !within(repo.Root, cwd) {
		return p, errors.New("cannot resolve worktree execution directory")
	}
	if subdir != "." {
		if err = headDirectoryPath(ctx, repo.Root, subdir); err != nil {
			return p, err
		}
	}
	expected, err := runGit(ctx, repo.Root, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		return p, err
	}
	label := ""
	requestedName := ""
	sanitized := ""
	randomSuffix := true
	if requested != nil {
		requestedName = strings.TrimSpace(requested.Name)
		sanitized = directoryName(requestedName)
		if sanitized != "" {
			// A caller-chosen name replaces the opaque task-<thread-id> prefix.
			// createStaging still keeps the result unique with deterministic
			// numeric suffixes followed by a short random suffix.
			label, randomSuffix = sanitized, false
		}
	}
	if label == "" {
		label = generatedLabel(threadID)
	}
	root, err := createStaging(repo.StagingRoot, label, randomSuffix)
	fallbackUsed := false
	if err != nil && sanitized != "" && errors.Is(err, errStagingCollision) {
		// Exhausted every readable variant of a caller-chosen name. Falling back
		// to the generated name is still better than failing the creation.
		root, err = createStaging(repo.StagingRoot, generatedLabel(threadID), true)
		fallbackUsed = err == nil
	}
	if err != nil {
		if requestedName != "" {
			return p, fmt.Errorf("cannot allocate a managed worktree for worktreeName %q: %w; retry without worktreeName or choose another name", requestedName, err)
		}
		return p, err
	}
	p.WorktreeName = filepath.Base(root)
	p.WorktreeNameAdjusted, p.WorktreeNameNotice = worktreeNameOutcome(requestedName, sanitized, p.WorktreeName, fallbackUsed)
	rootID, err := directoryID(root)
	if err != nil {
		return p, err
	}
	rollback := func(cause error) (Preparation, error) {
		return p, errors.Join(cause, cleanupAttempt(context.WithoutCancel(ctx), repo.Root, root, rootID))
	}
	if _, err = runGit(ctx, repo.Root, "worktree", "add", "--detach", root, expected); err != nil {
		return rollback(err)
	}
	if err = assertIdentity(root, rootID); err != nil {
		return rollback(err)
	}
	if _, err = detachedHEAD(ctx, root, expected); err != nil {
		return rollback(err)
	}
	if err = assertRegistered(ctx, repo.Root, root); err != nil {
		return rollback(err)
	}
	executionCwd := root
	if subdir != "." {
		executionCwd = filepath.Join(root, subdir)
	}
	if err = ensureDirectoryPath(root, executionCwd, rootID); err != nil {
		return rollback(err)
	}
	executionCwd, err = canonical(executionCwd)
	if err != nil {
		return rollback(err)
	}
	if !within(root, executionCwd) {
		return rollback(errors.New("execution directory escaped staging"))
	}
	if err = assertIdentity(root, rootID); err != nil {
		return rollback(err)
	}
	s, err := inspect(ctx, baseCwd, model.Worktree{Cwd: executionCwd}, expected, nil)
	if err != nil {
		return rollback(err)
	}
	for existingRoot, proof := range m.proofs {
		if existingRoot == s.Root && proof.OwnerThreadID != threadID {
			return rollback(errors.New("managed worktree already belongs to another owner"))
		}
		if proof.OwnerThreadID == threadID && existingRoot != s.Root {
			return rollback(errors.New("thread already owns another managed worktree"))
		}
	}
	proof := ownershipProof{Snapshot: s, OwnerThreadID: threadID, CreationHeadOID: s.HeadOID, CurrentHeadOID: s.HeadOID, InitialGrantPending: true}
	next := cloneProofs(m.proofs)
	next[s.Root] = proof
	if err = m.persist(next); err != nil {
		return rollback(err)
	}
	m.proofs = next
	p.Worktree = model.Worktree{Cwd: executionCwd}
	p.Created = true
	return p, nil
}
func (m *Manager) ManagedWorkspaceRoots() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	seen := map[string]bool{}
	var out []string
	for _, p := range m.proofs {
		for _, root := range []string{p.Snapshot.Root, p.Snapshot.StagingRoot} {
			if !seen[root] {
				seen[root] = true
				out = append(out, root)
			}
		}
	}
	return out
}
func proofMatches(s snapshot, p ownershipProof) error {
	// A selected subdirectory can be recreated between executions, as in the
	// original authority contract. Its identity is still fenced within one call.
	a, b := s, p.Snapshot
	a.HeadOID = ""
	b.HeadOID = ""
	a.ExecutionCwdIdentity = directoryIdentity{}
	b.ExecutionCwdIdentity = directoryIdentity{}
	if a != b {
		return errors.New("worktree identity differs from durable Core ownership proof")
	}
	return nil
}
func (m *Manager) inspectOwned(ctx context.Context, r AuthorizationRequest, policy string) (snapshot, ownershipProof, error) {
	var empty snapshot
	var zero ownershipProof
	if err := m.usable(); err != nil {
		return empty, zero, err
	}
	if err := ownerID(r.OwnerThreadID); err != nil {
		return empty, zero, err
	}
	if err := ctx.Err(); err != nil {
		return empty, zero, err
	}
	cwd, err := canonical(r.Worktree.Cwd)
	if err != nil {
		return empty, zero, err
	}
	var p ownershipProof
	found := false
	for root, proof := range m.proofs {
		if proof.OwnerThreadID == r.OwnerThreadID && within(root, cwd) {
			if found {
				return empty, zero, errors.New("multiple managed worktree proofs for owner")
			}
			p = proof
			found = true
		}
	}
	if !found {
		return empty, zero, errors.New("managed worktree lacks thread-bound Core ownership")
	}
	expected := r.ExpectedHeadOID
	proofHead := ""
	if p.InitialGrantPending {
		proofHead = p.CreationHeadOID
	} else if policy == "authorize" && !m.pendingRecovery[p.Snapshot.Root] {
		proofHead = p.CurrentHeadOID
	}
	if proofHead != "" {
		if expected != "" && expected != proofHead {
			return empty, zero, errors.New("expected HEAD differs from Core admitted HEAD")
		}
		expected = proofHead
	}
	first, err := inspect(ctx, r.BaseCwd, r.Worktree, expected, nil)
	if err != nil {
		return empty, zero, err
	}
	if err = proofMatches(first, p); err != nil {
		return empty, zero, err
	}
	verified, err := inspect(ctx, r.BaseCwd, r.Worktree, first.HeadOID, &first)
	if err != nil {
		return empty, zero, err
	}
	if r.ExpectedCwd != "" && r.ExpectedCwd != verified.ExecutionCwd {
		return empty, zero, errors.New("managed execution cwd changed")
	}
	if r.ExpectedRepositoryIdentity != "" && r.ExpectedRepositoryIdentity != verified.RepositoryIdentity {
		return empty, zero, errors.New("managed repository identity changed")
	}
	if err = proofMatches(verified, p); err != nil {
		return empty, zero, err
	}
	if m.pendingRecovery[p.Snapshot.Root] {
		// The startup candidate was metadata only. Both identity checks above
		// must succeed before restoring the admitted HEAD; an explicit expected
		// HEAD and the initial-grant fence have already been enforced.
		if err = ctx.Err(); err != nil {
			return empty, zero, err
		}
		previous := p
		p.CurrentHeadOID = verified.HeadOID
		if p != previous {
			next := cloneProofs(m.proofs)
			next[verified.Root] = p
			if err = m.persist(next); err != nil {
				return empty, zero, err
			}
			if err = ctx.Err(); err != nil {
				if rollback := m.persist(m.proofs); rollback != nil {
					m.registryErr = errors.Join(err, rollback)
					return empty, zero, m.registryErr
				}
				return empty, zero, err
			}
			m.proofs = next
		}
		delete(m.pendingRecovery, verified.Root)
	}
	return verified, p, nil
}
func (m *Manager) ValidateManaged(ctx context.Context, r AuthorizationRequest) (Validation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, _, err := m.inspectOwned(ctx, r, "observe")
	return validation(s), err
}
func (m *Manager) Admit(ctx context.Context, r AuthorizationRequest) (Validation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, p, err := m.inspectOwned(ctx, r, "admit")
	if err != nil {
		return Validation{}, err
	}
	if err = m.advance(ctx, r, s, p); err != nil {
		return Validation{}, err
	}
	return validation(s), nil
}
func (m *Manager) AuthorizeWrite(ctx context.Context, r AuthorizationRequest) (plugin.ManagedWorkspaceGrant, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, p, err := m.inspectOwned(ctx, r, "authorize")
	if err != nil {
		return plugin.ManagedWorkspaceGrant{}, err
	}
	if err = m.advance(ctx, r, s, p); err != nil {
		return plugin.ManagedWorkspaceGrant{}, err
	}
	return plugin.ManagedWorkspaceGrant{Kind: "managed-linked-worktree", Cwd: s.ExecutionCwd, HeadOID: s.HeadOID, WritableRoots: []string{s.GitDirectory, s.ObjectDirectory, s.PackedRefsLock}}, nil
}
func (m *Manager) advance(ctx context.Context, r AuthorizationRequest, s snapshot, previous ownershipProof) error {
	nextProof := previous
	nextProof.CurrentHeadOID = s.HeadOID
	nextProof.InitialGrantPending = false
	changed := nextProof != previous
	if changed {
		next := cloneProofs(m.proofs)
		next[s.Root] = nextProof
		if err := m.persist(next); err != nil {
			return err
		}
		m.proofs = next
	}
	final, err := inspect(ctx, r.BaseCwd, r.Worktree, s.HeadOID, &s)
	if err == nil {
		err = proofMatches(final, nextProof)
	}
	if err == nil {
		err = ctx.Err()
	}
	if err != nil && changed {
		restored := cloneProofs(m.proofs)
		restored[s.Root] = previous
		if rollbackErr := m.persist(restored); rollbackErr != nil {
			m.registryErr = errors.Join(err, rollbackErr)
			m.proofs = map[string]ownershipProof{}
			return m.registryErr
		}
		m.proofs = restored
	}
	return err
}
func (m *Manager) AdmitThread(ctx context.Context, t model.ThreadRecord) (Validation, error) {
	if err := m.validatePaths(ctx, t); err != nil {
		return Validation{}, err
	}
	if t.Worktree == nil {
		return Validation{Cwd: t.Cwd}, nil
	}
	return m.Admit(ctx, requestFor(t))
}
func (m *Manager) Grant(ctx context.Context, t model.ThreadRecord) (plugin.ManagedWorkspaceGrant, error) {
	if t.Worktree == nil {
		return plugin.ManagedWorkspaceGrant{}, errors.New("thread has no managed worktree")
	}
	if err := m.validatePaths(ctx, t); err != nil {
		return plugin.ManagedWorkspaceGrant{}, err
	}
	return m.AuthorizeWrite(ctx, requestFor(t))
}
func (m *Manager) Discard(ctx context.Context, p Preparation) error {
	if !p.Created {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.usable(); err != nil {
		return err
	}
	s, err := inspect(ctx, p.BaseCwd, p.Worktree, "", nil)
	if err != nil {
		return err
	}
	proof, ok := m.proofs[s.Root]
	if !ok || proof.OwnerThreadID != p.OwnerThreadID {
		return errors.New("creation rollback lacks matching owner/root proof")
	}
	if err = proofMatches(s, proof); err != nil {
		return err
	}
	if err = cleanupAttempt(ctx, s.BaseRoot, s.Root, proof.Snapshot.Identity); err != nil {
		return err
	}
	return m.removeProof(s.Root, p.OwnerThreadID)
}
func (m *Manager) Unregister(ctx context.Context, id string, worktree *model.Worktree) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := m.usable(); err != nil {
		return err
	}
	if err := ownerID(id); err != nil {
		return err
	}
	root := ""
	for r, p := range m.proofs {
		if p.OwnerThreadID == id {
			if root != "" {
				return errors.New("owner has multiple managed proofs")
			}
			root = r
			if worktree != nil && worktree.Cwd != p.Snapshot.ExecutionCwd {
				return errors.New("refusing to unregister mismatched worktree")
			}
		}
	}
	if root == "" {
		return nil
	}
	return m.removeProof(root, id)
}
func (m *Manager) removeProof(root, id string) error {
	p, ok := m.proofs[root]
	if !ok || p.OwnerThreadID != id {
		return errors.New("ownership proof changed")
	}
	next := cloneProofs(m.proofs)
	delete(next, root)
	delete(m.proofs, root)
	delete(m.pendingRecovery, root)
	if err := m.persist(next); err != nil {
		m.registryErr = err
		m.proofs = map[string]ownershipProof{}
		return err
	}
	m.proofs = next
	return nil
}
func (m *Manager) ClearOwned(ctx context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if !m.loaded {
		return errors.New("ownership registry not initialized")
	}
	m.proofs = map[string]ownershipProof{}
	m.pendingRecovery = map[string]bool{}
	m.observationEpoch++
	err := m.persist(m.proofs)
	m.registryErr = err
	return err
}
