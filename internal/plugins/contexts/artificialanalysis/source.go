package artificialanalysis

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

const indexURL = "https://artificialanalysis.ai/models/"

type HTTPClient interface {
	Do(*http.Request) (*http.Response, error)
}
type Options struct {
	CacheRoot   string
	HTTPClient  HTTPClient
	Now         func() time.Time
	OnPublished func(Snapshot)
	Log         func(string, map[string]any)
}
type refreshCall struct {
	done chan struct{}
	err  error
}

// Source serializes generations while letting callers cancel their own wait.
// A warm cache never blocks a Moku send on advisory HTTP acquisition.
type Source struct {
	mu           sync.Mutex
	options      Options
	current      *persistedSnapshot
	pending      map[string]*refreshCall
	refreshAfter map[string]time.Time
	order        []string
	tail         chan struct{}
	ctx          context.Context
	cancel       context.CancelFunc
	stopped      bool
}

func DefaultCacheRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	root := ""
	switch runtime.GOOS {
	case "windows":
		root = os.Getenv("LOCALAPPDATA")
		if root == "" {
			root = filepath.Join(home, "AppData/Local")
		}
	case "darwin":
		root = filepath.Join(home, "Library/Caches")
	default:
		root = os.Getenv("XDG_CACHE_HOME")
		if root == "" {
			root = filepath.Join(home, ".cache")
		}
	}
	return filepath.Join(root, "Mokusei/model-evaluation"), nil
}
func NewSource(options Options) (*Source, error) {
	if options.CacheRoot == "" {
		var err error
		options.CacheRoot, err = DefaultCacheRoot()
		if err != nil {
			return nil, err
		}
	}
	root, err := filepath.Abs(options.CacheRoot)
	if err != nil {
		return nil, err
	}
	options.CacheRoot = root
	if options.HTTPClient == nil {
		options.HTTPClient = http.DefaultClient
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	ctx, cancel := context.WithCancel(context.Background())
	tail := make(chan struct{})
	close(tail)
	s := &Source{options: options, pending: map[string]*refreshCall{}, refreshAfter: map[string]time.Time{}, tail: tail, ctx: ctx, cancel: cancel}
	path := filepath.Join(root, "moku-evaluation-facts.json")
	if info, err := os.Stat(path); err == nil && info.Size() <= MaxFactsBytes {
		if data, err := os.ReadFile(path); err == nil {
			if loaded, err := parsePersisted(data); err == nil {
				for i := range loaded.Configurations {
					loaded.Configurations[i].ETag = ""
				}
				s.current = loaded
			}
		}
	}
	return s, nil
}
func (s *Source) log(event string, fields map[string]any) {
	if s.options.Log != nil {
		s.options.Log(event, fields)
	}
}
func (s *Source) Snapshot() Snapshot { s.mu.Lock(); defer s.mu.Unlock(); return snapshot(s.current) }
func normalizeIdentities(values []AcquisitionIdentity) ([]AcquisitionIdentity, error) {
	if len(values) > 4096 {
		return nil, fmt.Errorf("local model identity sets cannot exceed 4096")
	}
	result := make([]AcquisitionIdentity, 0, len(values))
	for _, identity := range values {
		if identity.ReleaseSlug != nil {
			slug := canonical(*identity.ReleaseSlug, 1024)
			result = append(result, AcquisitionIdentity{ReleaseSlug: &slug})
			continue
		}
		names := []string{}
		seen := map[string]bool{}
		for _, name := range identity.Names {
			name = strings.TrimSpace(name)
			if name != "" && len(utf16.Encode([]rune(name))) <= 1024 && !strings.ContainsRune(name, 0) && !seen[name] {
				seen[name] = true
				names = append(names, name)
			}
		}
		result = append(result, AcquisitionIdentity{Names: names})
	}
	return result, nil
}
func identityKey(identities []AcquisitionIdentity) string {
	rows := []string{}
	for _, identity := range identities {
		var value any
		if identity.ReleaseSlug != nil {
			value = map[string]string{"releaseSlug": *identity.ReleaseSlug}
		} else {
			names := append([]string{}, identity.Names...)
			sort.Strings(names)
			value = names
		}
		data, _ := json.Marshal(value)
		rows = append(rows, string(data))
	}
	sort.Strings(rows)
	hash := sha256.Sum256([]byte(strings.Join(rows, "\x00")))
	return hex.EncodeToString(hash[:])
}
func (s *Source) WaitForBootstrap(ctx context.Context, values []AcquisitionIdentity) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	identities, err := normalizeIdentities(values)
	if err != nil {
		return Snapshot{}, err
	}
	key := identityKey(identities)
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return Snapshot{}, errors.New("artificial analysis source is stopped")
	}
	warm := s.current != nil
	call := s.pending[key]
	if call == nil && !s.options.Now().Before(s.refreshAfter[key]) {
		call = s.refreshLocked(identities, key)
	}
	s.mu.Unlock()
	if !warm && call != nil {
		select {
		case <-ctx.Done():
			return Snapshot{}, ctx.Err()
		case <-s.ctx.Done():
			return Snapshot{}, s.ctx.Err()
		case <-call.done:
		}
	}
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	return s.Snapshot(), nil
}
func (s *Source) Refresh(ctx context.Context, values []AcquisitionIdentity) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	identities, err := normalizeIdentities(values)
	if err != nil {
		return err
	}
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return errors.New("artificial analysis source is stopped")
	}
	call := s.refreshLocked(identities, identityKey(identities))
	s.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-call.done:
		return call.err
	}
}
func (s *Source) refreshLocked(identities []AcquisitionIdentity, key string) *refreshCall {
	if existing := s.pending[key]; existing != nil {
		return existing
	}
	call := &refreshCall{done: make(chan struct{})}
	previous := s.tail
	s.tail = call.done
	s.pending[key] = call
	if _, known := s.refreshAfter[key]; !known {
		if len(s.order) >= 4096 {
			delete(s.refreshAfter, s.order[0])
			s.order = s.order[1:]
		}
		s.order = append(s.order, key)
	}
	// A generation refreshes only its own catalog's releases. Another
	// catalog's success must neither defer this one nor enqueue a fresh one.
	s.refreshAfter[key] = s.options.Now().Add(10 * time.Minute)
	go func() {
		<-previous
		started := time.Now()
		generationError := s.ctx.Err()
		if generationError == nil {
			generationError = s.refreshGeneration(identities)
		}
		published := generationError == nil
		if generationError != nil {
			event := "aa.facts.refresh.failed"
			if s.ctx.Err() != nil {
				event = "aa.facts.refresh.cancelled"
			}
			s.mu.Lock()
			retained := s.current != nil
			s.mu.Unlock()
			s.log(event, map[string]any{"class": failureClass(generationError), "durationMs": time.Since(started).Milliseconds(), "retained": retained})
		}
		s.mu.Lock()
		delay := 10 * time.Minute
		if published {
			delay = 24 * time.Hour
		}
		if _, known := s.refreshAfter[key]; known {
			s.refreshAfter[key] = s.options.Now().Add(delay)
		}
		delete(s.pending, key)
		call.err = generationError
		close(call.done)
		s.mu.Unlock()
	}()
	return call
}
func (s *Source) Close() error {
	s.mu.Lock()
	if !s.stopped {
		s.stopped = true
		s.cancel()
	}
	tail := s.tail
	s.mu.Unlock()
	<-tail
	return nil
}
func (s *Source) refreshGeneration(identities []AcquisitionIdentity) error {
	s.mu.Lock()
	previous := s.current
	s.mu.Unlock()
	previousConfigurations := []persistedConfiguration{}
	if previous != nil {
		previousConfigurations = previous.Configurations
	}
	response, err := s.fetch(indexURL, "")
	if err != nil {
		return err
	}
	if response.status != "ok" {
		return errors.New("Artificial Analysis model index is unavailable")
	}
	if err := validateIndexVersion(response.body); err != nil {
		return err
	}
	index := parseIndex(response.body)
	if len(index) == 0 {
		return errors.New("Artificial Analysis model index has no configurations")
	}
	all := append([]target{}, index...)
	for _, entry := range previousConfigurations {
		configuration := entry.Configuration
		all = append(all, target{entry.Slug, entry.ReleaseSlug, entry.ReleaseName, &configuration})
	}
	roster := []Release{}
	seenReleases := map[string]bool{}
	for _, entry := range all {
		if !seenReleases[entry.ReleaseSlug] {
			seenReleases[entry.ReleaseSlug] = true
			roster = append(roster, Release{Slug: entry.ReleaseSlug, Name: entry.ReleaseName})
		}
	}
	matched := map[string]bool{}
	for _, identity := range identities {
		var match Match
		if identity.ReleaseSlug != nil {
			match = matchSlug(*identity.ReleaseSlug, roster)
		} else {
			match = MatchNames(identity.Names, roster)
		}
		if match.Status == "matched" {
			matched[match.Release.Slug] = true
		}
	}
	targets := []target{}
	seen := map[string]bool{}
	for _, entry := range all {
		if matched[entry.ReleaseSlug] && !seen[entry.Slug] {
			seen[entry.Slug] = true
			targets = append(targets, entry)
		}
	}
	s.log("aa.facts.refresh.targets", map[string]any{"identities": len(identities), "indexConfigurations": len(index), "matchedReleases": len(matched), "targets": len(targets)})
	prior := map[string]persistedConfiguration{}
	for _, entry := range previousConfigurations {
		prior[entry.Slug] = entry
	}
	results := make([]*persistedConfiguration, len(targets))
	jobs := make(chan int)
	var workers sync.WaitGroup
	for range min(4, len(targets)) {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for index := range jobs {
				if s.ctx.Err() != nil {
					return
				}
				var previous *persistedConfiguration
				if value, ok := prior[targets[index].Slug]; ok {
					previous = &value
				}
				results[index] = s.refreshConfiguration(targets[index], previous)
			}
		}()
	}
