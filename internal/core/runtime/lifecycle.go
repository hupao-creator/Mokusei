package runtime

import (
	"encoding/json"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

func (r *Runtime) appendEvent(tx *store.Tx, kind string, subject store.Subject, source string, data any, introduced []string) error {
	id, err := newID()
	if err != nil {
		return err
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return err
	}
	scope := ""
	if subject.Kind == "thread" && subject.TypeID == "agent" && subject.ID != "" {
		var thread model.ThreadRecord
		if ok, e := tx.Get("thread:"+subject.ID, &thread); e == nil && ok && !thread.Moku {
			scope = directorytag.Scope(thread.Cwd)
		}
	}
	return tx.AppendEvent(store.Event{ID: id, CreatedAt: time.Now().UnixMilli(), Type: kind, Subject: subject, Scope: scope, Source: source, Data: raw, IntroducedInteractionIDs: introduced})
}
func (r *Runtime) threadEvents(tx *store.Tx, old *model.ThreadRecord, next *model.ThreadRecord) error {
	record := next
	if record == nil {
		record = old
	}
	if record == nil {
		return nil
	}
	if !record.Moku {
		if err := rememberDirectoryScope(tx, *record); err != nil {
			return err
		}
	}
	if next == nil || (!next.Moku && !searchVisible(*next)) {
		if err := threadsearch.DeleteOwner(tx, "thread:"+record.ID); err != nil {
			return err
		}
	}
	typeID := "agent"
	if record.Moku {
		typeID = "moku"
	}
	subject := store.Subject{Kind: "thread", ID: record.ID, TypeID: typeID}
	emit := func(kind string, data any) error { return r.appendEvent(tx, kind, subject, "application", data, nil) }
	if next == nil {
		for _, key := range tx.Keys(mokuDeliveryPrefix + record.ID + ":") {
			if err := tx.Delete(key); err != nil {
				return err
			}
		}
		return emit("entity.deleted", map[string]any{"observation": old.Observation})
	}
	if old == nil {
		if err := emit("entity.created", map[string]any{"harnessId": next.HarnessID}); err != nil {
			return err
		}
	} else {
		if old.Title != next.Title || !same(old.Tags, next.Tags) || !same(old.TagEmojis, next.TagEmojis) || !same(old.Settings, next.Settings) {
			if err := emit("entity.updated", map[string]any{"harnessId": next.HarnessID, "title": next.Title, "tags": next.Tags, "tagEmojis": next.TagEmojis}); err != nil {
				return err
			}
		}
		if archived(old) != archived(next) {
			kind := "thread.restored"
			if archived(next) {
				kind = "thread.archived"
			}
			if err := emit(kind, map[string]any{}); err != nil {
				return err
			}
		}
	}
	var before *model.PublicExecution
	if old != nil {
		before = old.Observation.LatestExecution
	}
	after := next.Observation.LatestExecution
	if after != nil && (before == nil || before.ExecutionID != after.ExecutionID || before.Status != after.Status || (after.Status == "waiting-for-user" && !same(before, after))) {
		introduced := []string{}
		if after.Status == "waiting-for-user" {
			for _, interaction := range after.Interactions {
				present := false
				if before != nil && before.ExecutionID == after.ExecutionID && before.Status == "waiting-for-user" {
					for _, previous := range before.Interactions {
						if same(interaction, previous) {
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
		if !next.Moku && after.Terminal() {
			if err := queueMokuDelivery(tx, *next); err != nil {
				return err
			}
		}
		if err := r.appendEvent(tx, "execution."+after.Status, subject, "application", after, introduced); err != nil {
			return err
		}
	}
	var previousBackground *model.PublicBackgroundWork
	if old != nil {
		previousBackground = old.Observation.BackgroundWork
	}
	if !same(previousBackground, next.Observation.BackgroundWork) {
		kind := "background.finished"
		if next.Observation.BackgroundWork != nil {
			kind = "background.started"
		}
		if err := emit(kind, next.Observation); err != nil {
			return err
		}
	}
	return nil
}
func archived(t *model.ThreadRecord) bool { return t != nil && t.Archived != nil && *t.Archived }
