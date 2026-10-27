package git

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sort"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type monitor struct {
	environment plugin.BackgroundEnvironmentCapability
	domain      plugin.DomainClient
	tasks       plugin.OrdinaryTaskReadCapability
	process     plugin.ApplicationProcessCapability
	client      *client
	mu          sync.Mutex
	cancel      context.CancelFunc
	done        chan struct{}
	lastAttempt int64
}

func (m *monitor) Start(ctx context.Context, _ plugin.RuntimeStartContext) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cancel != nil {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	ctx, m.cancel = context.WithCancel(ctx)
	m.done = make(chan struct{})
	done := m.done
	go func() {
		defer close(done)
		for {
			if err := m.cycle(ctx); err != nil && ctx.Err() == nil {
				m.environment.Log("warning", "sync.failed", model.Object{"error": err.Error()})
			}
			timer := time.NewTimer(5 * time.Second)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	}()
	return nil
}
func (m *monitor) Stop(ctx context.Context) error {
	m.mu.Lock()
	cancel, done := m.cancel, m.done
	if cancel != nil {
		cancel()
	}
	m.mu.Unlock()
	if done == nil {
		return nil
	}
	select {
	case <-done:
		m.mu.Lock()
		if m.done == done {
			m.cancel = nil
			m.done = nil
		}
		m.mu.Unlock()
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func listAll[T any](ctx context.Context, domain plugin.DomainClient, id string) ([]T, error) {
	out := []T{}
	cursor := ""
	for {
		raw, err := domain.Query(ctx, id, marshal(PageInput{Cursor: cursor, Limit: 1000}))
		if err != nil {
			return nil, err
		}
		var page Page[T]
		if err := json.Unmarshal(raw, &page); err != nil {
			return nil, err
		}
		out = append(out, page.Items...)
		if page.NextCursor == "" {
			return out, nil
		}
		cursor = page.NextCursor
	}
}
func (m *monitor) cycle(ctx context.Context) error {
	activities, err := listAll[Activity](ctx, m.domain, "git.list")
	if err != nil {
		return err
	}
	tasks, err := m.tasks.CaptureList(ctx, true)
	if err != nil {
		return err
	}
	previous := map[string]string{}
	for _, a := range activities {
		// A new monitor must advance the persisted fence even if the wall clock
		// moved backwards while the application was stopped.
		m.lastAttempt = max(m.lastAttempt, a.Sync.AttemptedAt)
		for _, cwd := range a.Directories {
			previous[cwd] = a.Snapshot.Root
		}
	}
	// Cwd identifies the base project; execution cwd follows a managed worktree.
	directories := map[string]bool{}
	for _, task := range tasks {
		if validRoot(task.ExecutionCwd) {
			directories[task.ExecutionCwd] = true
		}
	}
	roots := map[string][]string{}
	failures := map[string]string{}
	paths := make([]string, 0, len(directories))
	for cwd := range directories {
		paths = append(paths, cwd)
	}
	sort.Strings(paths)
	for _, cwd := range paths {
		if err := ctx.Err(); err != nil {
			return err
		}
		root, e := m.client.locate(ctx, m.process, cwd)
		if e != nil {
			root = previous[cwd]
			if root != "" {
				failures[root] = readCode(e)
			}
		}
		if root != "" {
			roots[root] = append(roots[root], cwd)
		}
	}
	attempted := max(time.Now().UnixMilli(), m.lastAttempt+1)
	m.lastAttempt = attempted
	input := SyncInput{AttemptedAt: attempted, Observations: []Observation{}}
	paths = paths[:0]
	for root := range roots {
		paths = append(paths, root)
	}
	sort.Strings(paths)
	for _, root := range paths {
		if err := ctx.Err(); err != nil {
			return err
		}
		o := Observation{Root: root, Directories: roots[root], AttemptedAt: attempted}
		if failure := failures[root]; failure != "" {
			o.Error = ptr(failure)
		} else {
			snapshot, files, e := m.client.status(ctx, m.process, root)
			if e == nil {
				added, deleted, statsErr := m.client.lineStats(ctx, m.process, snapshot, files)
				if statsErr == nil {
					snapshot.Additions = &added
					snapshot.Deletions = &deleted
				} else {
					snapshot.LineStatsError = ptr(readCode(statsErr))
				}
				o.Snapshot = &snapshot
			} else {
				o.Error = ptr(readCode(e))
			}
		}
		input.Observations = append(input.Observations, o)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(activities) == 0 && len(input.Observations) == 0 {
		return nil
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return err
	}
	_, err = m.domain.Execute(ctx, "git.sync", marshal(input), plugin.DomainCommandOptions{RequestID: hex.EncodeToString(nonce[:])})
	return err
}
