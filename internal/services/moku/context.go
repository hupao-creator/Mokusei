package moku

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type targetRefreshUnavailable struct{ cause error }

func (e *targetRefreshUnavailable) Error() string { return e.cause.Error() }
func (e *targetRefreshUnavailable) Unwrap() error { return e.cause }

func (c *Coordinator) describeTargets(ctx context.Context, settings model.Settings) (ThreadCreationDescription, error) {
	type input struct {
		id       string
		harness  plugin.Harness
		settings json.RawMessage
	}
	inputs := []input{}
	for _, id := range settings.Moku.TargetHarnessIDs {
		h := c.config.Harnesses[id]
		if h == nil || c.config.HarnessEnabled != nil && !c.config.HarnessEnabled(id) {
			continue
		}
		// Capture independent immutable inputs before workers run. The settings
		// admission owner continues to fence this entire discovery operation.
		inputs = append(inputs, input{id, h, mergedSettings(settings, id, false)})
	}
	type result struct {
		target TargetDescription
		err    error
	}
	results := make([]result, len(inputs))
	var pending sync.WaitGroup
	gate := make(chan struct{}, 4)
	for i, source := range inputs {
		pending.Add(1)
		go func(index int, source input) {
			defer pending.Done()
			defer func() {
				if recover() != nil {
					results[index].err = fmt.Errorf("Moku Target Harness discovery failed: %s", source.id)
				}
			}()
			select {
			case gate <- struct{}{}:
				defer func() { <-gate }()
			case <-ctx.Done():
				results[index].err = ctx.Err()
				return
			}
			results[index].target, results[index].err = c.describeTarget(ctx, source.id, source.harness, source.settings)
		}(i, source)
	}
	// Cancellation never detaches native probes from the operation/Close owner.
	pending.Wait()
	if err := ctx.Err(); err != nil {
		return ThreadCreationDescription{}, err
	}
	targets := []TargetDescription{}
	for _, result := range results {
		// Configuration order, not completion order, owns schemas and failures.
		if result.err != nil {
			return ThreadCreationDescription{}, &targetRefreshUnavailable{result.err}
		}
		target := result.target
		if target.DeferredNative || len(target.NativeSchema) > 0 {
			targets = append(targets, target)
		}
	}
	if len(targets) == 0 {
		return ThreadCreationDescription{}, &targetRefreshUnavailable{errors.New("Moku 没有可用的 Target Harness")}
	}
	return DescribeThreadCreation(targets, c.config.Workspace)
}

func (c *Coordinator) describeTarget(ctx context.Context, id string, h plugin.Harness, merged json.RawMessage) (TargetDescription, error) {
	target := TargetDescription{HarnessID: id, DisplayName: h.Descriptor().DisplayName}
	var availability plugin.Availability
	var err error
	if discovery, ok := h.(plugin.MokuTargetDiscoverer); ok {
		target.NativeSchema, availability, err = discovery.DiscoverMokuTarget(ctx, plugin.SettingsRequest{Settings: merged, Cwd: c.config.Workspace})
		target.DeferredNative = err == nil && availability.Available && len(target.NativeSchema) == 0
	} else {
		availability, err = c.available(ctx, h, merged)
		if err == nil && availability.Available {
			target.NativeSchema, err = h.Settings().Describe(ctx, plugin.SettingsRequest{Settings: merged, Cwd: c.config.Workspace})
			if err != nil {
				return target, err
			}
		}
	}
	return target, nil
}