dispatch:
	for i := range targets {
		if s.ctx.Err() != nil {
			break
		}
		select {
		case <-s.ctx.Done():
			break dispatch
		case jobs <- i:
		}
	}
	close(jobs)
	workers.Wait()
	if err = s.ctx.Err(); err != nil {
		return err
	}
	configurations := []persistedConfiguration{}
	for _, entry := range previousConfigurations {
		if !seen[entry.Slug] {
			configurations = append(configurations, entry)
		}
	}
	for _, entry := range results {
		if entry != nil {
			configurations = append(configurations, *entry)
		}
	}
	sort.Slice(configurations, func(i, j int) bool { return configurations[i].Slug < configurations[j].Slug })
	if len(configurations) > 10000 {
		return errors.New("Artificial Analysis configuration cache is too large")
	}
	now := isoNow(s.options.Now())
	next := persistedSnapshot{SchemaVersion: cacheSchemaVersion, IntelligenceIndexVersion: IntelligenceIndexVersion, Source: SourceID, ObservedAt: now, FetchedAt: now, Configurations: configurations}
	data, err := json.Marshal(next)
	if err != nil {
		return err
	}
	validated, err := parsePersisted(data)
	if err != nil {
		return err
	}
	if err = s.ctx.Err(); err != nil {
		return err
	}
	if err = os.MkdirAll(s.options.CacheRoot, 0700); err != nil {
		return err
	}
	if err = profile.AtomicWrite(filepath.Join(s.options.CacheRoot, "moku-evaluation-facts.json"), data); err != nil {
		return err
	}
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return s.ctx.Err()
	}
	s.current = validated
	s.mu.Unlock()
	if s.options.OnPublished != nil {
		s.options.OnPublished(s.Snapshot())
	}
	return nil
}
func (s *Source) refreshConfiguration(target target, previous *persistedConfiguration) *persistedConfiguration {
	started := time.Now()
	observed := isoNow(s.options.Now())
	fallback := func() *persistedConfiguration {
		if previous != nil {
			copy := *previous
			copy.ObservedAt = observed
			return &copy
		}
		if target.Configuration != nil {
			return &persistedConfiguration{Slug: target.Slug, ReleaseSlug: target.ReleaseSlug, ReleaseName: target.ReleaseName, Configuration: *target.Configuration, ObservedAt: observed}
		}
		return nil
	}
	etag := ""
	if previous != nil {
		etag = previous.ETag
	}
	response, err := s.fetch(indexURL+url.PathEscape(target.Slug), etag)
	class := failureClass(err)
	if err == nil {
		switch response.status {
		case "gone":
			return nil
		case "not-modified":
			entry := fallback()
			if entry != nil && response.etag != "" {
				entry.ETag = response.etag
			}
			return entry
		}
	}
	if err == nil {
		identity, facts, parseErr := parsePage(response.body, target.Slug)
		err = parseErr
		class = "invalid-document"
		if err == nil && (identity.Slug != target.Slug || identity.ReleaseSlug != target.ReleaseSlug) {
			err = errors.New("AA detail page does not match requested configuration")
			class = "identity-mismatch"
		}
		if err == nil {
			return &persistedConfiguration{Slug: identity.Slug, ReleaseSlug: identity.ReleaseSlug, ReleaseName: identity.ReleaseName, Configuration: *identity.Configuration, ObservedAt: observed, ETag: response.etag, Facts: &facts}
		}
	}
	// Source shutdown is reported once per generation, not once per queued model.
	if s.ctx.Err() == nil {
		s.log("aa.facts.configuration.failed", map[string]any{"class": class, "durationMs": time.Since(started).Milliseconds(), "retained": previous != nil})
	}
	return fallback()
}

