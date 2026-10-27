package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode/utf16"

	"golang.org/x/text/cases"
	"golang.org/x/text/language"
	"golang.org/x/text/unicode/norm"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"github.com/hupao-creator/Mokusei/internal/services/taglabel"
)

const (
	maxScopeTags       = 5
	maxBatchAssignment = 100
)

type tagDefinition struct {
	Emoji       string `json:"emoji"`
	Name        string `json:"name"`
	Description string `json:"description"`
}
type tagsSnapshotCapability struct {
	runtime  *Runtime
	snapshot store.Snapshot
	issue    func(string, int64) (plugin.MutationScope, error)
}

func (c tagsSnapshotCapability) Scope() (plugin.MutationScope, error) {
	if c.issue == nil {
		return plugin.MutationScope{}, errors.New("snapshot cannot issue mutation scopes")
	}
	return c.issue("semantic-tags", int64(c.snapshot.Revision()))
}
func (c tagsSnapshotCapability) ReadThreadTags(ref model.ThreadRef) (model.TagProjection, error) {
	if ref.TypeID == "agent" {
		t, err := (taskSnapshotCapability{runtime: c.runtime, snapshot: c.snapshot, issue: c.issue}).record(ref)
		if err != nil {
			return model.TagProjection{}, err
		}
		if t == nil {
			return model.TagProjection{}, errors.New("unknown ordinary task")
		}
		return threadTags(*t), nil
	}
	if app, ok := c.runtime.config.Applications.(interface {
		ReadThreadTags(store.Snapshot, model.ThreadRef) (model.TagProjection, error)
	}); ok {
		return app.ReadThreadTags(c.snapshot, ref)
	}
	return model.TagProjection{}, errors.New("application thread tags unavailable")
}

type tagsReadCapability struct {
	runtime *Runtime
	scope   string
}

func (c tagsReadCapability) scopeID() string { return tagScope(c.scope) }

func (c tagsReadCapability) CaptureList(ctx context.Context) ([]plugin.SemanticTagSummary, error) {
	pool, _, err := readTags(c.runtime.config.Store.Snapshot(), c.scopeID())
	if err != nil {
		return nil, err
	}
	result := []plugin.SemanticTagSummary{}
	for _, tag := range pool {
		usage, err := c.CaptureUsage(ctx, tag.Name)
		if err != nil {
			return nil, err
		}
		byType := map[string]*plugin.TagTypeUsageCount{}
		for _, thread := range usage.Threads {
			entry := byType[thread.Ref.TypeID]
			if entry == nil {
				entry = &plugin.TagTypeUsageCount{TypeID: thread.Ref.TypeID}
				byType[thread.Ref.TypeID] = entry
			}
			entry.Total++
			if thread.Archived {
				entry.Archived++
			}
		}
		counts := []plugin.TagTypeUsageCount{}
		for _, value := range byType {
			counts = append(counts, *value)
		}
		sort.Slice(counts, func(i, j int) bool { return counts[i].TypeID < counts[j].TypeID })
		result = append(result, plugin.SemanticTagSummary{Emoji: tag.Emoji, Name: tag.Name, Description: tag.Description, Usage: counts})
	}
	return result, nil
}
func (c tagsReadCapability) CaptureUsage(ctx context.Context, name string) (plugin.SemanticTagUsage, error) {
	pool, redirects, err := readTags(c.runtime.config.Store.Snapshot(), c.scopeID())
	if err != nil {
		return plugin.SemanticTagUsage{}, err
	}
	canonical := resolveTag(pool, redirects, name)
	result := plugin.SemanticTagUsage{CanonicalName: canonical, Threads: []plugin.SemanticTagThread{}}
	if canonical == nil {
		return result, nil
	}
	tasks, err := (taskReadCapability{runtime: c.runtime, binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}).CaptureList(ctx, true)
	if err != nil {
		return result, err
	}
	for _, t := range tasks {
		if directorytag.Scope(t.Cwd) != c.scopeID() {
			continue
		}
		for _, tag := range t.Tags.SemanticTags {
			if tagKey(tag) == tagKey(*canonical) {
				result.Threads = append(result.Threads, plugin.SemanticTagThread{Ref: t.Ref, Title: t.Title, Tags: t.Tags, Archived: t.Archived})
				break
			}
		}
	}
	return result, nil
}