func (c *Coordinator) collectNativeContext(ctx context.Context, entryID string, settings model.Settings) ([]plugin.ContextEntry, error) {
	timeout := 2 * time.Second
	if entryID == "telemetry" {
		timeout = 7500 * time.Millisecond
	}
	type source struct {
		id, label string
		collect   func(context.Context) (string, error)
	}
	sources := []source{}
	ids := make([]string, 0, len(c.config.Harnesses))
	for id := range c.config.Harnesses {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if c.config.HarnessEnabled != nil && !c.config.HarnessEnabled(id) {
			continue
		}
		harness := c.config.Harnesses[id]
		contributor, ok := harness.(plugin.MokuContextContributor)
		if !ok {
			continue
		}
		var ledger plugin.TelemetryLedger
		if c.config.Ledger != nil {
			ledger = c.config.Ledger(id)
		}
		sources = append(sources, source{id: id, label: harness.Descriptor().DisplayName + " (" + id + ")", collect: func(ctx context.Context) (string, error) {
			return contributor.MokuContext(ctx, entryID, plugin.SettingsRequest{Settings: mergedSettings(settings, id, false), Cwd: c.config.Workspace}, ledger)
		}})
	}
	type result struct {
		text string
		err  error
	}
	outputs := make([]chan result, len(sources))
	for index, source := range sources {
		output := make(chan result, 1)
		outputs[index] = output
		contributionCtx, cancel := context.WithTimeout(ctx, timeout)
		if !c.launch(func(context.Context) {
			result := result{}
			func() {
				defer func() {
					if recover() != nil {
						result.err = errors.New("Moku context contributor panicked")
					}
				}()
				result.text, result.err = source.collect(contributionCtx)
			}()
			output <- result
		}) {
			cancel()
			output <- result{err: context.Canceled}
		}
		// A separate bounded waiter returns on timeout even if an adapter ignores
		// cancellation; the underlying operation remains tracked for shutdown.
		original := output
		bounded := make(chan result, 1)
		outputs[index] = bounded
		go func() {
			defer cancel()
			select {
			case value := <-original:
				bounded <- value
			case <-contributionCtx.Done():
				bounded <- result{err: contributionCtx.Err()}
			}
		}()
	}
	blocks := []string{}
	size := 0
	for index, output := range outputs {
		var value result
		select {
		case value = <-output:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		if value.err != nil {
			c.report("context:"+sources[index].id+":"+entryID, value.err)
			continue
		}
		if value.text == "" {
			continue
		}
		if len(value.text) > 32*1024 {
			c.report("context", fmt.Errorf("%s %s contribution exceeds32KiB", sources[index].id, entryID))
			continue
		}
		block := "### " + sources[index].label + "\n" + value.text
		separator := 0
		if len(blocks) > 0 {
			separator = 2
		}
		if size+len(block)+separator > 128*1024 {
			c.report("context", fmt.Errorf("%s entry exceeds128KiB", entryID))
			continue
		}
		blocks = append(blocks, block)
		size += len(block) + separator
	}
	if len(blocks) == 0 {
		return []plugin.ContextEntry{}, nil
	}
	return []plugin.ContextEntry{{ID: entryID, Content: strings.Join(blocks, "\n\n")}}, nil
}
func (c *Coordinator) collectContext(ctx context.Context, phase string, settings model.Settings) ([]plugin.ContextEntry, error) {
	native := []plugin.ContextEntry{}
	var err error
	if phase == "session-start" {
		native, err = c.collectNativeContext(ctx, "workspace", settings)
		if err != nil {
			return nil, err
		}
	}
	applications := []plugin.ContextEntry{}
	if c.config.CollectContext != nil {
		applications, err = c.config.CollectContext(ctx, phase, settings)
		if err != nil {
			return nil, err
		}
	}
	return mergeContext(applications, native), ctx.Err()
}
func mergeContext(groups ...[]plugin.ContextEntry) []plugin.ContextEntry {
	entries := []plugin.ContextEntry{}
	indices := map[string]int{}
	for _, group := range groups {
		for _, entry := range group {
			if index, ok := indices[entry.ID]; ok {
				entries[index].Content += "\n\n" + entry.Content
			} else {
				indices[entry.ID] = len(entries)
				entries = append(entries, entry)
			}
		}
	}
	return entries
}
func (c *Coordinator) refreshLoop(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		c.mu.Lock()
		applied := c.applied
		generation := c.generation
		c.mu.Unlock()
		if applied != nil {
			entries, err := c.collectNativeContext(ctx, "telemetry", applied.AppliedSettings)
			if err != nil && ctx.Err() == nil {
				c.report("context-refresh", err)
			}
			c.mu.Lock()
			if c.running && generation == c.generation && err == nil {
				c.runContext = append([]plugin.ContextEntry{}, entries...)
				c.runContextGeneration = generation
			}
			c.mu.Unlock()
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-c.refreshWake:
		}
	}
}
func (c *Coordinator) sendContext(ctx context.Context, input model.AgentInput, directoryTag *string) ([]plugin.ContextEntry, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		c.mu.Lock()
		applied := c.applied
		generation := c.generation
		ready := c.runContext != nil && c.runContextGeneration == generation
		native := append([]plugin.ContextEntry{}, c.runContext...)
		c.mu.Unlock()
		if applied == nil {
			return nil, errors.New("Moku configuration unavailable")
		}
		if !ready {
			// Account capacity is advisory. A slow first refresh must not hold
			// message admission; execution still validates its own credentials.
			native = []plugin.ContextEntry{{ID: "telemetry", Content: "Account telemetry for the current configuration is pending in the background. Account availability, balances and rate limits are unknown. Do not assume unlimited capacity or reuse another account's quota. A later message may receive the refreshed account snapshot."}}
		}
		applications, err := c.collectContext(ctx, "before-send", applied.AppliedSettings)
		if err != nil {
			return nil, err
		}
		entries, err := c.withWorkspaceHint(mergeContext(applications, native), input, directoryTag)
		if err != nil {
			return nil, err
		}
		c.mu.Lock()
		same := generation == c.generation
		c.mu.Unlock()
		if !same {
			continue
		}
		record, err := c.current()
		if err != nil {
			return nil, err
		}
		return withNoteContext(entries, record), nil
	}
}

