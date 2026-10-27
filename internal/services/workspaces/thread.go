package workspaces

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func (m *Manager) Validate(ctx context.Context, path string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	cwd, err := canonical(path)
	if err != nil {
		return "", fmt.Errorf("workspace inaccessible: %w", err)
	}
	info, err := os.Stat(cwd)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("workspace is not a directory")
	}
	if m.paths.MokuCwd != "" {
		moku, e := canonical(m.paths.MokuCwd)
		if e != nil {
			moku = filepath.Clean(m.paths.MokuCwd)
		}
		if within(moku, cwd) {
			return "", errors.New("ordinary thread cannot use Moku workspace")
		}
	}
	return cwd, ctx.Err()
}
func (m *Manager) RuntimeCwd(ctx context.Context) (string, error) {
	cwd, err := m.Validate(ctx, m.paths.DefaultCwd)
	if err == nil && cwd != m.paths.DefaultCwd {
		err = errors.New("global default workspace identity changed")
	}
	return cwd, err
}
func (m *Manager) validatePaths(ctx context.Context, t model.ThreadRecord) error {
	if t.Moku {
		if err := ctx.Err(); err != nil {
			return err
		}
		if m.paths.MokuCwd == "" || t.Worktree != nil {
			return errors.New("Moku requires its dedicated workspace without a managed worktree")
		}
		expected, err := canonical(m.paths.MokuCwd)
		if err != nil {
			return err
		}
		actual, err := canonical(t.Cwd)
		if err != nil {
			return err
		}
		if actual != t.Cwd || actual != expected {
			return errors.New("Moku workspace canonical identity changed")
		}
		info, err := os.Stat(actual)
		if err != nil {
			return err
		}
		if !info.IsDir() {
			return errors.New("Moku workspace is not a directory")
		}
		return ctx.Err()
	}
	paths := []string{t.Cwd}
	if t.Worktree != nil {
		paths = append(paths, t.Worktree.Cwd)
	}
	for _, path := range paths {
		got, err := m.Validate(ctx, path)
		if err != nil {
			return err
		}
		if got != path {
			return fmt.Errorf("thread workspace canonical identity changed: %s", t.ID)
		}
	}
	return nil
}
func (m *Manager) ValidateThread(ctx context.Context, t model.ThreadRecord) error {
	if err := m.validatePaths(ctx, t); err != nil {
		return err
	}
	if t.Worktree != nil {
		_, err := m.ValidateManaged(ctx, requestFor(t))
		return err
	}
	return nil
}
func (m *Manager) Observe(ctx context.Context, t model.ThreadRecord, expected *Observation) (*Observation, error) {
	if err := m.validatePaths(ctx, t); err != nil {
		return nil, err
	}
	var previous observationAuthority
	if expected != nil {
		m.mu.Lock()
		ok := expected.manager == m && expected.epoch == m.observationEpoch
		previous = expected.authority
		m.mu.Unlock()
		if !ok || previous.ThreadID != t.ID || previous.BaseCwd != t.Cwd || (previous.Managed != nil) != (t.Worktree != nil) {
			return nil, errors.New("thread workspace observation expired")
		}
	}
	cwd := t.Cwd
	var managed *Validation
	if t.Worktree != nil {
		r := requestFor(t)
		if previous.Managed != nil {
			r.ExpectedHeadOID = previous.Managed.HeadOID
			r.ExpectedCwd = previous.Managed.Cwd
			r.ExpectedRepositoryIdentity = previous.Managed.RepositoryIdentity
		}
		v, err := m.ValidateManaged(ctx, r)
		if err != nil {
			return nil, err
		}
		managed = &v
		cwd = v.Cwd
		if cwd != t.Worktree.Cwd {
			return nil, errors.New("managed execution directory changed")
		}
	}
	if expected != nil && expected.Cwd != cwd {
		return nil, errors.New("observed execution directory changed")
	}
	m.mu.Lock()
	observation := &Observation{Cwd: cwd, manager: m, epoch: m.observationEpoch, authority: observationAuthority{t.ID, t.Cwd, managed}}
	m.mu.Unlock()
	return observation, ctx.Err()
}
func (m *Manager) ReleaseObservation(observation *Observation) {
	m.mu.Lock()
	if observation != nil && observation.manager == m {
		observation.manager = nil
	}
	m.mu.Unlock()
}
func (m *Manager) CreateTemporary(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	root := m.paths.TemporaryRoot
	if !filepath.IsAbs(root) || strings.ContainsRune(root, 0) {
		return "", errors.New("temporary workspace root must be absolute")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return "", err
	}
	if err := privateDirectory(root); err != nil {
		return "", err
	}
	canonicalRoot, err := canonical(root)
	if err != nil {
		return "", err
	}
	rootID, err := directoryID(root)
	if err != nil {
		return "", err
	}
	path, err := os.MkdirTemp(canonicalRoot, "thread-")
	if err != nil {
		return "", err
	}
	if err = assertIdentity(root, rootID); err != nil {
		return "", errors.Join(err, removeEmptyDirectory(path))
	}
	id, err := directoryID(path)
	if err != nil {
		return "", err
	}
	m.mu.Lock()
	m.temporary[path] = id
	m.mu.Unlock()
	if err = ctx.Err(); err != nil {
		return "", errors.Join(err, m.DiscardTemporary(context.WithoutCancel(ctx), path))
	}
	return path, nil
}
func (m *Manager) DiscardTemporary(ctx context.Context, path string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.temporary[path]
	if !ok {
		return errors.New("temporary workspace lacks this process's creation authority")
	}
	root, err := canonical(m.paths.TemporaryRoot)
	if err != nil {
		return err
	}
	if filepath.Dir(path) != root || !strings.HasPrefix(filepath.Base(path), "thread-") {
		return errors.New("temporary workspace escapes root")
	}
	if err = assertIdentity(path, id); err != nil {
		return err
	}
	// Temporary rollback only removes an empty directory. Unexpected files are
	// retained rather than recursively deleting concurrently written user data.
	if err = removeEmptyDirectory(path); err != nil {
		return err
	}
	delete(m.temporary, path)
	return nil
}
