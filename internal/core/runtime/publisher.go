package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
	"sort"
)

func (r *Runtime) project() (model.AppState, error) {
	snap := r.config.Store.Snapshot()
	threads, err := r.projectThreads(snap)
	if err != nil {
		return model.AppState{}, err
	}
	state := model.AppState{Revision: int64(snap.Revision()), DefaultCwd: r.config.DefaultCwd, Threads: threads, Executions: []model.MokuExecution{}, AgentRuns: []model.AgentRun{}, ApplicationThreads: []model.ApplicationThread{}, TagRedirects: map[string]*string{}, Plugins: append([]model.RuntimePlugin{}, r.config.Plugins...)}
	state.SearchRevision = threadsearch.Revision(snap)
	if _, err = snap.Get("settings", &state.Settings); err != nil {
		return state, err
	}
	if _, err = snap.Get("settings-revision", &state.SettingsRevision); err != nil {
		return state, err
	}
	// Publish scoped redirects with a scope-qualified key so the native Overview
	// can keep a renamed or merged selection without a global name collision.
	for _, key := range snap.Keys("tag-redirects:") {
		var redirects map[string]*string
		if ok, e := snap.Get(key, &redirects); e != nil {
			return state, e
		} else if !ok {
			continue
		}
		scope := key[len("tag-redirects:"):]
		for name, target := range redirects {
			state.TagRedirects[scope+"\x00"+name] = target
		}
	}
	for i := range state.Threads {
		t := &state.Threads[i]
		if t.Moku {
			if e := t.Observation.LatestExecution; e != nil && !e.Terminal() {
				state.Executions = append(state.Executions, model.MokuExecution{ThreadID: t.ID, ExecutionID: e.ExecutionID, Status: e.Status, StartedAt: e.StartedAt})
			}
		}
	}
	r.mu.Lock()
	apps := r.config.Applications
	r.mu.Unlock()
	if apps != nil {
		// Project applications from the captured snapshot to keep revisions coherent.
		if captured, ok := apps.(interface {
			CatalogSnapshot(context.Context, store.Snapshot) ([]model.ApplicationThread, error)
		}); ok {
			state.ApplicationThreads, err = captured.CatalogSnapshot(r.ctx, snap)
		} else {
			state.ApplicationThreads, err = apps.Catalog(r.ctx)
		}
		if err != nil {
			return state, err
		}
		if state.ApplicationThreads == nil {
			state.ApplicationThreads = []model.ApplicationThread{}
		}

	}
	for _, key := range snap.Keys("private-session:") {
		var session plugin.PrivateSessionSnapshot
		if ok, e := snap.Get(key, &session); e != nil {
			return state, e
		} else if ok {
			if execution := session.Record.Observation.LatestExecution; execution != nil && execution.Status == "running" {
				state.AgentRuns = append(state.AgentRuns, model.AgentRun{AgentID: session.Ref.Owner.AgentID, Scope: session.Ref.Owner.Binding.Scope, ScopeLabel: session.Ref.Owner.ScopeLabel, ExecutionID: execution.ExecutionID, StartedAt: execution.StartedAt})
			}
		}
	}
	sort.Slice(state.AgentRuns, func(i, j int) bool { return state.AgentRuns[i].AgentID < state.AgentRuns[j].AgentID })
	return state, nil
}

// Publish serializes both state revisions and delivery. A subscriber sees a
// continuous baseRevision chain even when several adapters commit concurrently.
func (r *Runtime) Publish() {
	r.projectionMu.Lock()
	next, err := r.project()
	if err != nil {
		r.projectionMu.Unlock()
		r.log("state.publish", err)
		return
	}
	r.publishMu.Lock()
	previous := r.baseline
	r.publishMu.Unlock()
	next.Revision = previous.Revision + 1
	mutation := stateMutation(previous, next)
	r.publishMu.Lock()
	if len(r.pendingActivities) > 0 {
		mutation.Activities = append([]model.RuntimeActivity{}, r.pendingActivities...)
	}
	if emptyMutation(mutation) {
		r.publishMu.Unlock()
		r.projectionMu.Unlock()
		return
	}
	raw, err := json.Marshal(mutation)
	if err != nil {
		r.publishMu.Unlock()
		r.projectionMu.Unlock()
		r.log("state.encode", err)
		return
	}
	r.baseline = next
	r.pendingActivities = nil
	r.pendingPublications = append(r.pendingPublications, raw)
	deliver := !r.delivering
	r.delivering = true
	r.publishMu.Unlock()
	r.projectionMu.Unlock()
	if deliver {
		r.deliverPublications()
	}
}

