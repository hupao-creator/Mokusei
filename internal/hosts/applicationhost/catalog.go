package applicationhost

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func newCommandID() string {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(data[:])
}
func (h *Host) readThread(snap store.Snapshot, ref model.ThreadRef) (plugin.ThreadTypeDefinition, model.ApplicationThreadRecord, error) {
	definition, ok := h.threadTypes[ref.TypeID]
	if !ok || !h.enabled(definition.OwnerPluginID) {
		return definition, model.ApplicationThreadRecord{}, fmt.Errorf("unknown application thread type: %s", ref.TypeID)
	}
	var record model.VersionedRecord
	exists, err := snap.Get(recordKey(definition.CollectionID, ref.ThreadID), &record)
	if err != nil {
		return definition, model.ApplicationThreadRecord{}, err
	}
	if !exists {
		return definition, model.ApplicationThreadRecord{}, fmt.Errorf("unknown application thread: %s", ref.ThreadID)
	}
	return definition, model.ApplicationThreadRecord{VersionedRecord: record, Ref: ref}, nil
}
func (h *Host) Catalog(ctx context.Context) ([]model.ApplicationThread, error) {
	return h.CatalogSnapshot(ctx, h.config.Store.Snapshot())
}
func (h *Host) CatalogSnapshot(ctx context.Context, snap store.Snapshot) ([]model.ApplicationThread, error) {
	if err := h.begin(); err != nil {
		return nil, err
	}
	defer h.operations.Done()
	result := []model.ApplicationThread{}
	seen := map[string]bool{}
	for _, id := range sortedKeys(h.threadTypes) {
		definition := h.threadTypes[id]
		if !h.enabled(definition.OwnerPluginID) {
			continue
		}
		reader := newReader(h, definition.OwnerPluginID, snap)
		records, err := reader.List(definition.CollectionID)
		if err != nil {
			return nil, err
		}
		for _, record := range records {
			if seen[record.ID] {
				return nil, errors.New("application catalog has duplicate thread identity")
			}
			seen[record.ID] = true
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			thread := model.ApplicationThreadRecord{VersionedRecord: record, Ref: model.ThreadRef{ThreadID: record.ID, TypeID: id}}
			entry, err := h.projectThread(ctx, definition, thread)
			if err != nil {
				return nil, err
			}
			result = append(result, entry)
		}
	}
	return result, nil
}
func (h *Host) projectThread(ctx context.Context, definition plugin.ThreadTypeDefinition, record model.ApplicationThreadRecord) (model.ApplicationThread, error) {
	projection, err := definition.Project(record)
	if err != nil {
		return model.ApplicationThread{}, err
	}
	view, err := definition.Contract.Validate(projection.View)
	if err != nil {
		return model.ApplicationThread{}, err
	}
	entry := model.ApplicationThread{Scope: projection.Scope, ID: record.ID, Ref: record.Ref, Revision: record.Revision, CreatedAt: record.CreatedAt, UpdatedAt: record.UpdatedAt, Title: projection.Title, Tags: model.TagProjection{Tags: []string{}, TagEmojis: map[string]string{}, SemanticTags: []string{}, DirectoryTags: []string{}}, Presentations: []model.ThreadPresentation{}, View: view}
	if definition.Tags != nil {
		entry.Tags, err = definition.Tags.Project(record)
		if err != nil {
			return entry, err
		}
	}
	if definition.Archive != nil {
		entry.Archived = definition.Archive.Archived(record)
	}
	if definition.Overview != nil {
		overview, e := definition.Overview.Presentation(record)
		if e != nil {
			return entry, e
		}
		if overview.CoversExecutions == nil {
			overview.CoversExecutions = []model.ExecutionRef{}
		}
		raw, e := json.Marshal(overview)
		if e != nil {
			return entry, e
		}
		entry.Presentations = append(entry.Presentations, model.ThreadPresentation{ID: "mokusei.overview", APIVersion: 1, SchemaVersion: 1, Value: raw})
	}
	if definition.Conversation != nil {
		session, e := definition.Conversation.ReadSession(record)
		if e != nil {
			return entry, e
		}
		var thread *model.ThreadRecord
		if session != nil {
			if session.ID != record.ID {
				return entry, errors.New("application conversation identity mismatch")
			}
			if h.config.ProjectSession == nil {
				return entry, errors.New("application conversation projector unavailable")
			}
			projected, e := h.config.ProjectSession(ctx, *session)
			if e != nil {
				return entry, e
			}
			thread = &model.ThreadRecord{SessionRecord: projected, Title: entry.Title, Tags: entry.Tags.SemanticTags, TagEmojis: entry.Tags.TagEmojis}
		}
		raw, e := json.Marshal(model.Object{"thread": thread})
		if e != nil {
			return entry, e
		}
		entry.Presentations = append(entry.Presentations, model.ThreadPresentation{ID: "mokusei.conversation", APIVersion: 1, SchemaVersion: 1, Value: raw})
	}
	return entry, nil
}
func (h *Host) Archive(ctx context.Context, ref model.ThreadRef, archived bool) error {
	if err := h.begin(); err != nil {
		return err
	}
	defer h.operations.Done()
	commandID := newCommandID()
	at := h.config.Now().UnixMilli()
	_, err := h.config.Store.Update(ctx, func(tx *store.Tx) error {
		definition, record, e := h.readThread(tx.Snapshot(), ref)
		if e != nil {
			return e
		}
		if definition.Archive == nil {
			return errors.New("thread cannot be archived")
		}
		if definition.Archive.Archived(record) == archived {
			return nil
		}
		change, e := definition.Archive.Change(record, archived)
		if e != nil {
			return e
		}
		related, e := definition.Archive.RelatedLatestExecutions(record, archived)
		if e != nil {
			return e
		}
		writer := newReader(h, definition.OwnerPluginID, tx.Snapshot())
		writer.tx = tx
		writer.committedAt = at
		writer.commandID = commandID
		writer.source = definition.OwnerPluginID
		_, e = writer.Put(definition.CollectionID, record.ID, change.Value, plugin.RecordWriteOptions{ExpectedRevision: &record.Revision, TouchUpdatedAt: change.TouchUpdatedAt})
		if e != nil {
			return e
		}
		if len(related) > 0 {
			if h.config.ArchiveExecutions == nil {
				return errors.New("related execution archival unavailable")
			}
			if e = h.config.ArchiveExecutions(tx, related, archived); e != nil {
				return e
			}
		}
		if e = writer.flushEvents(); e != nil {
			return e
		}
		eventType := "thread.restored"
		if archived {
			eventType = "thread.archived"
		}
		return tx.AppendEvent(store.Event{ID: stableID(commandID, eventType), CreatedAt: at, Type: eventType, Subject: store.Subject{Kind: "thread", ID: record.ID, TypeID: ref.TypeID}, Source: definition.OwnerPluginID, Data: json.RawMessage(`{}`)})
	})
	return err
}
func (h *Host) InitializeConversation(ctx context.Context, ref model.ThreadRef) error {
	if err := h.begin(); err != nil {
		return err
	}
	defer h.operations.Done()
	definition, record, err := h.readThread(h.config.Store.Snapshot(), ref)
	if err != nil {
		return err
	}
	if definition.Conversation == nil {
		return errors.New("thread has no conversation extension")
	}
	existing, err := definition.Conversation.ReadSession(record)
	if err != nil {
		return err
	}
	if existing != nil {
		return nil
	}
	configuration, err := definition.Conversation.InitialConfiguration(record)
	if err != nil {
		return err
	}
	if h.config.InitializeSession == nil {
		return errors.New("conversation initialization unavailable")
	}
	session, err := h.config.InitializeSession(ctx, ref, configuration)
	if err != nil {
		return err
	}
	if session.ID != ref.ThreadID || session.HarnessID == "" || session.Observation.LatestExecution != nil || session.Observation.BackgroundWork != nil {
		return errors.New("initializer returned an invalid initial session")
	}
	commandID := newCommandID()
	at := h.config.Now().UnixMilli()
	_, err = h.config.Store.Update(ctx, func(tx *store.Tx) error {
		_, current, e := h.readThread(tx.Snapshot(), ref)
		if e != nil {
			return e
		}
		if current.Revision != record.Revision {
			return errors.New("conversation source changed during initialization")
		}
		value, e := definition.Conversation.WithSession(current, session)
		if e != nil {
			return e
		}
		writer := newReader(h, definition.OwnerPluginID, tx.Snapshot())
		writer.tx = tx
		writer.committedAt = at
		writer.commandID = commandID
		writer.source = definition.OwnerPluginID
		writer.allowSessionWrite = true
		_, e = writer.Put(definition.CollectionID, current.ID, value, plugin.RecordWriteOptions{ExpectedRevision: &current.Revision, TouchUpdatedAt: true})
		if e != nil {
			return e
		}
		return writer.flushEvents()
	})
	return err
}