type tagsWriteCapability struct {
	runtime *Runtime
	source  string
	scope   string
}

func (c tagsWriteCapability) scopeID() string { return tagScope(c.scope) }

// RefreshApplicationDirectoryTags recomputes derived labels before background
// participants start. Keep each application's semantic names unchanged.
func (r *Runtime) RefreshApplicationDirectoryTags(ctx context.Context) error {
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	ctx, cancel := r.operationContext(ctx)
	defer cancel()
	r.mu.Lock()
	applications, ok := r.config.Applications.(interface {
		ApplySemanticTags(*store.Tx, plugin.SemanticTagEffect) error
	})
	r.mu.Unlock()
	if !ok {
		return nil
	}
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		threads, err := readThreads(tx.Snapshot())
		if err != nil {
			return err
		}
		sources := []plugin.ThreadTagSnapshot{}
		for _, thread := range threads {
			if !thread.Moku {
				sources = append(sources, plugin.ThreadTagSnapshot{Thread: model.ThreadRef{ThreadID: thread.ID, TypeID: "agent"}, Tags: threadTags(thread)})
			}
		}
		return applications.ApplySemanticTags(tx, plugin.SemanticTagEffect{
			SourceThreads: sources,
		})
	})
	return err
}

func (c tagsWriteCapability) EnsureInventory(ctx context.Context) error {
	r := c.runtime
	scope := c.scopeID()
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		if tx.Has(tagInventoryKey(scope)) {
			return nil
		}
		threads, err := readThreads(tx.Snapshot())
		if err != nil {
			return err
		}
		scoped := []model.ThreadRecord{}
		for _, thread := range threads {
			if thread.Moku || directorytag.Scope(thread.Cwd) != scope {
				continue
			}
			scoped = append(scoped, thread)
		}
		for _, thread := range scoped {
			if err := r.appendEvent(tx, "thread.inventory", store.Subject{Kind: "thread", ID: thread.ID, TypeID: "agent"}, c.source, map[string]any{"title": thread.Title}, nil); err != nil {
				return err
			}
		}
		return tx.Put(tagInventoryKey(scope), true)
	})
	return err
}
func (c tagsWriteCapability) Execute(ctx context.Context, operation plugin.SemanticTagOperation, options plugin.BackgroundWriteOptions) (json.RawMessage, error) {
	r := c.runtime
	var output json.RawMessage
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		effect := func(tx *store.Tx) (any, error) { return c.apply(tx, operation) }
		if options.Batch.BatchID != "" {
			raw, err := tx.ApplyReceipt(store.Receipt{ConsumerID: options.Batch.ConsumerID, BatchID: options.Batch.BatchID, Key: options.Batch.InvocationID}, effect)
			output = raw
			return err
		}
		if options.RequestID == "" {
			return errors.New("tag operation requestId is required")
		}
		key := "tag-receipt:" + c.source + ":" + c.scopeID() + ":" + options.RequestID
		if raw, ok := tx.Raw(key); ok {
			output = raw
			return nil
		}
		value, err := effect(tx)
		if err != nil {
			return err
		}
		output, err = json.Marshal(value)
		if err != nil {
			return err
		}
		return tx.PutRaw(key, output)
	})
	return output, err
}
func (c tagsWriteCapability) apply(tx *store.Tx, op plugin.SemanticTagOperation) (any, error) {
	scope := c.scopeID()
	pool, redirects, err := readTags(tx.Snapshot(), scope)
	if err != nil {
		return nil, err
	}
	known := func(name string) (tagDefinition, error) {
		canonical := resolveTag(pool, redirects, name)
		if canonical != nil {
			for _, tag := range pool {
				if tagKey(tag.Name) == tagKey(*canonical) {
					return tag, nil
				}
			}
		}
		return tagDefinition{}, fmt.Errorf("semantic tag does not exist: %s", name)
	}
	// A semantic tag that normalizes to the scope's directory label would be
	// ambiguous with the directory chip in the Overview, so it cannot be
	// created or renamed into.
	labelKey := ""
	if scope != directorytag.InboxScope {
		labelKey = tagKey(directorytag.Name(scope))
	}
	rejectLabel := func(name string) error {
		if labelKey != "" && tagKey(name) == labelKey {
			return fmt.Errorf("tag name duplicates the directory filter: %s", name)
		}
		return nil
	}
	var result any
	assignments := []plugin.SemanticTagAssignment{}
	switch op.Kind {
	case "create", "create-many":
		definitions := op.Definitions
		if op.Kind == "create" {
			if op.Emoji == nil {
				return nil, errors.New("tag creation requires emoji")
			}
			definitions = []plugin.SemanticTagInput{{Name: op.Name, Emoji: *op.Emoji}}
		}
		if len(definitions) == 0 || len(definitions) > maxScopeTags {
			return nil, errors.New("invalid tag creation count")
		}
		created := []tagDefinition{}
		for _, definition := range definitions {
			if definition.Emoji == "" {
				return nil, errors.New("tag creation requires emoji")
			}
			name, err := normalizeTag(definition.Name, 32, false)
			if err != nil {
				return nil, err
			}
			if current, ok := findTag(pool, name); ok {
				created = append(created, current)
				continue
			}
			if err := rejectLabel(name); err != nil {
				return nil, err
			}
			if len(pool) >= maxScopeTags {
				return nil, fmt.Errorf("tag pool is full: %s", tagNames(pool))
			}
			description := name
			if op.Description != nil {
				description, err = normalizeTag(*op.Description, 120, true)
				if err != nil {
					return nil, err
				}
			}
			entry := tagDefinition{Name: name, Description: description, Emoji: taglabel.Emoji(definition.Emoji)}
			pool = append(pool, entry)
			delete(redirects, tagKey(name))
			created = append(created, entry)
		}
		if op.Kind == "create" {
			result = created[0]
		} else {
			result = created
		}
	case "update":
		current, err := known(op.Name)
		if err != nil {
			return nil, err
		}
		name := current.Name
		description := current.Description
		emoji := current.Emoji
		if op.Emoji != nil {
			if *op.Emoji == "" {
				return nil, errors.New("tag emoji must not be empty")
			}
			emoji = taglabel.Emoji(*op.Emoji)
		}
		if op.NewName != "" {
			name, err = normalizeTag(op.NewName, 32, false)
			if err != nil {
				return nil, err
			}
			if tagKey(name) != tagKey(current.Name) {
				if err := rejectLabel(name); err != nil {
					return nil, err
				}
			}
		}
		if op.Description != nil {
			description, err = normalizeTag(*op.Description, 120, true)
			if err != nil {
				return nil, err
			}
		}
		if op.NewName == "" && op.Description == nil && op.Emoji == nil {
			return nil, errors.New("tag update requires name, description or emoji")
		}
		if tagKey(name) != tagKey(current.Name) {
			if _, exists := findTag(pool, name); exists {
				return nil, errors.New("rename target already exists; use merge")
			}
			redirects[tagKey(current.Name)] = &name
			delete(redirects, tagKey(name))
		}
		for i := range pool {
			if tagKey(pool[i].Name) == tagKey(current.Name) {
				pool[i] = tagDefinition{Name: name, Description: description, Emoji: emoji}
			}
		}
		result = tagDefinition{Name: name, Description: description, Emoji: emoji}
	case "delete":
		canonical := resolveTag(pool, redirects, op.Name)
		if canonical == nil {
			return map[string]any{"name": op.Name, "deleted": true}, nil
		}
		current, err := known(op.Name)
		if err != nil {
			return nil, err
		}
		used, err := tagUsage(tx, scope, current.Name, pool, redirects)
		if err != nil {
			return nil, err
		}
		if used > 0 {
			return nil, fmt.Errorf("tag is in use by %d thread(s); use merge", used)
		}
		redirects[tagKey(current.Name)] = nil
		next := []tagDefinition{}
		for _, tag := range pool {
			if tagKey(tag.Name) != tagKey(current.Name) {
				next = append(next, tag)
			}
		}
		pool = next
		result = map[string]any{"name": current.Name, "deleted": true}
	case "merge":
		if len(op.Names) == 0 || len(op.Names) > 100 {
			return nil, errors.New("invalid merge source count")
		}
		if op.Emoji == nil || *op.Emoji == "" {
			return nil, errors.New("tag merge requires emoji")
		}
		targetName, err := normalizeTag(op.Target, 32, false)
		if err != nil {
			return nil, err
		}
		canonical := resolveTag(pool, redirects, targetName)
		if canonical == nil {
			return nil, errors.New("merge target is retired")
		}
		targetName = *canonical
		if !hasTag(pool, targetName) {
			if err := rejectLabel(targetName); err != nil {
				return nil, err
			}
		}
		sources := []tagDefinition{}
		for _, name := range op.Names {
			tag, err := known(name)
			if err != nil {
				return nil, err
			}
			sources = append(sources, tag)
		}
		if !hasTag(pool, targetName) {
			// Sources are removed below, so a merge can free the slot that the
			// new target occupies. Validate the final pool instead.
			pool = append(pool, tagDefinition{Name: targetName, Description: targetName, Emoji: taglabel.Emoji(*op.Emoji)})
		}
		merged := []string{}
		for _, source := range sources {
			if tagKey(source.Name) == tagKey(targetName) {
				continue
			}
			redirects[tagKey(source.Name)] = &targetName
			merged = append(merged, tagKey(source.Name))
		}
		next := []tagDefinition{}
		for _, tag := range pool {
			if contains(merged, tagKey(tag.Name)) {
				continue
			}
			if tagKey(tag.Name) == tagKey(targetName) {
				tag.Emoji = taglabel.Emoji(*op.Emoji)
			}
			if tagKey(tag.Name) == tagKey(targetName) && op.Description != nil {
				tag.Description, err = normalizeTag(*op.Description, 120, true)
				if err != nil {
					return nil, err
				}
			}
			next = append(next, tag)
		}
		pool = next
		delete(redirects, tagKey(targetName))
		if len(pool) > maxScopeTags {
			return nil, fmt.Errorf("tag pool is full: %s", tagNames(pool))
		}
		result = map[string]any{"name": targetName, "merged": merged}
	case "assign", "assign-many":
		entries := op.Assignments
		if op.Kind == "assign" {
			if op.Thread == nil {
				return nil, errors.New("tag assignment requires a thread")
			}
			entries = []plugin.SemanticTagAssignment{{Thread: *op.Thread, Tags: op.Tags}}
		}
		if len(entries) == 0 || len(entries) > maxBatchAssignment {
			return nil, errors.New("invalid tag assignment count")
		}
		seen := map[model.ThreadRef]bool{}
		for _, entry := range entries {
			if seen[entry.Thread] {
				return nil, errors.New("duplicate thread in tag assignment batch")
			}
			seen[entry.Thread] = true
			if _, err := c.classifiable(tx, entry.Thread); err != nil {
				return nil, err
			}
			if len(entry.Tags) != 1 {
				return nil, errors.New("each thread must have exactly one tag")
			}
			name, err := normalizeTag(entry.Tags[0], 32, false)
			if err != nil {
				return nil, err
			}
			canonical := resolveTag(pool, redirects, name)
			if canonical == nil {
				return nil, errors.New("tag was retired")
			}
			if !hasTag(pool, *canonical) {
				return nil, fmt.Errorf("tag does not exist in this scope: %s; create it first", name)
			}
			assignments = append(assignments, plugin.SemanticTagAssignment{Thread: entry.Thread, Tags: []string{*canonical}})
		}
		if op.Kind == "assign" {
			result = map[string]any{"thread": assignments[0].Thread, "tags": assignments[0].Tags}
		} else {
			result = map[string]any{"assignments": assignments}
		}
	default:
		return nil, errors.New("unknown semantic tag operation")
	}
	if err := c.commit(tx, pool, redirects, assignments); err != nil {
		return nil, err
	}
	return result, nil
}

