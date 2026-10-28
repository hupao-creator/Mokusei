package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
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
func (r *Runtime) ArchiveExecutions(tx *store.Tx, references []model.ExecutionRef, value bool) error {
	for _, ref := range references {
		if ref.Thread.TypeID != "agent" {
			return errors.New("archive propagation only supports ordinary agent tasks")
		}
		var thread model.ThreadRecord
		exists, err := tx.Get("thread:"+ref.Thread.ThreadID, &thread)
		if err != nil {
			return err
		}
		if !exists || thread.Moku || thread.MokuHistory {
			continue
		}
		execution := thread.Observation.LatestExecution
		if execution == nil || execution.ExecutionID != ref.ExecutionID {
			continue
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
