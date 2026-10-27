package artificialanalysis

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Plugin struct{ options Options }

func NewWithOptions(options Options) *Plugin { return &Plugin{options: options} }
func (*Plugin) Manifest() plugin.ContextManifest {
	return plugin.ContextManifest{ID: SourceID, DisplayName: "Artificial Analysis", APIVersion: 1, Contributions: []string{"artificial-analysis.evaluation"}}
}
func (p *Plugin) Register(registry plugin.ContextRegistry) error {
	return registry.MokuContext(plugin.MokuContextDefinition{ID: "artificial-analysis.evaluation", Slot: "evaluation", InjectAt: "before-send", TimeoutMS: ContextTimeoutMS, OnFailure: "abort-send", Create: func() (plugin.MokuContextService, error) { return acquire(p.options) }})
}

type sharedSource struct {
	source     *Source
	references int
}

var sources = struct {
	sync.Mutex
	clients map[string]*sharedSource
	closing map[string]chan struct{}
}{clients: map[string]*sharedSource{}, closing: map[string]chan struct{}{}}

type service struct {
	source     *Source
	key        string
	shared     *sharedSource
	ctx        context.Context
	cancel     context.CancelFunc
	mu         sync.Mutex
	disposed   bool
	operations sync.WaitGroup
	closeOnce  sync.Once
	closeErr   error
}

func acquire(options Options) (*service, error) {
	if options.CacheRoot == "" {
		var err error
		options.CacheRoot, err = DefaultCacheRoot()
		if err != nil {
			return nil, err
		}
	}
	key, err := filepath.Abs(options.CacheRoot)
	if err != nil {
		return nil, err
	}
	options.CacheRoot = key
	for {
		sources.Lock()
		if closing := sources.closing[key]; closing != nil {
			sources.Unlock()
			<-closing
			continue
		}
		shared := sources.clients[key]
		if shared == nil {
			if len(sources.clients) >= 32 {
				sources.Unlock()
				return nil, errors.New("too many active model evaluation cache roots")
			}
			source, err := NewSource(options)
			if err != nil {
				sources.Unlock()
				return nil, err
			}
			shared = &sharedSource{source: source}
			sources.clients[key] = shared
		}
		shared.references++
		sources.Unlock()
		ctx, cancel := context.WithCancel(context.Background())
		return &service{source: shared.source, key: key, shared: shared, ctx: ctx, cancel: cancel}, nil
	}
}
func (s *service) begin(ctx context.Context) (context.Context, func(), error) {
	s.mu.Lock()
	if s.disposed {
		s.mu.Unlock()
		return nil, nil, errors.New("artificial analysis service disposed")
	}
	s.operations.Add(1)
	s.mu.Unlock()
	combined, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(s.ctx, cancel)
	return combined, func() { stop(); cancel(); s.operations.Done() }, nil
}
func (s *service) Close() error {
	s.closeOnce.Do(func() {
		s.mu.Lock()
		s.disposed = true
		s.cancel()
		s.mu.Unlock()
		s.operations.Wait()
		sources.Lock()
		s.shared.references--
		if s.shared.references > 0 {
			sources.Unlock()
			return
		}
		delete(sources.clients, s.key)
		done := make(chan struct{})
		sources.closing[s.key] = done
		sources.Unlock()
		s.closeErr = s.source.Close()
		sources.Lock()
		delete(sources.closing, s.key)
		close(done)
		sources.Unlock()
	})
	return s.closeErr
}
func (s *service) Fallback(ctx context.Context, _ plugin.MokuContextInput) (string, error) {
	ctx, done, err := s.begin(ctx)
	if err != nil {
		return "", err
	}
	defer done()
	if err = ctx.Err(); err != nil {
		return "", err
	}
	return FormatCached(s.source.Snapshot()), nil
}
func (s *service) Collect(ctx context.Context, input plugin.MokuContextInput) (string, error) {
	ctx, done, err := s.begin(ctx)
	if err != nil {
		return "", err
	}
	defer done()
	return Collect(ctx, s.source, input)
}

