package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"time"
)

type userThreadInputKey struct{}

// SubscribeUserThreadInputs observes committed admissions only. The existing
// lifecycle subscription suppresses historical events and duplicate revisions.
func (r *Runtime) SubscribeUserThreadInputs(ctx context.Context, listener func(plugin.LifecycleEvent)) (func(), error) {
	return r.lifecycle.Subscribe(ctx, plugin.LifecycleScope{{Sources: []string{"user"}, Types: []string{"thread.input-accepted"}, SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"}}}, listener)
}

func (r *Runtime) OnThreadCommitted(listener func(model.ThreadRecord)) func() {
	r.mu.Lock()
	r.nextListener++
	id := r.nextListener
	r.threadListeners[id] = listener
	r.mu.Unlock()
	return func() { r.mu.Lock(); delete(r.threadListeners, id); r.mu.Unlock() }
}
func (r *Runtime) notifyThread(thread model.ThreadRecord) {
	r.mu.Lock()
	listeners := make([]func(model.ThreadRecord), 0, len(r.threadListeners))
	for _, f := range r.threadListeners {
		listeners = append(listeners, f)
	}
	r.mu.Unlock()
	if len(listeners) == 0 {
		return
	}
	// The envelope needs a deep copy, but opaque session history only needs
	// independent bytes. Encoding it again on every streamed commit would scan
	// the entire native history before a listener can inspect the observation.
	envelope := thread
	envelope.SessionState = nil
	envelope.Settings = nil
	envelope.MetadataState = nil
	envelope.Transcript = nil
	raw, err := json.Marshal(envelope)
	if err != nil {
		return
	}
	for _, listener := range listeners {
		var copy model.ThreadRecord
		if json.Unmarshal(raw, &copy) != nil {
			continue
		}
		copy.SessionState = model.CloneRaw(thread.SessionState)
		copy.Settings = model.CloneRaw(thread.Settings)
		copy.MetadataState = model.CloneRaw(thread.MetadataState)
		if thread.Transcript != nil {
			copy.Transcript = make([]json.RawMessage, len(thread.Transcript))
			for index, item := range thread.Transcript {
				copy.Transcript[index] = model.CloneRaw(item)
			}
		}
		safeLifecycleCallback(func() { listener(copy) }, r.log)
	}
}
func (r *Runtime) EnsureMokuThread(ctx context.Context, harnessID string, settings json.RawMessage, cwd string) (model.ThreadRecord, error) {
	threads, err := r.Threads()
	if err != nil {
		return model.ThreadRecord{}, err
	}
	for _, t := range threads {
		if t.Moku {
			return t, nil
		}
	}
	return r.createMokuShell(ctx, "", harnessID, settings, cwd, nil, false, false)
}
func (r *Runtime) ReplaceMokuThread(ctx context.Context, oldID, harnessID string, settings json.RawMessage, cwd string) (model.ThreadRecord, error) {
	if oldID != "" {
		if err := r.CloseMokuThread(ctx, oldID); err != nil {
			return model.ThreadRecord{}, err
		}
	}
	return r.createMokuShell(ctx, oldID, harnessID, settings, cwd, nil, false, false)
}
func (r *Runtime) EnsureConfiguredMokuThread(ctx context.Context, configuration MokuConfiguration) (model.ThreadRecord, error) {
	threads, err := r.Threads()
	if err != nil {
		return model.ThreadRecord{}, err
	}
	for _, t := range threads {
		if t.Moku {
			return t, nil
		}
	}
	var applied *MokuConfiguration
	if !configuration.Unapplied {
		applied = &configuration
	}
	return r.createMokuShell(ctx, "", configuration.HarnessID, configuration.Settings, configuration.Cwd, applied, false, false)
}
func (r *Runtime) ReplaceConfiguredMokuThread(ctx context.Context, oldID string, configuration MokuConfiguration) (model.ThreadRecord, error) {
	if oldID != "" {
		old, err := r.Thread(oldID)
		if err != nil {
			return model.ThreadRecord{}, err
		}
		if old.HarnessID != configuration.HarnessID {
			release, err := r.beginMokuHarnessChange(ctx, true)
			if err != nil {
				return model.ThreadRecord{}, err
			}
			defer release()
		}
		if err := r.CloseMokuThread(ctx, oldID); err != nil {
			return model.ThreadRecord{}, err
		}
	}
	var applied *MokuConfiguration
	if !configuration.Unapplied {
		applied = &configuration
	}
	return r.createMokuShell(ctx, oldID, configuration.HarnessID, configuration.Settings, configuration.Cwd, applied, configuration.PreserveNote, configuration.PreserveHistory)
}
func (r *Runtime) createMokuShell(ctx context.Context, oldID, harnessID string, settings json.RawMessage, cwd string, applied *MokuConfiguration, preserveNote, preserveHistory bool) (model.ThreadRecord, error) {
	if r.config.Harnesses[harnessID] == nil {
		return model.ThreadRecord{}, fmt.Errorf("unknown Moku harness: %s", harnessID)
	}
	if len(settings) == 0 {
		settings = json.RawMessage(`{}`)
	}
	if cwd == "" {
		cwd = r.config.DefaultCwd
	}
	id, err := newID()
	if err != nil {
		return model.ThreadRecord{}, err
	}
	now := time.Now().UnixMilli()
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: harnessID, SessionState: json.RawMessage("null"), Settings: settings, Cwd: cwd, CreatedAt: now, UpdatedAt: now}, Moku: true, Title: "Moku", Tags: []string{}, TagEmojis: map[string]string{}, Transcript: []json.RawMessage{}}
	retiredOwners := []string{}
	_, err = r.config.Store.Update(ctx, func(tx *store.Tx) error {
		if applied != nil {
			if err := r.assertAppliedConfiguration(tx, *applied); err != nil {
				return err
			}
		}
		order := []string{}
		for _, existing := range tx.Order("threads") {
			if existing != oldID || preserveHistory {
				order = append(order, existing)
			}
		}
		if oldID != "" {
			var old model.ThreadRecord
			ok, e := tx.Get("thread:"+oldID, &old)
			if e != nil {
				return e
			}
			if !ok || !old.Moku {
				return errors.New("Moku session changed during replacement")
			}
			if preserveNote && old.Note != nil {
				note := *old.Note
				if note.LastExposure != nil {
					exposure := *note.LastExposure
					note.LastExposure = &exposure
				}
				thread.Note = &note
			}
			if preserveHistory {
				// Native state can contain Moku-only instructions and tools. Keep
				// it readable, but never turn it into an executable ordinary task.
				archive := old
				archive.Moku = false
				archive.MokuHistory = true
				archived := true
				archive.Archived = &archived
				archive.Note = nil
				archive.Title = "Moku history · " + old.HarnessID
				archive.UpdatedAt = now
				archive.Revision++
				if err := tx.Put("thread:"+oldID, archive); err != nil {
					return err
				}
				if err := r.threadEvents(tx, &old, &archive); err != nil {
					return err
				}
			} else {
				// An explicit history reset also retires previously switched
				// Harness sessions, including their attachment ownership.
				remove := map[string]bool{oldID: true}
				for _, key := range tx.Keys("thread:") {
					var previous model.ThreadRecord
					if _, err := tx.Get(key, &previous); err != nil {
						return err
					}
					if previous.MokuHistory {
						remove[previous.ID] = true
					}
				}
				kept := order[:0]
				for _, existing := range order {
					if !remove[existing] {
						kept = append(kept, existing)
					}
				}
				order = kept
				for retiredID := range remove {
					var previous model.ThreadRecord
					if _, err := tx.Get("thread:"+retiredID, &previous); err != nil {
						return err
					}
					for _, key := range tx.Keys("interaction-answer:" + retiredID + ":") {
						if err := tx.Delete(key); err != nil {
							return err
						}
					}
					if err := tx.Delete("thread:" + retiredID); err != nil {
						return err
					}
					if err := r.threadEvents(tx, &previous, nil); err != nil {
						return err
					}
					retiredOwners = append(retiredOwners, retiredID)
				}
			}
		} else {
			for _, key := range tx.Keys("thread:") {
				var current model.ThreadRecord
				if _, e := tx.Get(key, &current); e != nil {
					return e
				}
				if current.Moku {
					return errors.New("Moku session already exists")
				}
			}
		}
		if err := tx.Put("thread:"+id, thread); err != nil {
			return err
		}
		if err := tx.SetOrder("threads", append([]string{id}, order...)); err != nil {
			return err
		}
		if applied != nil {
			if err := tx.Put("moku-applied-settings", map[string]any{"settings": applied.AppliedSettings, "settingsRevision": applied.SettingsRevision}); err != nil {
				return err
			}
		} else if err := tx.Delete("moku-applied-settings"); err != nil {
			return err
		}
		return r.threadEvents(tx, nil, &thread)
	})
	if err == nil && r.config.Attachments != nil {
		for _, retiredID := range retiredOwners {
			r.log("moku.attachments.release", r.config.Attachments.ReleaseOwner(ctx, retiredID))
		}
	}
	return thread, err
}
func (r *Runtime) ConfigureMokuThread(ctx context.Context, id string, expected int64, harnessID string, settings json.RawMessage, applied model.Settings, settingsRevision int64, cwd string) error {
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var thread model.ThreadRecord
		ok, err := tx.Get("thread:"+id, &thread)
		if err != nil {
			return err
		}
		if !ok || !thread.Moku {
			return errors.New("Moku session no longer exists")
		}
		if thread.Revision != expected {
			return model.NewError("REVISION_CONFLICT", "Moku configuration source changed")
		}
		if e := thread.Observation.LatestExecution; e != nil && !e.Terminal() {
			return errors.New("cannot replace active Moku configuration")
		}
		if thread.Observation.BackgroundWork != nil {
			return errors.New("cannot replace Moku configuration with native background work")
		}
		if err := r.assertAppliedConfiguration(tx, MokuConfiguration{AppliedSettings: applied, SettingsRevision: settingsRevision}); err != nil {
			return err
		}
		if thread.HarnessID != harnessID && !model.IsNull(thread.SessionState) {
			return errors.New("replace Moku session before changing its harness")
		}
		before := thread
		thread.HarnessID = harnessID
		thread.Settings = settings
		thread.Cwd = cwd
		thread.Revision++
		thread.UpdatedAt = time.Now().UnixMilli()
		if err := tx.Put("thread:"+id, thread); err != nil {
			return err
		}
		if err := tx.Put("moku-applied-settings", map[string]any{"settings": applied, "settingsRevision": settingsRevision}); err != nil {
			return err
		}
		return r.threadEvents(tx, &before, &thread)
	})
	if err != nil {
		return err
	}
	return r.closeThreadHandle(id)
}

