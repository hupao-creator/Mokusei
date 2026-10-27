package runtime

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

type capabilityAccess struct {
	err    error
	values map[string]any
	phase  string
}

func (c capabilityAccess) Require(key plugin.CapabilityKey) (any, error) {
	if c.err != nil {
		return nil, c.err
	}
	if key.APIVersion != 1 || key.Phase != c.phase {
		return nil, fmt.Errorf("incompatible capability: %s", key.ID)
	}
	value, ok := c.values[key.ID]
	if !ok || value == nil {
		return nil, fmt.Errorf("capability unavailable: %s", key.ID)
	}
	return value, nil
}
func (r *Runtime) RuntimeCapabilities(pluginID string) plugin.CapabilityAccess {
	values := map[string]any{plugin.OrdinaryTaskReadCapabilityKey.ID: taskReadCapability{runtime: r, binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}, plugin.SemanticTagsReadCapabilityKey.ID: tagsReadCapability{r, directorytag.InboxScope}, plugin.SemanticTagsWriteCapabilityKey.ID: tagsWriteCapability{r, pluginID, directorytag.InboxScope}, plugin.ClassificationReadCapabilityKey.ID: classificationCapability{r}, plugin.LifecycleCapabilityKey.ID: scopedLifecycle{base: r.lifecycle, owner: plugin.BackgroundAgentRef{PluginID: pluginID, AgentID: pluginID, Binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}}}
	for id, value := range r.config.ExtraCapabilities {
		values[id] = value
	}
	if r.config.ProcessFactory != nil {
		values[plugin.ApplicationProcessCapabilityKey.ID] = r.config.ProcessFactory(filepath.Join(r.config.DefaultCwd, "plugins", pluginID))
	}
	return capabilityAccess{values: values, phase: "runtime"}
}
func (r *Runtime) SnapshotCapabilities(snapshot store.Snapshot, issue func(string, int64) (plugin.MutationScope, error)) plugin.CapabilityAccess {
	return capabilityAccess{phase: "snapshot", values: map[string]any{plugin.OrdinaryTaskSnapshotCapabilityKey.ID: taskSnapshotCapability{runtime: r, snapshot: snapshot, issue: issue}, plugin.SemanticTagsSnapshotCapabilityKey.ID: tagsSnapshotCapability{r, snapshot, issue}}}
}

type taskReadCapability struct {
	runtime *Runtime
	binding plugin.ScopeBinding
}

func (c taskReadCapability) CaptureList(ctx context.Context, includeArchived bool) ([]plugin.OrdinaryTaskSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	threads, err := c.runtime.Threads()
	if err != nil {
		return nil, err
	}
	result := []plugin.OrdinaryTaskSnapshot{}
	for _, t := range threads {
		if t.Moku || (!includeArchived && archived(&t)) || !c.binding.Allows(directorytag.Scope(t.Cwd)) {
			continue
		}
		result = append(result, taskSnapshot(t))
	}
	return result, nil
}
func (c taskReadCapability) Get(ctx context.Context, ref model.ThreadRef) (*plugin.OrdinaryTaskSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return taskSnapshotCapability{runtime: c.runtime, snapshot: c.runtime.config.Store.Snapshot(), binding: &c.binding}.Get(ref)
}
func (c taskReadCapability) ReadThread(ctx context.Context, ref model.ThreadRef, question string) (string, error) {
	task, err := c.Get(ctx, ref)
	if err != nil {
		return "", err
	}
	if task == nil {
		return "", errors.New("unknown ordinary task")
	}
	return c.runtime.ReadThread(ctx, ref.ThreadID, question)
}
func (c taskReadCapability) CaptureHistory(ctx context.Context, ref model.ThreadRef) (plugin.TaskHistorySnapshot, error) {
	task, err := c.Get(ctx, ref)
	if err != nil {
		return plugin.TaskHistorySnapshot{}, err
	}
	if task == nil {
		return plugin.TaskHistorySnapshot{}, errors.New("unknown ordinary task")
	}
	t, err := c.runtime.Thread(ref.ThreadID)
	if err != nil {
		return plugin.TaskHistorySnapshot{}, err
	}
	h := c.runtime.config.Harnesses[t.HarnessID]
	if h == nil {
		return plugin.TaskHistorySnapshot{}, errors.New("unknown thread harness")
	}
	content, err := h.SessionState().ReadContext(t.SessionState)
	if err != nil {
		return plugin.TaskHistorySnapshot{}, err
	}
	return plugin.TaskHistorySnapshot{Task: *task, Content: string(content)}, nil
}
func (c taskReadCapability) ResolveExecution(ctx context.Context, ref model.ExecutionRef) (*model.PublicExecution, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return taskSnapshotCapability{runtime: c.runtime, snapshot: c.runtime.config.Store.Snapshot(), binding: &c.binding}.ResolveExecution(ref)
}

type taskSnapshotCapability struct {
	binding  *plugin.ScopeBinding
	runtime  *Runtime
	snapshot store.Snapshot
	issue    func(string, int64) (plugin.MutationScope, error)
}

