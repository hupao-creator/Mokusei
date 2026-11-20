package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/hupao-creator/Chief/internal/core/model"
	"github.com/hupao-creator/Chief/internal/core/plugin"
	"github.com/hupao-creator/Chief/internal/core/store"
	"time"
)

func (r *Runtime) InitializeApplicationSession(ctx context.Context, ref model.ThreadRef, configuration plugin.ConversationConfiguration) (model.SessionRecord, error) {
	cwd, err := validateCwd(configuration.Cwd)
	if err != nil {
		return model.SessionRecord{}, err
	}
	id, err := r.ResolveHost(ctx, configuration.HarnessPreference, configuration.Harnesses, cwd)
	if err != nil {
		return model.SessionRecord{}, err
	}
	h := r.config.Harnesses[id]
	merged := configuration.Harnesses[id]
	if len(merged) == 0 {
		merged = h.DefaultSettings()
	}
	defaults, err := h.Settings().DefaultThread(merged)
	if err != nil {
		return model.SessionRecord{}, err
	}
	settings, err := h.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: defaults, Cwd: cwd})
	if err != nil {
		return model.SessionRecord{}, err
	}
	now := time.Now().UnixMilli()
	return model.SessionRecord{ID: ref.ThreadID, HarnessID: id, SessionState: json.RawMessage("null"), Settings: settings, Cwd: cwd, CreatedAt: now, UpdatedAt: now}, nil
}
func (r *Runtime) ProjectSession(ctx context.Context, session model.SessionRecord) (model.SessionRecord, error) {
	if err := ctx.Err(); err != nil {
		return session, err
	}
	h := r.config.Harnesses[session.HarnessID]
	if h == nil {
		return session, errors.New("unknown session harness")
	}
	value, err := h.SessionState().ProjectRenderer(session.SessionState, model.RendererScope{Kind: "overview"})
	if err != nil {
		return session, err
	}
	session.SessionState = value
	return session, nil
}
func (r *Runtime) ArchiveThreads(tx *store.Tx, references []model.ThreadRef, value bool) error {
	seen := make(map[string]bool, len(references))
	for _, ref := range references {
		if ref.TypeID != "agent" {
			return errors.New("archive propagation only supports ordinary agent tasks")
		}
		if seen[ref.ThreadID] {
			continue
		}
		seen[ref.ThreadID] = true
		var thread model.ThreadRecord
		exists, err := tx.Get("thread:"+ref.ThreadID, &thread)
		if err != nil {
			return err
		}
		// Reports retain references after source deletion; there is nothing to hide.
		if !exists {
			continue
		}
		if thread.Moku || thread.MokuHistory {
			return errors.New("archive propagation only supports ordinary agent tasks")
		}
		if archived(&thread) == value {
			continue
		}
		before := thread
		thread.Archived = &value
		thread.Revision++
		thread.UpdatedAt = max(thread.UpdatedAt, time.Now().UnixMilli())
		if err := tx.Put("thread:"+thread.ID, thread); err != nil {
			return err
		}
		if err := r.threadEvents(tx, &before, &thread); err != nil {
			return err
		}
	}
	return nil
}