// commit applies the final pool and thread assignments atomically. It rebuilds
// the source snapshots for all scopes so Reports see canonical source tags.
func (c tagsWriteCapability) commit(tx *store.Tx, pool []tagDefinition, redirects map[string]*string, assignments []plugin.SemanticTagAssignment) error {
	if len(pool) > maxScopeTags {
		return fmt.Errorf("tag pool is full: %s", tagNames(pool))
	}
	scope := c.scopeID()
	assigned := map[model.ThreadRef][]string{}
	for _, entry := range assignments {
		assigned[entry.Thread] = append([]string{}, entry.Tags...)
	}
	threads, err := readThreads(tx.Snapshot())
	if err != nil {
		return err
	}
	sources := []plugin.ThreadTagSnapshot{}
	for _, thread := range threads {
		if thread.Moku {
			continue
		}
		before := thread
		if directorytag.Scope(thread.Cwd) == scope {
			tags := assigned[model.ThreadRef{ThreadID: thread.ID, TypeID: "agent"}]
			if tags == nil {
				tags = canonicalThreadTags(pool, redirects, thread.Tags)
			}
			emojis := tagEmojis(pool, tags)
			if !same(tags, thread.Tags) || !same(emojis, thread.TagEmojis) {
				thread.Tags = tags
				thread.TagEmojis = emojis
				thread.Revision++
				thread.UpdatedAt = max(thread.UpdatedAt, time.Now().UnixMilli())
				if err := tx.Put("thread:"+thread.ID, thread); err != nil {
					return err
				}
				if err := c.runtime.threadEvents(tx, &before, &thread); err != nil {
					return err
				}
			}
		}
		sources = append(sources, plugin.ThreadTagSnapshot{Thread: model.ThreadRef{ThreadID: thread.ID, TypeID: "agent"}, Tags: threadTags(thread)})
	}
	if err := tx.Put(tagPoolKey(scope), pool); err != nil {
		return err
	}
	if err := tx.Put(tagRedirectKey(scope), redirects); err != nil {
		return err
	}
	if applications, ok := c.runtime.config.Applications.(interface {
		ApplySemanticTags(*store.Tx, plugin.SemanticTagEffect) error
	}); ok {
		if err := applications.ApplySemanticTags(tx, plugin.SemanticTagEffect{SourceThreads: sources}); err != nil {
			return err
		}
	}
	return nil
}

