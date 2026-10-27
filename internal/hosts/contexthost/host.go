// Package contexthost owns the registration and lifetime of Moku-only Context
// plugins. It has no application store or task execution capabilities.
package contexthost

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Config struct {
	Plugins       []plugin.ContextPlugin
	PluginEnabled map[string]bool
}

type ownedDefinition struct {
	definition plugin.MokuContextDefinition
	enabled    bool
}

type Host struct {
	definitions              map[string]ownedDefinition
	mu                       sync.Mutex
	stopMu                   sync.Mutex
	running, ready, stopping bool
	lifetime                 context.Context
	cancel                   context.CancelFunc
	startDone                chan struct{}
	services                 map[string]plugin.MokuContextService
	operations               sync.WaitGroup
}

var pluginID = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
var contributionID = regexp.MustCompile(`^[a-z][a-z0-9_.-]*$`)

func New(config Config) (*Host, error) {
	h := &Host{definitions: map[string]ownedDefinition{}, services: map[string]plugin.MokuContextService{}}
	owners := map[string]bool{}
	for _, module := range config.Plugins {
		if module == nil {
			return nil, errors.New("nil Context plugin")
		}
		manifest := module.Manifest()
		if !pluginID.MatchString(manifest.ID) || strings.TrimSpace(manifest.DisplayName) == "" || manifest.APIVersion != 1 {
			return nil, fmt.Errorf("invalid Context manifest %q", manifest.ID)
		}
		if owners[manifest.ID] {
			return nil, fmt.Errorf("duplicate Context plugin %s", manifest.ID)
		}
		owners[manifest.ID] = true
		value, present := config.PluginEnabled["context:"+manifest.ID]
		r := &registry{owner: manifest.ID, enabled: !present || value, definitions: map[string]ownedDefinition{}}
		if err := module.Register(r); err != nil {
			return nil, err
		}
		declared := slices.Clone(manifest.Contributions)
		slices.Sort(declared)
		if !slices.Equal(declared, keys(r.definitions)) {
			return nil, fmt.Errorf("Context plugin %s manifest contributions do not match registration", manifest.ID)
		}
		// Copy definitions rather than retaining a registry that the plugin may
		// still hold. Registration cannot alter the frozen host afterwards.
		for id, definition := range r.definitions {
			h.definitions[id] = definition
		}
	}
	return h, nil
}

type registry struct {
	owner       string
	enabled     bool
	definitions map[string]ownedDefinition
}

func (r *registry) MokuContext(d plugin.MokuContextDefinition) error {
	if !contributionID.MatchString(d.ID) || !strings.HasPrefix(d.ID, r.owner+".") {
		return fmt.Errorf("invalid Context contribution identity %q", d.ID)
	}
	if d.Create == nil || strings.TrimSpace(d.Slot) == "" || d.TimeoutMS <= 0 || d.TimeoutMS > 60000 || !slices.Contains([]string{"session-start", "before-send"}, d.InjectAt) || !slices.Contains([]string{"omit", "abort-send"}, d.OnFailure) {
		return fmt.Errorf("invalid Moku context %s", d.ID)
	}
	if _, exists := r.definitions[d.ID]; exists {
		return fmt.Errorf("duplicate Moku context %s", d.ID)
	}
	r.definitions[d.ID] = ownedDefinition{definition: d, enabled: r.enabled}
	return nil
}

func keys[T any](values map[string]T) []string {
	result := make([]string, 0, len(values))
	for key := range values {
		result = append(result, key)
	}
	slices.Sort(result)
	return result
}

func (h *Host) Start(ctx context.Context, _ plugin.RuntimeStartContext) (err error) {
	// A new generation cannot be admitted while Stop is draining the old one.
	h.stopMu.Lock()
	h.mu.Lock()
	if h.running {
		h.mu.Unlock()
		h.stopMu.Unlock()
		return errors.New("Context host already started")
	}
	lifetime, cancel := context.WithCancel(ctx)
	h.lifetime, h.cancel = lifetime, cancel
	h.startDone = make(chan struct{})
	done := h.startDone
	h.running, h.ready, h.stopping = true, false, false
	h.services = map[string]plugin.MokuContextService{}
	h.mu.Unlock()
	h.stopMu.Unlock()
	defer func() {
		close(done)
		if err != nil {
			err = errors.Join(err, h.stop(context.Background(), done))
		}
	}()
	for _, id := range keys(h.definitions) {
		entry := h.definitions[id]
		if !entry.enabled {
			continue
		}
		if err = lifetime.Err(); err != nil {
			return err
		}
		service, createErr := entry.definition.Create()
		if createErr != nil {
			return createErr
		}
		if service == nil {
			return errors.New("nil Moku context service")
		}
		h.mu.Lock()
		h.services[id] = service
		h.mu.Unlock()
	}
	h.mu.Lock()
	err = lifetime.Err()
	h.ready = err == nil && !h.stopping
	h.mu.Unlock()
	return err
}

func (h *Host) begin(ctx context.Context) (context.Context, map[string]plugin.MokuContextService, func(), error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.ready || h.stopping {
		return nil, nil, nil, errors.New("Context host is not running")
	}
	if err := h.lifetime.Err(); err != nil {
		return nil, nil, nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, nil, err
	}
	combined, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(h.lifetime, cancel)
	services := make(map[string]plugin.MokuContextService, len(h.services))
	for id, service := range h.services {
		services[id] = service
	}
	h.operations.Add(1)
	return combined, services, func() { stop(); cancel(); h.operations.Done() }, nil
}

func (h *Host) Stop(ctx context.Context) error {
	return h.stop(ctx, nil)
}

func (h *Host) stop(ctx context.Context, generation chan struct{}) error {
	h.stopMu.Lock()
	defer h.stopMu.Unlock()
	h.mu.Lock()
	// A failed Start may finish its cleanup after another Stop and restart.
	// Its deferred cleanup must not revoke that newer generation.
	if generation != nil && h.startDone != generation {
		h.mu.Unlock()
		return nil
	}
	h.stopping, h.ready = true, false
	if h.cancel != nil {
		h.cancel()
	}
	done := h.startDone
	h.mu.Unlock()
	if done != nil {
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.mu.Lock()
	services := make([]plugin.MokuContextService, 0, len(h.services))
	for _, id := range keys(h.services) {
		services = append(services, h.services[id])
	}
	h.mu.Unlock()
	var wg sync.WaitGroup
	failures := make(chan error, len(services))
	for _, service := range services {
		wg.Add(1)
		go func(s plugin.MokuContextService) {
			defer wg.Done()
			if err := s.Close(); err != nil {
				failures <- err
			}
		}(service)
	}
	wg.Wait()
	h.operations.Wait()
	close(failures)
	var errs []error
	for err := range failures {
		errs = append(errs, err)
	}
	if len(errs) == 0 {
		h.mu.Lock()
		h.running = false
		h.services = map[string]plugin.MokuContextService{}
		h.startDone, h.lifetime, h.cancel = nil, nil, nil
		h.mu.Unlock()
	}
	return errors.Join(errs...)
}