// withNoteContext prepends Moku's own note to every outbound input. Moku
// authored the note, but harness context compaction can still drop earlier
// turns, so each send carries the current value rather than relying on history.
func withNoteContext(entries []plugin.ContextEntry, record model.ThreadRecord) []plugin.ContextEntry {
	return append([]plugin.ContextEntry{{ID: "moku-note", Content: MokuNoteContext(model.SnapshotNote(record.Note))}}, entries...)
}
func (c *Coordinator) withWorkspaceHint(entries []plugin.ContextEntry, input model.AgentInput, directoryTag *string) ([]plugin.ContextEntry, error) {
	directories := []string{}
	seen := map[string]bool{}
	mentioned := false
	truncated := false
	for _, part := range input.Parts {
		if part.Kind == "mention" && part.PathType == "directory" && !seen[part.Path] {
			directories = append(directories, part.Path)
			seen[part.Path] = true
			mentioned = true
		}
	}
	if !mentioned && directoryTag != nil {
		tag := strings.TrimSpace(*directoryTag)
		if tag == "" || model.UTF16Length(*directoryTag) > 256 || strings.ContainsRune(tag, 0) {
			return nil, errors.New("directoryTag 无效")
		}
		// Explicit directory mentions already carry the complete hint. Only a
		// directory tag needs the Thread catalog to resolve matching workspaces.
		records, err := c.config.Threads()
		if err != nil {
			return nil, err
		}
		sort.SliceStable(records, func(i, j int) bool { return records[i].UpdatedAt > records[j].UpdatedAt })
		for _, record := range records {
			if record.Moku || ThreadTagKey(ThreadDirectoryTag(record.Cwd)) != ThreadTagKey(tag) {
				continue
			}
			cwd := record.Cwd
			if cwd == "" || seen[cwd] {
				continue
			}
			seen[cwd] = true
			if len(directories) == 8 {
				truncated = true
				break
			}
			directories = append(directories, cwd)
		}
	}
	if len(directories) == 0 {
		return entries, nil
	}
	quoted := make([]string, len(directories))
	for i, directory := range directories {
		raw, _ := json.Marshal(directory)
		quoted[i] = "- " + string(raw)
	}
	content := "The user's entire request concerns work in these directories:\n" + strings.Join(quoted, "\n")
	if truncated {
		content = "The user's entire request concerns work in these and other matching directories (partial list):\n" + strings.Join(quoted, "\n")
	}
	if mentioned {
		content = "The user explicitly referenced these directories:\n" + strings.Join(quoted, "\n") + "\nUse these references to interpret current-project requests and choose cwd for related delegated work. Determine each directory's role from the user's request; a reference alone does not request changes to that directory."
	}
	return mergeContext(entries, []plugin.ContextEntry{{ID: "workspace", Content: content}}), nil
}
