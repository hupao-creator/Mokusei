package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func privateSessionKey(owner plugin.BackgroundAgentRef, key string) string {
	return "private-session:" + owner.AgentID + ":" + key
}

type backgroundCapability struct {
	runtime    *Runtime
	owner      plugin.BackgroundAgentRef
	settingsID string
}

func (r *Runtime) BackgroundCapabilities(owner plugin.BackgroundAgentRef, settingsID string) plugin.CapabilityAccess {
	if err := owner.Binding.Validate(); err != nil {
		return capabilityAccess{phase: "runtime", err: err}
	}
	if owner.PluginID == "" || owner.AgentID == "" {
		return capabilityAccess{phase: "runtime", err: errors.New("missing background owner identity")}
	}
	access := r.RuntimeCapabilities(owner.PluginID).(capabilityAccess)
	background := backgroundCapability{r, owner, settingsID}
	access.values[plugin.BackgroundConfigurationCapabilityKey.ID] = background
	access.values[plugin.BackgroundSessionsCapabilityKey.ID] = background
	access.values[plugin.BackgroundEnvironmentCapabilityKey.ID] = background
	access.values[plugin.OrdinaryTaskReadCapabilityKey.ID] = taskReadCapability{runtime: r, binding: owner.Binding}
	access.values[plugin.LifecycleCapabilityKey.ID] = scopedLifecycle{base: r.lifecycle, owner: owner}
	access.values[plugin.SemanticTagsReadCapabilityKey.ID] = tagsReadCapability{r, owner.Binding.Scope}
	access.values[plugin.SemanticTagsWriteCapabilityKey.ID] = tagsWriteCapability{r, owner.AgentID, owner.Binding.Scope}
	if owner.Binding.Kind == plugin.DirectoryScopeKind {
		// Classification includes application-wide evidence and has no scoped contract.
		delete(access.values, plugin.ClassificationReadCapabilityKey.ID)
	}
	if owner.Binding.Kind == plugin.GlobalScope {
		// Semantic-tag operations require a particular directory, never an implicit Inbox.
		delete(access.values, plugin.SemanticTagsReadCapabilityKey.ID)
		delete(access.values, plugin.SemanticTagsWriteCapabilityKey.ID)
	}
	if r.config.ProcessFactory != nil {
		access.values[plugin.ApplicationProcessCapabilityKey.ID] = r.config.ProcessFactory(background.Cwd())
	}
	return access
}
func (c backgroundCapability) Owner() plugin.BackgroundAgentRef { return c.owner }
func (c backgroundCapability) Cwd() string {
	return filepath.Join(c.runtime.config.DefaultCwd, "plugins", c.owner.PluginID, c.owner.AgentID)
}
func (c backgroundCapability) OutputLocale(ctx context.Context) (string, error) {
	if c.runtime.config.OutputLocale != nil {
		return c.runtime.config.OutputLocale(ctx)
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	return "zh-CN", nil
}
func (c backgroundCapability) Log(level, event string, fields model.Object) {
	raw, err := json.Marshal(fields)
	if err == nil {
		c.runtime.log(c.owner.AgentID+"."+event, fmt.Errorf("%s: %s", level, raw))
	}
}
func (c backgroundCapability) Resolve(ctx context.Context, sessionKey string) (plugin.ResolvedBackgroundConfiguration, error) {
	if err := c.runtime.begin(); err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	defer c.runtime.operations.Done()
	ctx, cancel := c.runtime.operationContext(ctx)
	defer cancel()
	if err := identifier(sessionKey); err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	// Capture settings and its revision from the same configuration admission.
	// Native discovery may run afterwards; Configure fences any intervening save.
	unlock, err := c.runtime.configurationLock(ctx)
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	admission := context.WithValue(ctx, configurationContextKey{}, c.runtime)
	settings, err := c.runtime.EnsureExecutionSettings(admission, "", c.settingsID)
	_, revision, revisionErr := c.runtime.Settings()
	unlock()
	if err == nil {
		err = revisionErr
	}
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	harnesses, preference, err := c.effectiveSettings(settings)
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	cwd := c.Cwd()
	if err := os.MkdirAll(cwd, 0700); err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	cwd, err = validateCwd(cwd)
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	existing, err := c.Read(sessionKey)
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	harnessID, err := c.runtime.ResolveHost(ctx, preference, harnesses, cwd)
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	h := c.runtime.config.Harnesses[harnessID]
	merged := harnesses[harnessID]
	if len(merged) == 0 {
		return plugin.ResolvedBackgroundConfiguration{}, errors.New("background execution profile is not captured")
	}
	defaults, err := h.Settings().DefaultThread(merged)
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	request := plugin.ResolveSettingsRequest{Merged: defaults, Cwd: cwd}
	if existing != nil && existing.Record.HarnessID == harnessID && existing.Record.Cwd == cwd {
		request.Existing = model.CloneRaw(existing.Record.Settings)
		request.SessionState = model.CloneRaw(existing.Record.SessionState)
	}
	threadSettings, err := h.Settings().ResolveThread(ctx, request)
	if err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	if err = ctx.Err(); err != nil {
		return plugin.ResolvedBackgroundConfiguration{}, err
	}
	result := plugin.ResolvedBackgroundConfiguration{SessionKey: sessionKey, SettingsRevision: revision, HarnessID: harnessID, Cwd: cwd, ThreadSettings: threadSettings, ConfigurationKey: backgroundConfigurationKey(harnessID, cwd, merged)}
	if existing != nil {
		result.SessionRevision = &existing.Record.Revision
	}
	return result, nil
}

func (c backgroundCapability) effectiveSettings(settings model.Settings) (map[string]json.RawMessage, string, error) {
	harnesses, preference := settings.Moku.ExecutionHarnesses, settings.Moku.HostHarnessPreference
	if c.settingsID == "" {
		return harnesses, preference, nil
	}
	for _, entry := range settings.PluginSettings {
		if entry.ID != c.settingsID {
			continue
		}
		var value backgroundSettings
		if err := json.Unmarshal(entry.Value, &value); err != nil {
			return nil, "", err
		}
		if value.Mode == "override" {
			harnesses, preference = value.Harnesses, value.HarnessPreference
		} else if value.Mode != "inherit" {
			return nil, "", errors.New("invalid background execution settings mode")
		}
		return harnesses, preference, nil
	}
	return nil, "", fmt.Errorf("unknown background settings: %s", c.settingsID)
}
func backgroundConfigurationKey(harnessID, cwd string, settings json.RawMessage) string {
	raw, _ := json.Marshal([]any{harnessID, cwd, settings})
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:])
}
func equalRevision(left, right *int64) bool {
	return left == nil && right == nil || left != nil && right != nil && *left == *right
}
func (r *Runtime) ResolveHost(ctx context.Context, preference string, harnesses map[string]json.RawMessage, cwd string) (string, error) {
	ids := []string{}
	for _, id := range []string{"pi", "codex", "claude", "opencode"} {
		if r.config.Harnesses[id] != nil {
			ids = append(ids, id)
		}
	}
	for _, id := range r.harnessIDs() {
		if !contains(ids, id) {
			ids = append(ids, id)
		}
	}
	if preference != "" && preference != "auto" {
		ids = []string{preference}
	}
	var reasons []string
	for _, id := range ids {
		if r.config.DisabledHarnesses[id] != "" {
			reasons = append(reasons, id+": disabled")
			continue
		}
		h := r.config.Harnesses[id]
		if h == nil {
			return "", fmt.Errorf("unknown harness: %s", id)
		}
		if !h.Descriptor().ThreadCapabilities.CanHostMoku() {
			reasons = append(reasons, id+": cannot host injected tools")
			continue
		}
		settings := harnesses[id]
		if len(settings) == 0 {
			settings = h.DefaultSettings()
		}
		if probe, ok := h.(plugin.AvailabilityProbe); ok {
			available, err := probe.Probe(ctx, plugin.SettingsRequest{Settings: settings, Cwd: cwd}, "exclusive")
			if err != nil {
				reasons = append(reasons, id+": "+err.Error())
				continue
			}
			if available.Available && (!available.RequiresExplicitSelection || preference == id) {
				return id, nil
			}
			reasons = append(reasons, id+": "+available.Reason)
			continue
		}
		installation, err := h.Detect(ctx, cwd)
		if err != nil {
			reasons = append(reasons, id+": "+err.Error())
			continue
		}
		if installation.Status == "installed" || installation.Status == "available" {
			return id, nil
		}
		reasons = append(reasons, id+": "+installation.Status)
	}
	return "", fmt.Errorf("no available execution harness: %s", strings.Join(reasons, "; "))
}
func (c backgroundCapability) Read(sessionKey string) (*plugin.PrivateSessionSnapshot, error) {
	if err := identifier(sessionKey); err != nil {
		return nil, err
	}
	var snapshot plugin.PrivateSessionSnapshot
	ok, err := c.runtime.config.Store.Snapshot().Get(privateSessionKey(c.owner, sessionKey), &snapshot)
	if err != nil || !ok {
		return nil, err
	}
	if snapshot.Ref.Owner != c.owner {
		return nil, errors.New("private session owner mismatch")
	}
	return &snapshot, nil
}
func (c backgroundCapability) Configure(ctx context.Context, request plugin.ConfigureSessionRequest) (plugin.PrivateSessionSnapshot, error) {
	if err := c.runtime.begin(); err != nil {
		return plugin.PrivateSessionSnapshot{}, err
	}
	defer c.runtime.operations.Done()
	ctx, cancel := c.runtime.operationContext(ctx)
	defer cancel()
	if err := identifier(request.SessionKey); err != nil {
		return plugin.PrivateSessionSnapshot{}, err
	}
	configuration := request.Configuration
	if configuration.SessionKey != request.SessionKey || !equalRevision(configuration.SessionRevision, request.ExpectedRevision) {
		return plugin.PrivateSessionSnapshot{}, errors.New("configuration belongs to another private session revision")
	}
	if !json.Valid(configuration.ThreadSettings) {
		return plugin.PrivateSessionSnapshot{}, errors.New("background thread settings must be JSON")
	}
	// Settings saves, configuration changes, opening and sends each have a stable
	// lock order: configuration admission, private slot, then native session ID.
	unlock, err := c.runtime.configurationLock(ctx)
	if err != nil {
		return plugin.PrivateSessionSnapshot{}, err
	}
	defer unlock()
	key := privateSessionKey(c.owner, request.SessionKey)
	slot := c.runtime.threadLock("background-config:" + key)
	slot.Lock()
	defer slot.Unlock()
	source, err := c.Read(request.SessionKey)
	if err != nil {
		return plugin.PrivateSessionSnapshot{}, err
	}
	if source != nil {
		lock := c.runtime.threadLock(source.Record.ID)
		lock.Lock()
		defer lock.Unlock()
	}
	expectedCwd, err := validateCwd(c.Cwd())
	if err != nil {
		return plugin.PrivateSessionSnapshot{}, err
	}
	validate := func(snapshot store.Snapshot) (*plugin.PrivateSessionSnapshot, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var settings model.Settings
		var revision int64
		if ok, err := snapshot.Get("settings", &settings); err != nil {
			return nil, err
		} else if !ok {
			return nil, errors.New("settings unavailable")
		}
		if _, err := snapshot.Get("settings-revision", &revision); err != nil {
			return nil, err
		}
		if revision != configuration.SettingsRevision {
			return nil, errors.New("settings changed while resolving background configuration")
		}
		harnesses, _, err := c.effectiveSettings(settings)
		if err != nil {
			return nil, err
		}
		harness := c.runtime.config.Harnesses[configuration.HarnessID]
		profile := harnesses[configuration.HarnessID]
		if harness == nil || !harness.Descriptor().ThreadCapabilities.CanHostMoku() || c.runtime.config.DisabledHarnesses[configuration.HarnessID] != "" || len(profile) == 0 || configuration.Cwd != expectedCwd || configuration.ConfigurationKey != backgroundConfigurationKey(configuration.HarnessID, expectedCwd, profile) {
			return nil, errors.New("stale or unregistered background configuration")
		}
		var current plugin.PrivateSessionSnapshot
		exists, err := snapshot.Get(key, &current)
		if err != nil {
			return nil, err
		}
		if !exists {
			if request.ExpectedRevision != nil {
				return nil, errors.New("private session disappeared")
			}
			return nil, nil
		}
		if current.Ref.Owner != c.owner || request.ExpectedRevision == nil || current.Record.Revision != *request.ExpectedRevision {
			return nil, errors.New("private session revision conflict")
		}
		if source == nil || current.Record.ID != source.Record.ID {
			return nil, errors.New("private session changed during configuration")
		}
		if current.Record.Observation.BackgroundWork != nil || current.Record.Observation.LatestExecution != nil && !current.Record.Observation.LatestExecution.Terminal() {
			return nil, errors.New("background configuration applies only while idle")
		}
		return &current, nil
	}
	current, err := validate(c.runtime.config.Store.Snapshot())
	if err != nil {
		return plugin.PrivateSessionSnapshot{}, err
	}
	if current != nil && current.ConfigurationKey == configuration.ConfigurationKey {
		return *current, nil
	}
	if current != nil {
		if err = c.runtime.closeThreadHandle(current.Record.ID); err != nil {
			return plugin.PrivateSessionSnapshot{}, err
		}
	}
	id := ""
	if current != nil {
		id = current.Record.ID
	} else {
		id, err = newID()
		if err != nil {
			return plugin.PrivateSessionSnapshot{}, err
		}
	}
	var configured plugin.PrivateSessionSnapshot
	_, err = c.runtime.config.Store.Update(ctx, func(tx *store.Tx) error {
		current, err := validate(tx.Snapshot())
		if err != nil {
			return err
		}
		now := time.Now().UnixMilli()
		record := model.SessionRecord{ID: id, HarnessID: configuration.HarnessID, SessionState: json.RawMessage("null"), Settings: model.CloneRaw(configuration.ThreadSettings), Cwd: configuration.Cwd, CreatedAt: now, UpdatedAt: now}
		if current != nil {
			record.Revision = current.Record.Revision + 1
			record.CreatedAt = current.Record.CreatedAt
			record.UpdatedAt = max(now, current.Record.UpdatedAt)
			if current.Record.HarnessID == record.HarnessID && current.Record.Cwd == record.Cwd {
				record.SessionState = current.Record.SessionState
				record.Observation = current.Record.Observation
			}
		}
		configured = plugin.PrivateSessionSnapshot{Ref: plugin.PrivateSessionRef{Owner: c.owner, SessionKey: request.SessionKey, SessionID: id}, ConfigurationKey: configuration.ConfigurationKey, Record: record}
		if err := tx.Put(key, configured); err != nil {
			return err
		}
		if err := tx.Put("private-session-index:"+id, key); err != nil {
			return err
		}
		kind := "entity.created"
		if current != nil {
			kind = "entity.updated"
		}
		return c.runtime.appendEvent(tx, kind, store.Subject{Kind: "session", ID: id, TypeID: c.owner.AgentID}, c.owner.AgentID, map[string]any{"harnessId": record.HarnessID}, nil)
	})
	return configured, err
}
func (c backgroundCapability) Open(ctx context.Context, request plugin.OpenSessionRequest) (plugin.PrivateSessionHandle, error) {
	if err := c.runtime.begin(); err != nil {
		return nil, err
	}
	defer c.runtime.operations.Done()
	ctx, cancel := c.runtime.operationContext(ctx)
	defer cancel()
	if err := identifier(request.SessionKey); err != nil {
		return nil, err
	}
	slot := c.runtime.threadLock("background-config:" + privateSessionKey(c.owner, request.SessionKey))
	slot.Lock()
	defer slot.Unlock()
	snapshot, err := c.Read(request.SessionKey)
	if err != nil {
		return nil, err
	}
	if snapshot == nil {
		return nil, errors.New("configure the private session before opening")
	}
	lock := c.runtime.threadLock(snapshot.Record.ID)
	lock.Lock()
	defer lock.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// Session publication can advance while a previous send was holding the lock.
	snapshot, err = c.Read(request.SessionKey)
	if err != nil {
		return nil, err
	}
	if snapshot == nil {
		return nil, errors.New("private session disappeared")
	}
	thread := model.ThreadRecord{SessionRecord: snapshot.Record, Tags: []string{}, TagEmojis: map[string]string{}}
	owner, err := c.runtime.openThread(ctx, thread, &request.Injection)
	if err != nil {
		return nil, err
	}
	return &privateHandle{cap: c, ref: snapshot.Ref, owner: owner}, nil
}