func (r *Runtime) deliverPublications() {
	for {
		r.publishMu.Lock()
		if len(r.pendingPublications) == 0 {
			r.delivering = false
			r.publishMu.Unlock()
			return
		}
		raw := r.pendingPublications[0]
		r.pendingPublications = r.pendingPublications[1:]
		r.publishMu.Unlock()
		r.mu.Lock()
		listeners := make([]func(json.RawMessage), 0, len(r.listeners))
		for _, listener := range r.listeners {
			listeners = append(listeners, listener)
		}
		r.mu.Unlock()
		for _, listener := range listeners {
			callListener(listener, bytes.Clone(raw), r.log)
		}
	}
}
func callListener(listener func(json.RawMessage), raw json.RawMessage, log func(string, error)) {
	defer func() {
		if reason := recover(); reason != nil {
			log("state.subscriber", fmt.Errorf("subscriber panic: %v", reason))
		}
	}()
	listener(raw)
}
func (r *Runtime) Snapshot() (model.AppState, error) {
	r.projectionMu.Lock()
	defer r.projectionMu.Unlock()
	state, err := r.project()
	r.publishMu.Lock()
	state.Revision = r.baseline.Revision
	r.publishMu.Unlock()
	if err != nil {
		return model.AppState{}, err
	}
	// Cached projections must never escape as mutable shared values.
	raw, err := json.Marshal(state)
	if err != nil {
		return model.AppState{}, err
	}
	var detached model.AppState
	err = json.Unmarshal(raw, &detached)
	return detached, err
}
func (r *Runtime) SubscribeMutations(listener func(json.RawMessage)) func() {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return func() {}
	}
	r.nextListener++
	id := r.nextListener
	r.listeners[id] = listener
	r.mu.Unlock()
	return func() { r.mu.Lock(); delete(r.listeners, id); r.mu.Unlock() }
}
func (r *Runtime) publishActivity(threadID, harnessID string, activity model.HarnessActivity) {
	if !r.config.Store.Snapshot().Has("thread:" + threadID) {
		return
	}
	r.publishMu.Lock()
	if r.ctx.Err() != nil {
		r.publishMu.Unlock()
		return
	}
	event := model.RuntimeActivity{ThreadID: threadID, HarnessID: harnessID, Activity: activity}
	replaced := false
	if count := len(r.pendingActivities); count > 0 {
		last := r.pendingActivities[count-1]
		if last.ThreadID == threadID && last.HarnessID == harnessID && last.Activity.ExecutionID == activity.ExecutionID && last.Activity.Sequence == activity.Sequence {
			r.pendingActivities[count-1] = event
			replaced = true
		}
	}
	if !replaced {
		if len(r.pendingActivities) >= 1024 {
			r.pendingActivities = r.pendingActivities[1:]
		}
		r.pendingActivities = append(r.pendingActivities, event)
	}
	r.publishMu.Unlock()
	select {
	case r.publisherWake <- struct{}{}:
	default:
	}
}
func stateMutation(old, next model.AppState) model.StateMutation {
	m := model.StateMutation{Type: "state-patched", BaseRevision: old.Revision, Revision: next.Revision}
	if old.SearchRevision != next.SearchRevision {
		m.SearchRevision = &next.SearchRevision
	}
	m.Threads = collectionPatch(old.Threads, next.Threads, func(t model.ThreadRecord) string { return t.ID },
		func(t model.ThreadRecord) int64 { return t.Revision })
	m.ApplicationThreads = collectionPatch(old.ApplicationThreads, next.ApplicationThreads, func(t model.ApplicationThread) string { return t.ID }, nil)
	if !same(old.Settings, next.Settings) {
		m.Settings = &next.Settings
	}
	if old.SettingsRevision != next.SettingsRevision {
		m.SettingsRevision = &next.SettingsRevision
	}
	if old.DefaultCwd != next.DefaultCwd {
		m.DefaultCwd = &next.DefaultCwd
	}
	if !same(old.Executions, next.Executions) {
		m.Executions = &next.Executions
	}
	if !same(old.AgentRuns, next.AgentRuns) {
		m.AgentRuns = &next.AgentRuns
	}
	if !same(old.TagRedirects, next.TagRedirects) {
		m.TagRedirects = &next.TagRedirects
	}
	if !same(old.Plugins, next.Plugins) {
		m.Plugins = &next.Plugins
	}
	return m
}

