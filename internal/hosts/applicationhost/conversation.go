package applicationhost

import (
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// ReadConversation reads a single immutable aggregate snapshot. It never opens
// native resources and only exposes owner-opted-in application thread types.
func (h *Host) ReadConversation(snapshot store.Snapshot, id string) (model.SessionRecord, model.ThreadRef, bool, error) {
	for _, typeID := range sortedKeys(h.threadTypes) {
		definition := h.threadTypes[typeID]
		if !h.enabled(definition.OwnerPluginID) || definition.Conversation == nil {
			continue
		}
		var record model.VersionedRecord
		exists, err := snapshot.Get(recordKey(definition.CollectionID, id), &record)
		if err != nil {
			return model.SessionRecord{}, model.ThreadRef{}, false, err
		}
		if !exists {
			continue
		}
		ref := model.ThreadRef{ThreadID: id, TypeID: typeID}
		session, err := definition.Conversation.ReadSession(model.ApplicationThreadRecord{VersionedRecord: record, Ref: ref})
		if err != nil {
			return model.SessionRecord{}, ref, false, err
		}
		if session == nil {
			return model.SessionRecord{}, ref, false, nil
		}
		if session.ID != id {
			return model.SessionRecord{}, ref, false, errors.New("application conversation identity mismatch")
		}
		return *session, ref, true, nil
	}
	return model.SessionRecord{}, model.ThreadRef{}, false, nil
}

// CommitConversation accepts only a host-authorized successor revision for the
// same session. The owning extension embeds it without changing business data.
// Caller appends execution/background lifecycle facts in this same transaction.
func (h *Host) CommitConversation(tx *store.Tx, ref model.ThreadRef, session model.SessionRecord) error {
	definition, record, err := h.readThread(tx.Snapshot(), ref)
	if err != nil {
		return err
	}
	if definition.Conversation == nil {
		return errors.New("application conversation unavailable")
	}
	previous, err := definition.Conversation.ReadSession(record)
	if err != nil {
		return err
	}
	if previous == nil {
		return errors.New("application conversation is not initialized")
	}
	if session.ID != ref.ThreadID || session.HarnessID != previous.HarnessID || session.Revision != previous.Revision+1 {
		return errors.New("application conversation revision or identity conflict")
	}
	if err = model.ValidatePublicObservation(session.Observation); err != nil {
		return err
	}
	value, err := definition.Conversation.WithSession(record, session)
	if err != nil {
		return err
	}
	writer := newReader(h, definition.OwnerPluginID, tx.Snapshot())
	writer.tx = tx
	writer.committedAt = h.config.Now().UnixMilli()
	writer.commandID = newCommandID()
	writer.source = definition.OwnerPluginID
	writer.allowSessionWrite = true
	if _, err = writer.Put(definition.CollectionID, record.ID, value, plugin.RecordWriteOptions{ExpectedRevision: &record.Revision, TouchUpdatedAt: true}); err != nil {
		return err
	}
	return writer.flushEvents()
}
