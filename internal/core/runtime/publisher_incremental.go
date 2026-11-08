package runtime

import (
	"context"
	"encoding/json"
	"slices"
	"sort"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

func (r *Runtime) initializePublication() error {
	r.publishedThreads = make(map[string]model.ThreadRecord, len(r.baseline.Threads))
	r.publishedThreadOrder = make(map[string]int, len(r.baseline.Threads))
	for i, thread := range r.baseline.Threads {
		r.publishedThreads[thread.ID] = thread
		r.publishedThreadOrder[thread.ID] = i
	}
	r.publishedApplications = make(map[string]model.ApplicationThread, len(r.baseline.ApplicationThreads))
	for _, entry := range r.baseline.ApplicationThreads {
		r.publishedApplications[entry.ID] = entry
		r.publishedApplicationOrder = append(r.publishedApplicationOrder, entry.ID)
	}
	// Whole collections are materialized only for explicit snapshots. Publication
	// retains private identity maps, so a point update never copies their arrays.
	r.baseline.Threads = nil
	r.baseline.ApplicationThreads = nil
	r.publishedAgentRuns = map[string]model.AgentRun{}
	for _, key := range r.publicationSnapshot.Keys("private-session:") {
		run, err := agentRun(r.publicationSnapshot, key)
		if err != nil {
			return err
		}
		if run != nil {
			r.publishedAgentRuns[key] = *run
		}
	}
	return nil
}

func (r *Runtime) projectMutation(snapshot store.Snapshot) (model.AppState, model.StateMutation, uint64, error) {
	previous := r.publicationSnapshot
	r.pendingAgentRuns = nil
	next := r.baseline
	next.Revision++
	mutation := model.StateMutation{Type: "state-patched", BaseRevision: r.baseline.Revision, Revision: next.Revision}
	r.mu.Lock()
	apps, generation := r.config.Applications, r.applicationGeneration
	r.mu.Unlock()
	fail := func(err error) (model.AppState, model.StateMutation, uint64, error) {
		return next, mutation, generation, err
	}
	changed := map[string]bool{}
	for id := range r.publicationRetries {
		changed[id] = true
	}
	for _, key := range snapshot.ChangedKeys(previous, "thread:") {
		changed[strings.TrimPrefix(key, "thread:")] = true
	}
	for _, key := range snapshot.ChangedKeys(previous, attentionHiddenPrefix) {
		changed[strings.TrimPrefix(key, attentionHiddenPrefix)] = true
	}
	patch := &model.CollectionPatch[model.ThreadRecord]{Upserts: []model.ThreadRecord{}, RemovedIDs: []string{}}
	orderChanged := snapshot.OrderChanged(previous, "threads")
	mokuChanged := false
	for _, id := range sortedMapKeys(changed) {
		before, exists := r.publishedThreads[id]
		if !snapshot.Has("thread:" + id) {
			delete(r.publicationRetries, id)
			if exists {
				patch.RemovedIDs = append(patch.RemovedIDs, id)
				orderChanged = true
				mokuChanged = mokuChanged || before.Moku
			}
			continue
		}
		thread, err := r.projectChangedThread(snapshot, id)
		if err != nil {
			return fail(err)
		}
		if !exists || !same(before, thread) {
			patch.Upserts = append(patch.Upserts, thread)
			if exists && thread.Revision <= before.Revision {
				patch.RemovedIDs = append(patch.RemovedIDs, id)
			}
			orderChanged = orderChanged || !exists
			mokuChanged = mokuChanged || before.Moku || thread.Moku
		}
	}
	if orderChanged {
		order := threadCatalogOrder(snapshot)
		orderChanged = len(order) != len(r.publishedThreadOrder)
		for i, id := range order {
			if rank, found := r.publishedThreadOrder[id]; !found || rank != i {
				orderChanged = true
				break
			}
		}
		if orderChanged {
			patch.Order = &order
		}
	}
	if len(patch.Upserts) > 0 || len(patch.RemovedIDs) > 0 || patch.Order != nil {
		mutation.Threads = patch
	}
	if mokuChanged || orderChanged {
		executions := map[string]model.MokuExecution{}
		for _, execution := range next.Executions {
			executions[execution.ThreadID] = execution
		}
		for _, id := range patch.RemovedIDs {
			delete(executions, id)
		}
		for _, thread := range patch.Upserts {
			delete(executions, thread.ID)
			if execution := thread.Observation.LatestExecution; thread.Moku && execution != nil && !execution.Terminal() {
				executions[thread.ID] = model.MokuExecution{ThreadID: thread.ID, ExecutionID: execution.ExecutionID, Status: execution.Status, StartedAt: execution.StartedAt}
			}
		}
		next.Executions = make([]model.MokuExecution, 0, len(executions))
		for _, execution := range executions {
			next.Executions = append(next.Executions, execution)
		}
		order := r.publishedThreadOrder
		if patch.Order != nil {
			order = make(map[string]int, len(*patch.Order))
			for i, id := range *patch.Order {
				order[id] = i
			}
		}
		sort.Slice(next.Executions, func(i, j int) bool { return order[next.Executions[i].ThreadID] < order[next.Executions[j].ThreadID] })
		if !same(r.baseline.Executions, next.Executions) {
			mutation.Executions = &next.Executions
		}
	}
	if apps != nil {
		if captured, ok := apps.(interface {
			CatalogChanges(context.Context, store.Snapshot, store.Snapshot) (*model.CollectionPatch[model.ApplicationThread], error)
		}); ok && generation == r.publishedAppGeneration {
			appPatch, err := captured.CatalogChanges(r.ctx, previous, snapshot)
			if err != nil {
				return fail(err)
			}
			mutation.ApplicationThreads = r.changedApplications(appPatch)
		} else {
			var entries []model.ApplicationThread
			var err error
			if captured, ok := apps.(interface {
				CatalogSnapshot(context.Context, store.Snapshot) ([]model.ApplicationThread, error)
			}); ok {
				entries, err = captured.CatalogSnapshot(r.ctx, snapshot)
			} else {
				entries, err = apps.Catalog(r.ctx)
			}
			if err != nil {
				return fail(err)
			}
			mutation.ApplicationThreads = r.replaceApplications(entries)
		}
	} else if len(r.publishedApplications) > 0 {
		mutation.ApplicationThreads = r.replaceApplications(nil)
	}
	if changedRecord(snapshot, previous, "settings") {
		next.Settings = model.Settings{}
		if _, err := snapshot.Get("settings", &next.Settings); err != nil {
			return fail(err)
		}
		if !same(r.baseline.Settings, next.Settings) {
			mutation.Settings = &next.Settings
		}
	}
	if changedRecord(snapshot, previous, "settings-revision") {
		next.SettingsRevision = 0
		if _, err := snapshot.Get("settings-revision", &next.SettingsRevision); err != nil {
			return fail(err)
		}
		if next.SettingsRevision != r.baseline.SettingsRevision {
			mutation.SettingsRevision = &next.SettingsRevision
		}
	}
	next.SearchRevision = threadsearch.Revision(snapshot)
	if next.SearchRevision != r.baseline.SearchRevision {
		mutation.SearchRevision = &next.SearchRevision
	}
	if keys := snapshot.ChangedKeys(previous, "tag-redirects:"); len(keys) > 0 {
		next.TagRedirects = make(map[string]*string, len(r.baseline.TagRedirects))
		for key, target := range r.baseline.TagRedirects {
			next.TagRedirects[key] = target
		}
		for _, key := range keys {
			scope := strings.TrimPrefix(key, "tag-redirects:") + "\x00"
			var old, current map[string]*string
			if _, err := previous.Get(key, &old); err != nil {
				return fail(err)
			}
			if _, err := snapshot.Get(key, &current); err != nil {
				return fail(err)
			}
			for name := range old {
				delete(next.TagRedirects, scope+name)
			}
			for name, target := range current {
				next.TagRedirects[scope+name] = target
			}
		}
		if !same(r.baseline.TagRedirects, next.TagRedirects) {
			mutation.TagRedirects = &next.TagRedirects
		}
	}
	if keys := snapshot.ChangedKeys(previous, "private-session:"); len(keys) > 0 {
		for _, key := range keys {
			after, err := agentRun(snapshot, key)
			if err != nil {
				return fail(err)
			}
			before, hadRun := r.publishedAgentRuns[key]
			if (after == nil && !hadRun) || (after != nil && hadRun && before == *after) {
				continue
			}
			if r.pendingAgentRuns == nil {
				r.pendingAgentRuns = map[string]*model.AgentRun{}
			}
			r.pendingAgentRuns[key] = after
		}
		if len(r.pendingAgentRuns) > 0 {
			next.AgentRuns = make([]model.AgentRun, 0, len(r.publishedAgentRuns))
			for key, run := range r.publishedAgentRuns {
				if _, changed := r.pendingAgentRuns[key]; !changed {
					next.AgentRuns = append(next.AgentRuns, run)
				}
			}
			for _, run := range r.pendingAgentRuns {
				if run != nil {
					next.AgentRuns = append(next.AgentRuns, *run)
				}
			}
			sort.Slice(next.AgentRuns, func(i, j int) bool {
				a, b := next.AgentRuns[i], next.AgentRuns[j]
				if a.AgentID != b.AgentID {
					return a.AgentID < b.AgentID
				}
				if a.Scope != b.Scope {
					return a.Scope < b.Scope
				}
				return a.ExecutionID < b.ExecutionID
			})
			if !same(r.baseline.AgentRuns, next.AgentRuns) {
				mutation.AgentRuns = &next.AgentRuns
			}
		}
	}
	return next, mutation, generation, nil
}

func changedRecord(current, previous store.Snapshot, key string) bool {
	left, leftOK := current.RecordHash(key)
	right, rightOK := previous.RecordHash(key)
	return leftOK != rightOK || left != right
}

func (r *Runtime) projectChangedThread(snapshot store.Snapshot, id string) (model.ThreadRecord, error) {
	thread, err := r.cachedThread(r.ctx, snapshot, id)
	if err != nil {
		return thread, err
	}
	hash, _ := snapshot.RecordHash("thread:" + id)
	entry, found := r.overviewCache[id]
	if !found || entry.hash != hash {
		entry = cachedOverview{hash: hash, record: thread}
		if harness := r.config.Harnesses[thread.HarnessID]; harness != nil {
			entry.record.SessionState, err = harness.SessionState().ProjectRenderer(model.CloneRaw(thread.SessionState), model.RendererScope{Kind: "overview"})
			if err != nil {
				r.log("catalog.projection", err)
				entry.record.SessionState = json.RawMessage("null")
				entry.hash = ""
				if r.publicationRetries == nil {
					r.publicationRetries = map[string]bool{}
				}
				r.publicationRetries[id] = true
			}
		}
		if thread.Moku || thread.MokuHistory {
			entry.record.Transcript = auditPreview(thread.Transcript)
		}
		if r.overviewCache == nil {
			r.overviewCache = map[string]cachedOverview{}
		}
		r.overviewCache[id] = entry
	}
	thread = entry.record
	thread.AttentionHidden = snapshot.Has(attentionHiddenPrefix + id)
	thread.DirectoryTag = directorytag.Name(thread.Cwd)
	thread.DirectoryScope = directorytag.Scope(thread.Cwd)
	return thread, nil
}

func threadCatalogOrder(snapshot store.Snapshot) []string {
	ids := snapshot.Order("threads")
	result := make([]string, 0, len(ids))
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if !seen[id] && snapshot.Has("thread:"+id) {
			result = append(result, id)
			seen[id] = true
		}
	}
	for _, key := range snapshot.Keys("thread:") {
		id := strings.TrimPrefix(key, "thread:")
		if !seen[id] {
			result = append(result, id)
		}
	}
	return result
}

