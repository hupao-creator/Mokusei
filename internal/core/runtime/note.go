package runtime

import (
	"context"
	"errors"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func currentMokuNoteThread(tx *store.Tx) (model.ThreadRecord, bool, error) {
	for _, key := range tx.Keys("thread:") {
		var thread model.ThreadRecord
		found, err := tx.Get(key, &thread)
		if err != nil {
			return thread, false, err
		}
		if found && thread.Moku {
			return thread, true, nil
		}
	}
	return model.ThreadRecord{}, false, nil
}

// UpdateMokuNote compares the evidence and content basis inside the writer
// transaction. The owner ID fences a retired tool even after history reset.
func (r *Runtime) UpdateMokuNote(ctx context.Context, ownerID, text string, expected *model.NoteBasis) (model.NoteUpdateResult, error) {
	var result model.NoteUpdateResult
	var committed *model.ThreadRecord
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		thread, found, err := currentMokuNoteThread(tx)
		if err != nil {
			return err
		}
		if !found || thread.ID != ownerID {
			return errors.New("Moku note owner was replaced")
		}
		result.State = model.SnapshotNote(thread.Note)
		if !sameNoteBasis(result.State.Basis, expected) {
			result.Code = "note_state_changed"
			return nil
		}
		if thread.Revision >= model.MaximumSafeInteger {
			return errors.New("thread revision exhausted")
		}
		at := time.Now().UnixMilli()
		if thread.Note == nil {
			id, err := newID()
			if err != nil {
				return err
			}
			thread.Note = &model.ThreadNote{ID: id, Text: text, Revision: 1, UpdatedAt: at}
		} else {
			if thread.Note.Revision >= model.MaximumSafeInteger {
				return errors.New("note revision exhausted")
			}
			note := *thread.Note
			note.Revision++
			note.Text = text
			note.UpdatedAt = at
			if text == "" && note.LastExposure != nil {
				if note.ReadingRevision >= model.MaximumSafeInteger {
					return errors.New("note reading revision exhausted")
				}
				note.LastExposure = nil
				note.ReadingRevision++
			}
			thread.Note = &note
		}
		thread.Revision++
		thread.UpdatedAt = max(at, thread.UpdatedAt)
		if err := tx.Put("thread:"+thread.ID, thread); err != nil {
			return err
		}
		result.OK = true
		result.State = model.SnapshotNote(thread.Note)
		copy := thread
		committed = &copy
		return nil
	})
	if err == nil && committed != nil {
		r.notifyThread(*committed)
	}
	return result, err
}

func sameNoteBasis(a, b *model.NoteBasis) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

type NoteExposureReceipt struct {
	NoteID   string `json:"noteId"`
	Revision int64  `json:"revision"`
	Signal   string `json:"signal"`
}

type NoteExposureResult struct {
	Status string `json:"status"`
}

// RecordNoteExposure only accepts the current nonempty incarnation/version.
// Duplicate and stale receipts are true store no-ops and wake no participant.
func (r *Runtime) RecordNoteExposure(ctx context.Context, receipt NoteExposureReceipt) (NoteExposureResult, error) {
	result := NoteExposureResult{Status: "stale"}
	var committed *model.ThreadRecord
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		thread, found, err := currentMokuNoteThread(tx)
		if err != nil {
			return err
		}
		if !found || thread.Note == nil || thread.Note.Text == "" || thread.Note.ID != receipt.NoteID {
			return nil
		}
		note := thread.Note
		if receipt.Revision < note.Revision {
			return nil
		}
		if receipt.Revision > note.Revision {
			return errors.New("note exposure revision is in the future")
		}
		if note.LastExposure != nil && note.LastExposure.Revision == receipt.Revision {
			result.Status = "duplicate"
			return nil
		}
		if note.ReadingRevision >= model.MaximumSafeInteger || thread.Revision >= model.MaximumSafeInteger {
			return errors.New("note revision exhausted")
		}
		at := time.Now().UnixMilli()
		copy := *note
		copy.ReadingRevision++
		copy.LastExposure = &model.NoteExposure{Revision: copy.Revision, Text: copy.Text, RecordedAt: at, Signal: model.NoteExposureSignal}
		thread.Note = &copy
		thread.Revision++
		thread.UpdatedAt = max(at, thread.UpdatedAt)
		if err := tx.Put("thread:"+thread.ID, thread); err != nil {
			return err
		}
		result.Status = "accepted"
		committed = &thread
		return nil
	})
	if err == nil && committed != nil {
		r.notifyThread(*committed)
	}
	return result, err
}
