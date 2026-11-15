package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/platform/workpool"
)

// Execution scopes are produced by the owning Harness and then receive only the
// runtime's exact naming evidence. Titles never widen the catalog overview.
type threadContentEnvelope struct {
	Version         int               `json:"version"`
	State           json.RawMessage   `json:"state"`
	ExecutionTitles map[string]string `json:"executionTitles,omitempty"`
}

// Directory adapters must return a page whose Offset/Limit reflect the requested
// scope after normalization (negative offset -> 0, zero limit -> default,
// offset beyond total -> total, oversized limit -> maximum). The Runtime rejects
// a page that silently chooses a different page identity.
func projectExecutionPage(value json.RawMessage, scope transport.ContentScope, titles map[string]string) (json.RawMessage, error) {
	var page model.ExecutionDirectoryPage
	if err := model.Unmarshal(value, &page); err != nil {
		return nil, fmt.Errorf("invalid execution directory projection: %w", err)
	}
	if page.Version != 1 || page.Executions == nil || page.Total < 0 {
		return nil, errors.New("invalid execution directory projection")
	}
	expectedOffset := max(0, scope.Offset)
	if expectedOffset > page.Total {
		expectedOffset = page.Total
	}
	expectedLimit := scope.Limit
	if expectedLimit <= 0 {
		expectedLimit = model.DefaultExecutionDirectoryLimit
	}
	if expectedLimit > model.MaximumExecutionDirectoryLimit {
		expectedLimit = model.MaximumExecutionDirectoryLimit
	}
	if page.Offset != expectedOffset || page.Limit != expectedLimit {
		return nil, fmt.Errorf("execution directory page scope mismatch: got offset=%d limit=%d want offset=%d limit=%d", page.Offset, page.Limit, expectedOffset, expectedLimit)
	}
	for index := range page.Executions {
		page.Executions[index].Title = titles[page.Executions[index].ExecutionID]
	}
	return json.Marshal(page)
}

func projectExecutionPreview(value json.RawMessage, executionID string, titles map[string]string) (*model.ExecutionDigest, error) {
	var digest model.ExecutionDigest
	if err := model.Unmarshal(value, &digest); err != nil {
		return nil, fmt.Errorf("invalid execution preview projection: %w", err)
	}
	if digest.ExecutionID == "" {
		return nil, nil
	}
	if digest.ExecutionID != executionID {
		return nil, errors.New("execution preview identity changed")
	}
	digest.Title = titles[executionID]
	return &digest, nil
}

func wrapThreadContent(state json.RawMessage, titles map[string]string) (json.RawMessage, error) {
	if titles == nil {
		titles = map[string]string{}
	}
	return json.Marshal(threadContentEnvelope{Version: 1, State: state, ExecutionTitles: titles})
}

func (r *Runtime) projectThreadContent(ctx context.Context, snapshot store.Snapshot, entry cachedThread,
	harness plugin.Harness, scope transport.ContentScope, known *int64) (*transport.ContentSnapshot, error) {
	thread := entry.record
	if known != nil && *known == thread.Revision && threadScopeHasRuntimeEnvelope(scope.Kind) {
		return nil, nil
	}
	rendererScope := rendererContentScope(scope)
	adapter := harness.SessionState()
	var value json.RawMessage
	revision := thread.Revision
	if reader, ok := adapter.(plugin.ReaderProjectionAdapter); ok {
		// Runtime-owned envelopes (thread/directory/preview) must not hand the
		// final revision back as the adapter's content Known: adapter revisions
		// may be 63-bit content hashes, while a title-only change advances only
		// Thread revision. Project again and derive the final revision below.
		adapterKnown := known
		if threadScopeHasRuntimeEnvelope(scope.Kind) {
			adapterKnown = nil
		}
		var result *plugin.ReaderSnapshot
		err := r.computeTasks(ctx, []workpool.Task{{Bytes: snapshot.RecordBytes("thread:" + thread.ID), Run: func(taskCtx context.Context) error {
			var readErr error
			result, readErr = reader.ProjectReader(taskCtx, plugin.ReaderRequest{ThreadID: thread.ID, ContentID: entry.contentID,
				State: thread.SessionState, Scope: rendererScope, Known: adapterKnown, Generation: thread.Revision})
			return readErr
		}}})
		if err != nil {
			return nil, err
		}
		if result == nil {
			return nil, nil
		}
		value = result.Value
		if !threadScopeHasRuntimeEnvelope(scope.Kind) {
			revision = result.Revision
		}
	} else {
		if known != nil && *known == thread.Revision {
			return nil, nil
		}
		err := r.computeTasks(ctx, []workpool.Task{{Bytes: snapshot.RecordBytes("thread:" + thread.ID), Run: func(ctx context.Context) error {
			var err error
			value, err = adapter.ProjectRenderer(bytes.Clone(thread.SessionState), rendererScope)
			return err
		}}})
		if err != nil {
			return nil, err
		}
	}
	final, err := applyThreadContentEnvelope(value, thread, scope)
	if err != nil {
		return nil, err
	}
	return &transport.ContentSnapshot{Revision: revision, Value: final}, nil
}