type privateHandle struct {
	cap   backgroundCapability
	ref   plugin.PrivateSessionRef
	owner *threadHandle
}

func (h *privateHandle) Ref() plugin.PrivateSessionRef { return h.ref }
func (h *privateHandle) Observation() model.PublicObservation {
	snapshot, err := h.cap.Read(h.ref.SessionKey)
	if err != nil || snapshot == nil || snapshot.Ref.SessionID != h.ref.SessionID {
		return model.PublicObservation{}
	}
	return snapshot.Record.Observation
}
func (h *privateHandle) Send(ctx context.Context, input model.AgentInput, entries []plugin.ContextEntry, onAdmitted plugin.SessionSendAdmitted) (plugin.SessionSendResult, error) {
	r := h.cap.runtime
	if err := r.begin(); err != nil {
		return SendResult{}, err
	}
	defer r.operations.Done()
	ctx, cancel := r.operationContext(ctx)
	defer cancel()
	if err := validateInput(input); err != nil {
		return SendResult{}, err
	}
	lock := r.threadLock(h.ref.SessionID)
	lock.Lock()
	defer lock.Unlock()
	if err := h.owner.active(); err != nil {
		return SendResult{}, err
	}
	snapshot, err := h.cap.Read(h.ref.SessionKey)
	if err != nil {
		return SendResult{}, err
	}
	if snapshot == nil || snapshot.Ref.SessionID != h.ref.SessionID {
		return SendResult{}, errors.New("private session replaced")
	}
	return r.sendLockedAdmitted(ctx, h.ref.SessionID, input, nil, entries, onAdmitted)
}
func (h *privateHandle) Interrupt(ctx context.Context, expected *string) error {
	if err := h.owner.active(); err != nil {
		return err
	}
	if expected != nil {
		e := h.Observation().LatestExecution
		if e == nil || e.ExecutionID != *expected {
			return errors.New("private execution changed")
		}
	}
	return h.owner.native.Interrupt(ctx)
}
func (h *privateHandle) Close() error {
	lock := h.cap.runtime.threadLock(h.ref.SessionID)
	lock.Lock()
	defer lock.Unlock()
	// Closing an obsolete facade must not dispose a newly opened native owner.
	h.cap.runtime.mu.Lock()
	current := h.cap.runtime.handles[h.ref.SessionID]
	h.cap.runtime.mu.Unlock()
	if current != h.owner {
		return h.owner.close()
	}
	return h.cap.runtime.closeThreadHandle(h.ref.SessionID)
}
func (r *Runtime) sessionThread(id string) (model.ThreadRecord, error) {
	thread, err := r.Thread(id)
	if err == nil {
		return thread, nil
	}
	snapshot := r.config.Store.Snapshot()
	var key string
	ok, e := snapshot.Get("private-session-index:"+id, &key)
	if e != nil {
		return model.ThreadRecord{}, e
	}
	if !ok {
		return model.ThreadRecord{}, err
	}
	var session plugin.PrivateSessionSnapshot
	ok, e = snapshot.Get(key, &session)
	if e != nil {
		return model.ThreadRecord{}, e
	}
	if !ok || session.Record.ID != id {
		return model.ThreadRecord{}, errors.New("private session index is stale")
	}
	return model.ThreadRecord{SessionRecord: session.Record, Tags: []string{}, TagEmojis: map[string]string{}}, nil
}
func (r *Runtime) updateSessionThread(ctx context.Context, id string, update func(*model.ThreadRecord) error) error {
	if r.config.Store.Snapshot().Has("thread:" + id) {
		return r.UpdateThread(ctx, id, update)
	}
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var key string
		ok, err := tx.Get("private-session-index:"+id, &key)
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("private session disappeared")
		}
		var session plugin.PrivateSessionSnapshot
		ok, err = tx.Get(key, &session)
		if err != nil {
			return err
		}
		if !ok || session.Record.ID != id {
			return errors.New("private session identity changed")
		}
		before := session.Record
		thread := model.ThreadRecord{SessionRecord: session.Record}
		if err := update(&thread); err != nil {
			return err
		}
		thread.Revision++
		thread.UpdatedAt = max(time.Now().UnixMilli(), thread.UpdatedAt)
		session.Record = thread.SessionRecord
		if err := tx.Put(key, session); err != nil {
			return err
		}
		subject := store.Subject{Kind: "session", ID: id, TypeID: session.Ref.Owner.AgentID}
		old := before.Observation.LatestExecution
		next := session.Record.Observation.LatestExecution
		if next != nil && (old == nil || old.ExecutionID != next.ExecutionID || old.Status != next.Status || (next.Status == "waiting-for-user" && !same(old, next))) {
			introduced := []string{}
			if next.Status == "waiting-for-user" {
				for _, interaction := range next.Interactions {
					present := false
					if old != nil && old.ExecutionID == next.ExecutionID && old.Status == "waiting-for-user" {
						for _, previous := range old.Interactions {
							if previous.ID == interaction.ID && same(previous, interaction) {
								present = true
								break
							}
						}
					}
					if !present {
						introduced = append(introduced, interaction.ID)
					}
				}
			}
			if err := r.appendEvent(tx, "execution."+next.Status, subject, session.Ref.Owner.AgentID, next, introduced); err != nil {
				return err
			}
		}
		if !same(before.Observation.BackgroundWork, session.Record.Observation.BackgroundWork) {
			kind := "background.finished"
			if session.Record.Observation.BackgroundWork != nil {
				kind = "background.started"
			}
			return r.appendEvent(tx, kind, subject, session.Ref.Owner.AgentID, session.Record.Observation, nil)
		}
		return nil
	})
	return err
}