func (r *Runtime) changedApplications(patch *model.CollectionPatch[model.ApplicationThread]) *model.CollectionPatch[model.ApplicationThread] {
	if patch == nil {
		return nil
	}
	upserts := patch.Upserts[:0]
	for _, value := range patch.Upserts {
		if old, found := r.publishedApplications[value.ID]; !found || !same(old, value) {
			upserts = append(upserts, value)
			if found && old.Revision == value.Revision && old.Ref.TypeID == value.Ref.TypeID && !slices.Contains(patch.RemovedIDs, value.ID) {
				patch.RemovedIDs = append(patch.RemovedIDs, value.ID)
			}
		}
	}
	patch.Upserts = upserts
	if patch.Order != nil && slices.Equal(*patch.Order, r.publishedApplicationOrder) {
		patch.Order = nil
	}
	if len(patch.Upserts) == 0 && len(patch.RemovedIDs) == 0 && patch.Order == nil {
		return nil
	}
	return patch
}

func (r *Runtime) replaceApplications(entries []model.ApplicationThread) *model.CollectionPatch[model.ApplicationThread] {
	patch := &model.CollectionPatch[model.ApplicationThread]{Upserts: entries, RemovedIDs: []string{}}
	seen := make(map[string]bool, len(entries))
	order := make([]string, 0, len(entries))
	for _, entry := range entries {
		seen[entry.ID] = true
		order = append(order, entry.ID)
	}
	for id := range r.publishedApplications {
		if !seen[id] {
			patch.RemovedIDs = append(patch.RemovedIDs, id)
		}
	}
	patch.Order = &order
	return r.changedApplications(patch)
}