// revision, when supplied, orders record incarnations. A record identity whose
// revision does not advance was recreated in place after deletion.
// Clients discard upserts they cannot order against their cached revision, so
// publish a removal in the same patch and let the new incarnation install from
// empty. Nil revision opts a collection out of this ordering.
func collectionPatch[T any](old, next []T, id func(T) string, revision func(T) int64) *model.CollectionPatch[T] {
	oldByID := map[string]T{}
	newByID := map[string]T{}
	oldOrder := []string{}
	newOrder := []string{}
	p := &model.CollectionPatch[T]{Upserts: []T{}, RemovedIDs: []string{}}
	for _, v := range old {
		oldByID[id(v)] = v
		oldOrder = append(oldOrder, id(v))
	}
	for _, v := range next {
		key := id(v)
		newByID[key] = v
		newOrder = append(newOrder, key)
		before, ok := oldByID[key]
		if !ok || !same(before, v) {
			p.Upserts = append(p.Upserts, v)
			if ok && revision != nil && revision(v) <= revision(before) {
				p.RemovedIDs = append(p.RemovedIDs, key)
			}
		}
	}
	for _, v := range old {
		if _, ok := newByID[id(v)]; !ok {
			p.RemovedIDs = append(p.RemovedIDs, id(v))
		}
	}
	if !same(oldOrder, newOrder) {
		p.Order = &newOrder
	}
	if len(p.Upserts) == 0 && len(p.RemovedIDs) == 0 && p.Order == nil {
		return nil
	}
	return p
}
func emptyMutation(m model.StateMutation) bool {
	return m.Threads == nil && m.ApplicationThreads == nil && m.DefaultCwd == nil && m.Executions == nil && m.AgentRuns == nil && m.TagRedirects == nil && m.Settings == nil && m.SettingsRevision == nil && m.SearchRevision == nil && m.Plugins == nil && len(m.Activities) == 0
}
func same(a, b any) bool {
	left, e := json.Marshal(a)
	if e != nil {
		return false
	}
	right, e := json.Marshal(b)
	return e == nil && bytes.Equal(left, right)
}
func auditPreview(items []json.RawMessage) []json.RawMessage {
	result := []json.RawMessage{}
	latest := ""
	for _, raw := range items {
		var item map[string]any
		if json.Unmarshal(raw, &item) == nil {
			if id, ok := item["executionId"].(string); ok {
				latest = id
			}
		}
	}
	for _, raw := range items {
		var item map[string]any
		if json.Unmarshal(raw, &item) != nil {
			continue
		}
		if id, _ := item["executionId"].(string); id != latest {
			continue
		}
		delete(item, "reasoning")
		if value, ok := item["content"].(string); ok && len([]rune(value)) > 600 {
			item["content"] = string([]rune(value)[:600])
		}
		for _, key := range []string{"arguments", "result"} {
			if source, ok := item[key].(map[string]any); ok {
				preview := map[string]any{}
				// The catalog is the Dock's audit source. Keep explicit outcome
				// facts: dropping ok turns delivered create_thread calls into
				// false failures, and dropping error hides genuine failure reasons.
				if key == "result" {
					if ok, present := source["ok"].(bool); present {
						preview["ok"] = ok
					}
				}
				for _, name := range []string{"threadId", "harnessId", "title", "prompt", "text", "error"} {
					if value, ok := source[name].(string); ok {
						limit := 256
						if name == "prompt" {
							limit = 600
						}
						if name == "text" {
							limit = 4000
						}
						if name == "error" {
							limit = 8192
						}
						if len([]rune(value)) > limit {
							value = string([]rune(value)[:limit])
						}
						preview[name] = value
					}
				}
				item[key] = preview
			}
		}
		encoded, err := json.Marshal(item)
		if err == nil {
			result = append(result, encoded)
		}
	}
	return result
}