func (c tagsWriteCapability) classifiable(tx *store.Tx, ref model.ThreadRef) (*model.ThreadRecord, error) {
	if ref.TypeID != "agent" {
		return nil, errors.New("only ordinary threads can be classified")
	}
	var thread model.ThreadRecord
	ok, err := tx.Get("thread:"+ref.ThreadID, &thread)
	if err != nil {
		return nil, err
	}
	if !ok || thread.Moku {
		return nil, errors.New("thread cannot be classified")
	}
	if directorytag.Scope(thread.Cwd) != c.scopeID() {
		return nil, errors.New("thread belongs to a different tag scope")
	}
	return &thread, nil
}

func tagScope(scope string) string {
	if scope == "" {
		return directorytag.InboxScope
	}
	return scope
}
func tagPoolKey(scope string) string     { return "semantic-tags:" + tagScope(scope) }
func tagRedirectKey(scope string) string { return "tag-redirects:" + tagScope(scope) }
func tagInventoryKey(scope string) string {
	return "tag-inventory-initialized:" + tagScope(scope)
}
func readTags(snapshot store.Snapshot, scope string) ([]tagDefinition, map[string]*string, error) {
	pool := []tagDefinition{}
	redirects := map[string]*string{}
	if _, err := snapshot.Get(tagPoolKey(scope), &pool); err != nil {
		return nil, nil, err
	}
	if _, err := snapshot.Get(tagRedirectKey(scope), &redirects); err != nil {
		return nil, nil, err
	}
	for _, tag := range pool {
		if _, err := normalizeTag(tag.Name, 32, false); err != nil {
			return nil, nil, err
		}
		if !taglabel.ValidEmoji(tag.Emoji) {
			return nil, nil, fmt.Errorf("invalid stored emoji for tag %q", tag.Name)
		}
	}
	return pool, redirects, nil
}
func tagKey(name string) string {
	return strings.Join(strings.Fields(cases.Lower(language.Und).String(norm.NFKC.String(name))), " ")
}
func resolveTag(pool []tagDefinition, redirects map[string]*string, name string) *string {
	visited := map[string]bool{}
	for {
		key := tagKey(name)
		if visited[key] {
			return nil
		}
		visited[key] = true
		if target, ok := redirects[key]; ok {
			if target == nil {
				return nil
			}
			name = *target
			continue
		}
		for _, tag := range pool {
			if tagKey(tag.Name) == key {
				value := tag.Name
				return &value
			}
		}
		value := name
		return &value
	}
}
func findTag(pool []tagDefinition, name string) (tagDefinition, bool) {
	for _, tag := range pool {
		if tagKey(tag.Name) == tagKey(name) {
			return tag, true
		}
	}
	return tagDefinition{}, false
}
func hasTag(pool []tagDefinition, name string) bool {
	_, ok := findTag(pool, name)
	return ok
}
func tagNames(pool []tagDefinition) string {
	names := make([]string, 0, len(pool))
	for _, tag := range pool {
		names = append(names, tag.Name)
	}
	return strings.Join(names, ", ")
}
func canonicalThreadTags(pool []tagDefinition, redirects map[string]*string, names []string) []string {
	result := []string{}
	for _, name := range names {
		canonical := resolveTag(pool, redirects, name)
		if canonical == nil || !hasTag(pool, *canonical) {
			continue
		}
		if !contains(result, *canonical) {
			result = append(result, *canonical)
		}
	}
	if len(result) > 1 {
		result = result[:1]
	}
	return result
}
func tagUsage(tx *store.Tx, scope, name string, pool []tagDefinition, redirects map[string]*string) (int, error) {
	threads, err := readThreads(tx.Snapshot())
	if err != nil {
		return 0, err
	}
	canonical := resolveTag(pool, redirects, name)
	if canonical == nil {
		return 0, nil
	}
	used := 0
	for _, thread := range threads {
		if thread.Moku || directorytag.Scope(thread.Cwd) != scope {
			continue
		}
		for _, tag := range thread.Tags {
			resolved := resolveTag(pool, redirects, tag)
			if resolved != nil && tagKey(*resolved) == tagKey(*canonical) {
				used++
				break
			}
		}
	}
	return used, nil
}
func normalizeTag(value string, limit int, empty bool) (string, error) {
	if strings.ContainsRune(value, 0) {
		return "", errors.New("tag contains NUL")
	}
	if !empty && taglabel.HasEmojiPrefix(value) {
		return "", errors.New("tag name must not have an emoji prefix; supply emoji separately")
	}
	value = strings.Join(strings.Fields(value), " ")
	if (!empty && value == "") || len(utf16.Encode([]rune(value))) > limit {
		return "", errors.New("tag text outside permitted length")
	}
	return value, nil
}

// Assignments store text names; this denormalized projection lets every catalog
// and archived-thread envelope carry decoration without changing identity.
func tagEmojis(pool []tagDefinition, names []string) map[string]string {
	result := map[string]string{}
	for _, name := range names {
		if tag, ok := findTag(pool, name); ok {
			result[name] = tag.Emoji
		}
	}
	return result
}