// Collect keeps each harness's advisory evidence independent of discovery failure elsewhere.
func Collect(ctx context.Context, source *Source, input plugin.MokuContextInput) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	blocks := make([]string, len(input.Catalogs))
	var workers sync.WaitGroup
	for index, catalog := range input.Catalogs {
		workers.Add(1)
		go func(index int, catalog plugin.BoundModelCatalog) {
			defer workers.Done()
			started := time.Now()
			timeout := 7500 * time.Millisecond
			if catalog.ID == "opencode" {
				timeout = 20 * time.Second
			}
			bounded, cancel := context.WithTimeout(ctx, timeout)
			defer cancel()
			content, err := collectCatalog(bounded, source, catalog)
			if err != nil {
				event := "aa.context.catalog.failed"
				if errors.Is(ctx.Err(), context.Canceled) {
					event = "aa.context.catalog.cancelled"
				}
				source.log(event, map[string]any{"catalogId": catalog.ID, "class": failureClass(err), "durationMs": time.Since(started).Milliseconds()})
				content = ""
			}
			if content != "" && len(content) <= MaxCatalogBytes {
				content = fmt.Sprintf("### %s (%s)\n%s", catalog.DisplayName, catalog.ID, content)
			} else {
				content = ""
			}
			blocks[index] = content
		}(index, catalog)
	}
	// Catalog callbacks belong to this collection. Cancellation asks them to
	// stop; returning only after they settle lets service.Close drain them.
	workers.Wait()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	accepted := []string{}
	size := 0
	for _, block := range blocks {
		if block == "" {
			continue
		}
		next := len(block)
		if len(accepted) > 0 {
			next += 2
		}
		if size+next > 128*1024 {
			source.log("aa.context.catalog.skipped", map[string]any{"reason": "contribution-byte-limit", "heading": strings.SplitN(block, "\n", 2)[0], "bytes": next})
			continue
		}
		accepted = append(accepted, block)
		size += next
	}
	return strings.Join(accepted, "\n\n"), nil
}
func collectCatalog(ctx context.Context, source *Source, catalog plugin.BoundModelCatalog) (string, error) {
	if catalog.Load == nil {
		return "", errors.New("catalog loader is unavailable")
	}
	raw, err := catalog.Load(ctx)
	if err != nil {
		return "", err
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	var payload struct {
		Models []struct {
			Selector    string          `json:"selector"`
			DisplayName json.RawMessage `json:"displayName"`
			Aliases     []string        `json:"aliases"`
			Provenance  struct {
				Kind string `json:"kind"`
			} `json:"provenance"`
		} `json:"models"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return "", err
	}
	identities := make([]Identity, 0, len(payload.Models))
	acquisition := []AcquisitionIdentity{}
	for _, model := range payload.Models {
		identity := Identity{Selector: model.Selector, Aliases: model.Aliases, DisplayNamePresent: len(model.DisplayName) > 0}
		if identity.DisplayNamePresent {
			if err := json.Unmarshal(model.DisplayName, &identity.DisplayName); err != nil {
				return "", err
			}
		}
		switch model.Provenance.Kind {
		case "unknown":
			identity.SuppressFallback = true
		case "native":
		default:
			return "", errors.New("catalog model provenance is invalid")
		}
		identities = append(identities, identity)
		if !identity.SuppressFallback {
			if identity.EvaluationRelease != nil {
				acquisition = append(acquisition, AcquisitionIdentity{ReleaseSlug: identity.EvaluationRelease})
			} else {
				acquisition = append(acquisition, AcquisitionIdentity{Names: IdentityNames(identity)})
			}
		}
	}
	if err := validateIdentities(identities); err != nil {
		return "", err
	}
	if len(acquisition) == 0 {
		source.log("aa.context.catalog.skipped", map[string]any{"catalogId": catalog.ID, "reason": "no-resolvable-identities", "models": len(identities)})
		return "", nil
	}
	facts, err := source.WaitForBootstrap(ctx, acquisition)
	if err != nil {
		return "", err
	}
	if err = ctx.Err(); err != nil {
		return "", err
	}
	if facts.Availability != "available" {
		source.log("aa.context.catalog.skipped", map[string]any{"catalogId": catalog.ID, "reason": "facts-unavailable"})
		return "", nil
	}
	models := make([]NativeModel, 0, len(identities))
	unmatched := []string{}
	for _, identity := range identities {
		label := identity.Selector
		if identity.DisplayName != "" && identity.DisplayName != identity.Selector {
			label += " (" + identity.DisplayName + ")"
		}
		models = append(models, NativeModel{label, identity})
		if MatchRelease(facts, identity).Status != "matched" {
			unmatched = append(unmatched, identity.Selector)
		}
	}
	content := FormatModels(facts, models)
	source.log("aa.context.catalog.completed", map[string]any{"catalogId": catalog.ID, "models": len(models), "matchedModels": len(models) - len(unmatched), "unmeasured": unmatched, "acquisitionIdentities": len(acquisition), "bytes": len(content), "truncated": strings.Contains(content, truncatedMarker)})
	return content, nil
}
func validateIdentities(identities []Identity) error {
	data, err := json.Marshal(identities)
	if err != nil {
		return err
	}
	if len(identities) > 4096 || len(data) > 2*1024*1024 {
		return errors.New("evaluation identities exceed bounded acquisition limit")
	}
	for _, identity := range identities {
		values := append([]string{identity.Selector}, identity.Aliases...)
		if identity.DisplayNamePresent || identity.DisplayName != "" {
			values = append(values, identity.DisplayName)
		}
		if identity.EvaluationRelease != nil {
			values = append(values, *identity.EvaluationRelease)
		}
		if len(identity.Aliases) > 64 {
			return errors.New("too many evaluation aliases")
		}
		for _, value := range values {
			if value == "" || value != strings.TrimSpace(value) || strings.ContainsRune(value, 0) || len(value) > 1024 {
				return errors.New("evaluation identity must be a canonical bounded string")
			}
		}
	}
	return nil
}
