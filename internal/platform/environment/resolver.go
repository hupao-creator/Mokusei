// Package environment resolves native executables without shell interpolation.
// A GUI launch may have an incomplete PATH; a bounded login-shell snapshot is
// used for discovery and copied before any Harness adds private configuration.
package environment

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

type Resolver struct {
	mu          sync.Mutex
	supplied    map[string]string
	cached      map[string]string
	cachedAt    time.Time
	executables map[string]string
	generation  uint64
	ctx         context.Context
	cancel      context.CancelFunc
	loads       sync.WaitGroup
	pending     *environmentLoad
	closed      bool
	cleanupErr  error
}
type environmentLoad struct {
	done   chan struct{}
	values map[string]string
	err    error
	cancel context.CancelFunc
}

func New(supplied map[string]string) *Resolver {
	ctx, cancel := context.WithCancel(context.Background())
	return &Resolver{supplied: clone(supplied), executables: map[string]string{}, ctx: ctx, cancel: cancel}
}
func Current() map[string]string {
	result := map[string]string{}
	for _, entry := range os.Environ() {
		if k, v, ok := strings.Cut(entry, "="); ok {
			result[k] = v
		}
	}
	return result
}
func Slice(values map[string]string) []string {
	out := make([]string, 0, len(values))
	for k, v := range values {
		out = append(out, k+"="+v)
	}
	return out
}
func clone(values map[string]string) map[string]string {
	if values == nil {
		return nil
	}
	result := make(map[string]string, len(values))
	for k, v := range values {
		result[k] = v
	}
	return result
}
func clean(values map[string]string) map[string]string {
	delete(values, "ELECTRON_RUN_AS_NODE")
	delete(values, "NODE_OPTIONS")
	values["TERM"] = "dumb"
	values["NO_COLOR"] = "1"
	values["FORCE_COLOR"] = "0"
	return values
}

func (r *Resolver) Environment(ctx context.Context) (map[string]string, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil, errors.New("executable resolver is closed")
	}
	if r.cached != nil && (r.supplied != nil || time.Since(r.cachedAt) < 5*time.Minute) {
		value := clone(r.cached)
		r.mu.Unlock()
		return value, nil
	}
	if r.cached != nil {
		r.cached = nil
		r.executables = map[string]string{}
		r.generation++
	}
	load := r.pending
	if load == nil {
		loadCtx, cancel := context.WithCancel(r.ctx)
		load = &environmentLoad{done: make(chan struct{}), cancel: cancel}
		r.pending = load
		supplied := clone(r.supplied)
		generation := r.generation
		r.loads.Add(1)
		go func() {
			defer r.loads.Done()
			defer cancel()
			value := supplied
			if value == nil {
				value = Current()
				if loaded, err := loadShell(loadCtx, value); err == nil {
					value = loaded
				} else if errors.Is(err, processgroup.ErrCleanup) {
					load.err = processgroup.ErrCleanup
				}
			}
			load.err = errors.Join(load.err, loadCtx.Err())
			if load.err == nil {
				load.values = clean(value)
			}
			r.mu.Lock()
			if errors.Is(load.err, processgroup.ErrCleanup) {
				r.cleanupErr = processgroup.ErrCleanup
			}
			if r.pending == load {
				r.pending = nil
			}
			if !r.closed && r.generation == generation && load.err == nil {
				r.cached = clone(load.values)
				r.cachedAt = time.Now()
			}
			r.mu.Unlock()
			close(load.done)
		}()
	}
	r.mu.Unlock()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-load.done:
		return clone(load.values), load.err
	}
}
func (r *Resolver) Refresh(ctx context.Context) error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return errors.New("executable resolver is closed")
	}
	r.generation++
	if r.pending != nil {
		r.pending.cancel()
		r.pending = nil
	}
	r.cached = nil
	r.executables = map[string]string{}
	r.mu.Unlock()
	_, err := r.Environment(ctx)
	return err
}

// Close joins any shared login-shell acquisition, including a load whose last
// requesting client disconnected. No child process outlives runtime ownership.
func (r *Resolver) Close() error {
	r.mu.Lock()
	r.closed = true
	r.cancel()
	r.mu.Unlock()
	r.loads.Wait()
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cleanupErr
}

func (r *Resolver) ResolveExecutable(ctx context.Context, command, cwd, configured string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if strings.TrimSpace(configured) != "" {
		command = strings.TrimSpace(configured)
	}
	if command == "" || strings.ContainsRune(command, 0) {
		return "", model.NewError("HARNESS_EXECUTABLE_NOT_FOUND", "Native executable is not configured")
	}
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return "", err
		}
	}
	values, err := r.Environment(ctx)
	if err != nil {
		return "", err
	}
	key := cwd + "\x00" + command
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return "", errors.New("executable resolver is closed")
	}
	cached := r.executables[key]
	generation := r.generation
	r.mu.Unlock()
	if cached != "" && executable(cached) {
		return cached, nil
	}
	expanded := command
	if strings.HasPrefix(expanded, "~/") || strings.HasPrefix(expanded, "~\\") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		expanded = filepath.Join(home, expanded[2:])
	}
	var candidates []string
	if filepath.IsAbs(expanded) || strings.ContainsAny(expanded, "/\\") {
		if !filepath.IsAbs(expanded) {
			expanded = filepath.Join(cwd, expanded)
		}
		candidates = []string{expanded}
	} else {
		for _, directory := range filepath.SplitList(values["PATH"]) {
			directory = strings.Trim(strings.TrimSpace(directory), `"`)
			if directory != "" {
				if !filepath.IsAbs(directory) {
					directory = filepath.Join(cwd, directory)
				}
				candidates = append(candidates, filepath.Join(directory, command))
			}
		}
	}
	for _, candidate := range candidates {
		if err = ctx.Err(); err != nil {
			return "", err
		}
		if executable(candidate) {
			r.mu.Lock()
			if generation == r.generation {
				r.executables[key] = candidate
			}
			r.mu.Unlock()
			return candidate, nil
		}
	}
	return "", model.NewError("HARNESS_EXECUTABLE_NOT_FOUND", "Native executable could not be found: "+command)
}
func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && syscall.Access(path, 1) == nil
}

var environmentName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func loadShell(parent context.Context, base map[string]string) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(parent, 4*time.Second)
	defer cancel()
	shell := base["SHELL"]
	if shell == "" {
		shell = "/bin/zsh"
	}
	output, err := processgroup.Run(ctx, shell, []string{"-ilc", "/usr/bin/env -0"}, "", Slice(base), 1024*1024)
	if err != nil || output.ExitCode != 0 {
		return nil, errors.Join(errors.New("login shell environment unavailable"), err)
	}
	result := clone(base)
	for _, entry := range strings.Split(output.Stdout, "\x00") {
		name, value, ok := strings.Cut(entry, "=")
		if ok && environmentName.MatchString(name) {
			result[name] = value
		}
	}
	return result, nil
}