type document struct{ status, body, etag string }

func (s *Source) fetch(address, etag string) (document, error) {
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		if err := s.ctx.Err(); err != nil {
			return document{}, err
		}
		ctx, cancel := context.WithTimeout(s.ctx, 15*time.Second)
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
		if err != nil {
			cancel()
			return document{}, err
		}
		if etag != "" {
			request.Header.Set("If-None-Match", etag)
		}
		response, err := s.options.HTTPClient.Do(request)
		if err == nil {
			responseETag := response.Header.Get("ETag")
			if responseETag == "" {
				responseETag = etag
			}
			switch response.StatusCode {
			case http.StatusNotFound, http.StatusGone:
				response.Body.Close()
				cancel()
				return document{status: "gone"}, nil
			case http.StatusNotModified:
				response.Body.Close()
				cancel()
				return document{status: "not-modified", etag: responseETag}, nil
			default:
				if response.StatusCode >= 200 && response.StatusCode < 300 {
					var body []byte
					body, err = io.ReadAll(io.LimitReader(response.Body, 32*1024*1024+1))
					if err == nil && len(body) > 32*1024*1024 {
						err = errors.New("AA source document exceeds 32 MiB")
					}
					response.Body.Close()
					cancel()
					if err == nil {
						return document{status: "ok", body: string(body), etag: responseETag}, nil
					}
				} else {
					response.Body.Close()
					err = httpFailure(response.StatusCode)
				}
			}
		}
		cancel()
		last = err
		if attempt < 2 {
			timer := time.NewTimer(time.Duration(250*(1<<attempt)) * time.Millisecond)
			select {
			case <-s.ctx.Done():
				timer.Stop()
				return document{}, s.ctx.Err()
			case <-timer.C:
			}
		}
	}
	return document{}, last
}