func (r *Runtime) applyPublication(mutation model.StateMutation) {
	for key, run := range r.pendingAgentRuns {
		if run == nil {
			delete(r.publishedAgentRuns, key)
		} else {
			r.publishedAgentRuns[key] = *run
		}
	}
	r.pendingAgentRuns = nil
	if patch := mutation.Threads; patch != nil {
		upserted := make(map[string]bool, len(patch.Upserts))
		for _, thread := range patch.Upserts {
			upserted[thread.ID] = true
		}
		for _, id := range patch.RemovedIDs {
			if !upserted[id] {
				delete(r.publicationRetries, id)
				delete(r.overviewCache, id)
				r.threadCacheMu.Lock()
				delete(r.threadCache, id)
				r.threadCacheMu.Unlock()
			}
			delete(r.publishedThreads, id)
		}
		for _, thread := range patch.Upserts {
			r.publishedThreads[thread.ID] = thread
		}
		if patch.Order != nil {
			r.publishedThreadOrder = make(map[string]int, len(*patch.Order))
			for i, id := range *patch.Order {
				r.publishedThreadOrder[id] = i
			}
		}
	}
	if patch := mutation.ApplicationThreads; patch != nil {
		for _, id := range patch.RemovedIDs {
			delete(r.publishedApplications, id)
		}
		for _, entry := range patch.Upserts {
			r.publishedApplications[entry.ID] = entry
		}
		if patch.Order != nil {
			r.publishedApplicationOrder = *patch.Order
		}
	}
	// A full Snapshot may warm a recovered renderer without updating existing
	// subscribers. A later projection/encoding error may also abort publication.
	// Acknowledge retries only after the entire publication has been accepted,
	// including a successful no-op that already matches the published value.
	for id := range r.publicationRetries {
		if entry, found := r.overviewCache[id]; found && entry.hash != "" {
			delete(r.publicationRetries, id)
		}
	}
}

func agentRun(snapshot store.Snapshot, key string) (*model.AgentRun, error) {
	var session plugin.PrivateSessionSnapshot
	if found, err := snapshot.Get(key, &session); err != nil || !found {
		return nil, err
	}
	if execution := session.Record.Observation.LatestExecution; execution != nil && execution.Status == "running" {
		return &model.AgentRun{AgentID: session.Ref.Owner.AgentID, Scope: session.Ref.Owner.Binding.Scope, ScopeLabel: session.Ref.Owner.ScopeLabel, ExecutionID: execution.ExecutionID, StartedAt: execution.StartedAt}, nil
	}
	return nil, nil
}

func sortedMapKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