func threadScopeHasRuntimeEnvelope(kind string) bool {
	return kind == "thread" || kind == "directory" || kind == "preview"
}

func applyThreadContentEnvelope(value json.RawMessage, thread model.ThreadRecord, scope transport.ContentScope) (json.RawMessage, error) {
	switch scope.Kind {
	case "thread":
		return wrapThreadContent(value, thread.ExecutionTitles)
	case "directory":
		return projectExecutionPage(value, scope, thread.ExecutionTitles)
	case "preview":
		digest, err := projectExecutionPreview(value, scope.Key, thread.ExecutionTitles)
		if err != nil {
			return nil, err
		}
		if digest == nil {
			return nil, fmt.Errorf("unknown execution: %s", scope.Key)
		}
		digest.ThreadID = thread.ID
		return json.Marshal(digest)
	default:
		return value, nil
	}
}

func (r *Runtime) projectExecutionPreviewValue(ctx context.Context, thread model.ThreadRecord, state json.RawMessage,
	contentID string, harness plugin.Harness, executionID string) (json.RawMessage, error) {
	scope := rendererContentScope(transport.ContentScope{Kind: "preview", Key: executionID})
	adapter := harness.SessionState()
	if reader, ok := adapter.(plugin.ReaderProjectionAdapter); ok {
		result, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: thread.ID, ContentID: contentID,
			State: state, Scope: scope, Generation: thread.Revision})
		if err != nil {
			return nil, err
		}
		if result == nil {
			return json.RawMessage(`{}`), nil
		}
		return result.Value, nil
	}
	return adapter.ProjectRenderer(state, scope)
}

// ExecutionPreviews resolves exact references in one bounded read. Each result
// carries only the cited execution's title, timing and Harness-selected excerpt;
// no turn/execution content lease or complete body is created.
func (r *Runtime) ExecutionPreviews(ctx context.Context, references []model.ExecutionRef) ([]model.ExecutionDigest, error) {
	snapshot := r.config.Store.Snapshot()
	type previewThread struct {
		entry cachedThread
		state json.RawMessage
	}
	type previewTarget struct {
		thread  model.ThreadRecord
		state   json.RawMessage
		content string
		harness plugin.Harness
		index   int
	}
	targets := make([]previewTarget, 0, len(references))
	threads := map[string]previewThread{}
	unique := map[string]bool{}
	for index, reference := range references {
		if reference.Thread.TypeID != "agent" || identifier(reference.Thread.ThreadID) != nil || identifier(reference.ExecutionID) != nil {
			continue
		}
		key := reference.Thread.ThreadID + "\x00" + reference.ExecutionID
		if unique[key] {
			continue
		}
		unique[key] = true
		thread, exists := threads[reference.Thread.ThreadID]
		if !exists {
			var entry cachedThread
			var err error
			entry, err = r.cachedThread(ctx, snapshot, reference.Thread.ThreadID)
			if err != nil {
				continue
			}
			if harness := r.config.Harnesses[entry.record.HarnessID]; harness != nil {
				state := entry.record.SessionState
				if _, shared := harness.SessionState().(plugin.ReaderProjectionAdapter); !shared {
					// One detached copy per Thread, never one per reference.
					state = bytes.Clone(state)
				}
				thread = previewThread{entry: entry, state: state}
				threads[reference.Thread.ThreadID] = thread
			}
		}
		if thread.entry.record.Moku || thread.entry.record.MokuHistory {
			continue
		}
		harness := r.config.Harnesses[thread.entry.record.HarnessID]
		if harness == nil {
			continue
		}
		targets = append(targets, previewTarget{thread: thread.entry.record, state: thread.state,
			content: thread.entry.contentID, harness: harness, index: index})
	}
	results := make([]*model.ExecutionDigest, len(references))
	tasks := make([]workpool.Task, 0, len(threads))
	groups := map[string][]previewTarget{}
	order := make([]string, 0, len(threads))
	for _, target := range targets {
		id := target.thread.ID
		if _, exists := groups[id]; !exists {
			order = append(order, id)
		}
		groups[id] = append(groups[id], target)
	}
	for _, id := range order {
		group := groups[id]
		tasks = append(tasks, workpool.Task{Bytes: snapshot.RecordBytes("thread:" + id), Run: func(ctx context.Context) error {
			for _, target := range group {
				value, err := r.projectExecutionPreviewValue(ctx, target.thread, target.state, target.content,
					target.harness, references[target.index].ExecutionID)
				if err != nil {
					return err
				}
				digest, err := projectExecutionPreview(value, references[target.index].ExecutionID, target.thread.ExecutionTitles)
				if err != nil {
					return err
				}
				if digest != nil {
					digest.ThreadID = target.thread.ID
				}
				results[target.index] = digest
			}
			return nil
		}})
	}
	if err := r.computeTasks(ctx, tasks); err != nil {
		return nil, err
	}
	previews := make([]model.ExecutionDigest, 0, len(targets))
	for _, digest := range results {
		if digest != nil {
			previews = append(previews, *digest)
		}
	}
	return previews, nil
}