func (c taskSnapshotCapability) record(ref model.ThreadRef) (*model.ThreadRecord, error) {
	if err := identifier(ref.ThreadID); err != nil {
		return nil, err
	}
	if ref.TypeID != "agent" {
		return nil, errors.New("only ordinary task references are supported")
	}
	var t model.ThreadRecord
	ok, err := c.snapshot.Get("thread:"+ref.ThreadID, &t)
	if err != nil {
		return nil, err
	}
	if c.issue != nil {
		revision := int64(0)
		if ok {
			revision = t.Revision
		}
		if _, err := c.issue("thread:"+ref.ThreadID, revision); err != nil {
			return nil, err
		}
	}
	if !ok || t.Moku || (c.binding != nil && !c.binding.Allows(directorytag.Scope(t.Cwd))) {
		return nil, nil
	}
	return &t, nil
}
func (c taskSnapshotCapability) Scope(ref model.ThreadRef) (plugin.MutationScope, error) {
	t, err := c.record(ref)
	if err != nil {
		return plugin.MutationScope{}, err
	}
	if c.issue == nil {
		return plugin.MutationScope{}, errors.New("snapshot cannot issue mutation scopes")
	}
	if t == nil {
		return c.issue("thread:"+ref.ThreadID, 0)
	}
	return c.issue("thread:"+t.ID, t.Revision)
}
func (c taskSnapshotCapability) Get(ref model.ThreadRef) (*plugin.OrdinaryTaskSnapshot, error) {
	t, err := c.record(ref)
	if err != nil || t == nil {
		return nil, err
	}
	value := taskSnapshot(*t)
	return &value, nil
}
func (c taskSnapshotCapability) ResolveExecution(ref model.ExecutionRef) (*model.PublicExecution, error) {
	t, err := c.record(ref.Thread)
	if err != nil || t == nil {
		return nil, err
	}
	h := c.runtime.config.Harnesses[t.HarnessID]
	if h == nil {
		return nil, errors.New("thread harness is unavailable")
	}
	return h.SessionState().ResolveExecution(t.SessionState, ref.ExecutionID)
}
func taskSnapshot(t model.ThreadRecord) plugin.OrdinaryTaskSnapshot {
	return plugin.OrdinaryTaskSnapshot{Scope: directorytag.Scope(t.Cwd), Ref: model.ThreadRef{ThreadID: t.ID, TypeID: "agent"}, Title: t.Title, HarnessID: t.HarnessID, Cwd: t.Cwd, ExecutionCwd: effectiveCwd(t), Archived: archived(&t), Tags: threadTags(t), Observation: t.Observation}
}
func threadTags(t model.ThreadRecord) model.TagProjection {
	semantic := append([]string{}, t.Tags...)
	directory := []string{}
	if tag := directorytag.Name(t.Cwd); tag != "" {
		directory = append(directory, tag)
	}
	tags := append(append([]string{}, semantic...), directory...)
	return model.TagProjection{Tags: tags, SemanticTags: semantic, DirectoryTags: directory, TagEmojis: t.TagEmojis}
}

type classificationCapability struct{ runtime *Runtime }

func (c classificationCapability) CaptureList(ctx context.Context, includeArchived bool) ([]plugin.ClassificationThreadSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if host, ok := c.runtime.config.Applications.(interface {
		ClassificationList(store.Snapshot, bool) ([]plugin.ClassificationThreadSnapshot, error)
	}); ok {
		return host.ClassificationList(c.runtime.config.Store.Snapshot(), includeArchived)
	}
	return []plugin.ClassificationThreadSnapshot{}, nil
}
func (c classificationCapability) Get(ctx context.Context, ref model.ThreadRef) (*plugin.ClassificationThreadSnapshot, error) {
	all, err := c.CaptureList(ctx, true)
	if err != nil {
		return nil, err
	}
	for _, item := range all {
		if item.Ref == ref {
			return &item, nil
		}
	}
	return nil, nil
}
func (c classificationCapability) CaptureEvidence(ctx context.Context, ref model.ThreadRef) (plugin.ClassificationEvidenceSnapshot, error) {
	thread, err := c.Get(ctx, ref)
	if err != nil {
		return plugin.ClassificationEvidenceSnapshot{}, err
	}
	if thread == nil {
		return plugin.ClassificationEvidenceSnapshot{}, errors.New("unknown classification thread")
	}
	if ref.TypeID == "agent" {
		history, err := taskReadCapability{runtime: c.runtime, binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}.CaptureHistory(ctx, ref)
		return plugin.ClassificationEvidenceSnapshot{Thread: *thread, Content: history.Content}, err
	}
	if contributor, ok := c.runtime.config.Applications.(interface {
		ClassificationEvidence(store.Snapshot, model.ThreadRef) (plugin.ClassificationEvidenceSnapshot, error)
	}); ok {
		evidence, err := contributor.ClassificationEvidence(c.runtime.config.Store.Snapshot(), ref)
		thread.EvidenceRevision = evidence.Thread.EvidenceRevision
		return plugin.ClassificationEvidenceSnapshot{Thread: *thread, Content: evidence.Content}, err
	}
	return plugin.ClassificationEvidenceSnapshot{}, errors.New("application does not provide classification evidence")
}
