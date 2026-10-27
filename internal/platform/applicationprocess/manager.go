// Package applicationprocess supplies the host-owned finite process capability.
package applicationprocess

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/environment"
	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

type Manager struct {
	resolver *environment.Resolver
	ctx      context.Context
	cancel   context.CancelFunc
	mu       sync.Mutex
	closed   bool
	calls    sync.WaitGroup
	cleanup  error
}

func New(ctx context.Context, resolver *environment.Resolver) *Manager {
	ctx, cancel := context.WithCancel(ctx)
	return &Manager{resolver: resolver, ctx: ctx, cancel: cancel}
}
func (m *Manager) ForCwd(cwd string) plugin.ApplicationProcessCapability { return capability{m, cwd} }
func (m *Manager) Close(ctx context.Context) error {
	m.mu.Lock()
	m.closed = true
	m.cancel()
	m.mu.Unlock()
	done := make(chan struct{})
	go func() { m.calls.Wait(); close(done) }()
	select {
	case <-done:
		m.mu.Lock()
		defer m.mu.Unlock()
		return m.cleanup
	case <-ctx.Done():
		return ctx.Err()
	}
}

type capability struct {
	manager *Manager
	cwd     string
}

func failure(code string) error {
	messages := map[string]string{"not-found": "Application executable was not found", "timeout": "Application process timed out", "output-limit": "Application process exceeded its output limit", "spawn-failed": "Application process could not complete safely", "cancelled": "Application process was cancelled"}
	return &plugin.ApplicationProcessError{Code: code, Message: messages[code]}
}
func (c capability) Run(parent context.Context, input plugin.ApplicationProcessInput) (plugin.ApplicationProcessResult, error) {
	m := c.manager
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return plugin.ApplicationProcessResult{}, failure("cancelled")
	}
	m.calls.Add(1)
	m.mu.Unlock()
	defer m.calls.Done()
	timeout := input.TimeoutMS
	if timeout == 0 {
		timeout = 30000
	}
	limit := input.MaxOutputBytes
	if limit == 0 {
		limit = 4 * 1024 * 1024
	}
	if timeout < 1 || timeout > 120000 || limit < 1 || limit > 16*1024*1024 || strings.TrimSpace(input.Command) == "" || strings.ContainsRune(input.Command, 0) {
		return plugin.ApplicationProcessResult{}, failure("spawn-failed")
	}
	ctx, cancel := context.WithTimeout(parent, time.Duration(timeout)*time.Millisecond)
	defer cancel()
	unlink := context.AfterFunc(m.ctx, cancel)
	defer unlink()
	translate := func(err error) error {
		if err == nil {
			return nil
		}
		if errors.Is(err, processgroup.ErrCleanup) {
			m.mu.Lock()
			m.cleanup = errors.Join(m.cleanup, processgroup.ErrCleanup)
			m.mu.Unlock()
			return failure("spawn-failed")
		}
		if parent.Err() != nil || m.ctx.Err() != nil {
			return failure("cancelled")
		}
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return failure("timeout")
		}
		if errors.Is(err, processgroup.ErrOutputLimit) {
			return failure("output-limit")
		}
		var public *model.Error
		if errors.As(err, &public) && public.Code == "HARNESS_EXECUTABLE_NOT_FOUND" {
			return failure("not-found")
		}
		return failure("spawn-failed")
	}
	cwd := input.Cwd
	if cwd == "" {
		cwd = c.cwd
	}
	if !filepath.IsAbs(cwd) {
		return plugin.ApplicationProcessResult{}, failure("spawn-failed")
	}
	if err := os.MkdirAll(c.cwd, 0700); err != nil {
		return plugin.ApplicationProcessResult{}, failure("spawn-failed")
	}
	executable, err := m.resolver.ResolveExecutable(ctx, input.Command, cwd, "")
	if err != nil {
		return plugin.ApplicationProcessResult{}, translate(err)
	}
	env, err := m.resolver.Environment(ctx)
	if err != nil {
		return plugin.ApplicationProcessResult{}, translate(err)
	}
	for key, value := range input.Env {
		if key == "" || strings.ContainsAny(key, "=\x00") {
			return plugin.ApplicationProcessResult{}, failure("spawn-failed")
		}
		if value == nil {
			delete(env, key)
		} else {
			if strings.ContainsRune(*value, 0) {
				return plugin.ApplicationProcessResult{}, failure("spawn-failed")
			}
			env[key] = *value
		}
	}
	result, err := processgroup.Run(ctx, executable, input.Args, cwd, environment.Slice(env), limit)
	if err != nil {
		return plugin.ApplicationProcessResult{}, translate(err)
	}
	return plugin.ApplicationProcessResult{Stdout: result.Stdout, Stderr: result.Stderr, ExitCode: result.ExitCode}, nil
}