func (h *Host) ReadThreadTags(snap store.Snapshot, ref model.ThreadRef) (model.TagProjection, error) {
	definition, record, err := h.readThread(snap, ref)
	if err != nil {
		return model.TagProjection{}, err
	}
	if definition.Tags == nil {
		return model.TagProjection{Tags: []string{}, TagEmojis: map[string]string{}, SemanticTags: []string{}, DirectoryTags: []string{}}, nil
	}
	return definition.Tags.Project(record)
}

// ApplySemanticTags joins the caller's existing transaction so ordinary and
// application projections, redirects and lifecycle facts are published together.
func (h *Host) ApplySemanticTags(tx *store.Tx, effect plugin.SemanticTagEffect) error {
	commandID := newCommandID()
	at := h.config.Now().UnixMilli()
	for _, id := range sortedKeys(h.threadTypes) {
		definition := h.threadTypes[id]
		if !h.enabled(definition.OwnerPluginID) {
			continue
		}
		if definition.Tags == nil {
			continue
		}
		writer := newReader(h, definition.OwnerPluginID, tx.Snapshot())
		writer.tx = tx
		writer.committedAt = at
		writer.commandID = commandID
		writer.source = "tag.agent"
		records, err := writer.List(definition.CollectionID)
		if err != nil {
			return err
		}
		for _, record := range records {
			thread := model.ApplicationThreadRecord{VersionedRecord: record, Ref: model.ThreadRef{ThreadID: record.ID, TypeID: id}}
			change, err := definition.Tags.Apply(thread, effect)
			if err != nil {
				return err
			}
			before, err := model.Decode(record.Value)
			if err != nil {
				return err
			}
			after, err := model.Decode(change.Value)
			if err != nil {
				return err
			}
			left, _ := json.Marshal(before)
			right, _ := json.Marshal(after)
			if string(left) == string(right) {
				continue
			}
			if _, err = writer.Put(definition.CollectionID, record.ID, change.Value, plugin.RecordWriteOptions{ExpectedRevision: &record.Revision, TouchUpdatedAt: change.TouchUpdatedAt}); err != nil {
				return err
			}
		}
		if err = writer.flushEvents(); err != nil {
			return err
		}
	}
	return nil
}
func (h *Host) ClassificationList(snap store.Snapshot, includeArchived bool) ([]plugin.ClassificationThreadSnapshot, error) {
	result := []plugin.ClassificationThreadSnapshot{}
	for _, id := range sortedKeys(h.threadTypes) {
		definition := h.threadTypes[id]
		if !h.enabled(definition.OwnerPluginID) {
			continue
		}
		if definition.Classification == nil {
			continue
		}
		reader := newReader(h, definition.OwnerPluginID, snap)
		records, err := reader.List(definition.CollectionID)
		if err != nil {
			return nil, err
		}
		for _, record := range records {
			thread := model.ApplicationThreadRecord{VersionedRecord: record, Ref: model.ThreadRef{ThreadID: record.ID, TypeID: id}}
			item, _, err := h.classification(definition, thread)
			if err != nil {
				return nil, err
			}
			if includeArchived || !item.Archived {
				result = append(result, item)
			}
		}
	}
	return result, nil
}
func (h *Host) ClassificationEvidence(snap store.Snapshot, ref model.ThreadRef) (plugin.ClassificationEvidenceSnapshot, error) {
	definition, record, err := h.readThread(snap, ref)
	if err != nil {
		return plugin.ClassificationEvidenceSnapshot{}, err
	}
	item, evidence, err := h.classification(definition, record)
	return plugin.ClassificationEvidenceSnapshot{Thread: item, Content: evidence.Content}, err
}
func (h *Host) classification(definition plugin.ThreadTypeDefinition, record model.ApplicationThreadRecord) (plugin.ClassificationThreadSnapshot, plugin.ClassificationEvidence, error) {
	var result plugin.ClassificationThreadSnapshot
	if definition.Classification == nil {
		return result, plugin.ClassificationEvidence{}, errors.New("thread classification unavailable")
	}
	projection, err := definition.Project(record)
	if err != nil {
		return result, plugin.ClassificationEvidence{}, err
	}
	tags, err := definition.Tags.Project(record)
	if err != nil {
		return result, plugin.ClassificationEvidence{}, err
	}
	evidence, err := definition.Classification.Evidence(record)
	if err != nil {
		return result, evidence, err
	}
	if evidence.Revision == "" || model.UTF16Length(evidence.Revision) > 256 || model.UTF16Length(evidence.Content) > 32000 {
		return result, evidence, errors.New("classification evidence exceeds contract")
	}
	archived := definition.Archive != nil && definition.Archive.Archived(record)
	return plugin.ClassificationThreadSnapshot{Ref: record.Ref, Title: projection.Title, Archived: archived, Tags: tags, EvidenceRevision: evidence.Revision}, evidence, nil
}