func (r *Runtime) assertAppliedConfiguration(tx *store.Tx, configuration MokuConfiguration) error {
	var current model.Settings
	var revision int64
	if _, err := tx.Get("settings", &current); err != nil {
		return err
	}
	if _, err := tx.Get("settings-revision", &revision); err != nil {
		return err
	}
	if revision != configuration.SettingsRevision || !same(current, configuration.AppliedSettings) {
		return model.NewError("REVISION_CONFLICT", "saved settings changed before native configuration admission")
	}
	return nil
}
func (r *Runtime) OpenMokuThread(ctx context.Context, id string, injection *plugin.Injection) error {
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	t, err := r.Thread(id)
	if err != nil {
		return err
	}
	if !t.Moku {
		return errors.New("not a Moku session")
	}
	_, err = r.openThread(ctx, t, injection)
	return err
}
func (r *Runtime) CloseMokuThread(ctx context.Context, id string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	return r.closeThreadHandle(id)
}
func (r *Runtime) closeThreadHandle(id string) error {
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	if owner == nil {
		return nil
	}
	if err := owner.close(); err != nil {
		return err
	}
	r.mu.Lock()
	if r.handles[id] == owner {
		delete(r.handles, id)
	}
	r.mu.Unlock()
	return nil
}
func (r *Runtime) SendMokuThread(ctx context.Context, id string, input model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry, onAdmitted func(plugin.SessionSendResult) error) (plugin.SessionSendResult, error) {
	if err := r.begin(); err != nil {
		return SendResult{}, err
	}
	defer r.operations.Done()
	if err := validateInput(input); err != nil {
		return SendResult{}, err
	}
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	t, err := r.Thread(id)
	if err != nil {
		return SendResult{}, err
	}
	if !t.Moku {
		return SendResult{}, errors.New("not a Moku session")
	}
	return r.sendLockedAdmitted(ctx, id, input, injection, entries, onAdmitted)
}
func (r *Runtime) CompletedReply(id, executionID string) (string, bool) {
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	if owner == nil {
		return "", false
	}
	if reply, ok := owner.native.(plugin.CompletedReply); ok {
		return reply.CompletedReply(executionID)
	}
	return "", false
}
func (r *Runtime) PrepareMokuVoice(ctx context.Context, id string, entries []plugin.ContextEntry) (plugin.VoiceSession, error) {
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	t, err := r.Thread(id)
	if err != nil {
		return nil, err
	}
	owner, err := r.openThread(ctx, t, nil)
	if err != nil {
		return nil, err
	}
	native, ok := owner.native.(plugin.NativeVoiceCapability)
	if !ok {
		return nil, errors.New("Moku harness does not provide native voice")
	}
	return native.PrepareNativeVoice(ctx, entries)
}
func (r *Runtime) Ledger(id string) plugin.TelemetryLedger {
	if r.config.TelemetryLedger != nil {
		harnessID := id
		if r.config.Harnesses[id] == nil {
			if thread, err := r.sessionThread(id); err == nil {
				harnessID = thread.HarnessID
			}
		}
		return r.config.TelemetryLedger(harnessID)
	}
	return telemetryLedger{r, id}
}
func (r *Runtime) SetMokuNativeAdmission(id string, callback func(context.Context) error) error {
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	if owner == nil {
		return errors.New("Moku native handle is not open")
	}
	owner.mu.Lock()
	defer owner.mu.Unlock()
	if owner.closed {
		return errors.New("Moku native handle is closed")
	}
	owner.beforeNativeAdmission = callback
	return nil
}
