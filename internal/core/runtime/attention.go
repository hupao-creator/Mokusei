package runtime

import (
	"context"
	"errors"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadattention"
)

const attentionPrefix = "attention-thread:"
const attentionHiddenPrefix = "attention-hidden:"

type attentionVisit struct {
	CompletedExecution string `json:"completedExecution"`
	AlreadyVisible     bool   `json:"alreadyVisible"`
	ThreadID           string `json:"threadId"`
	VisitID            string `json:"visitId"`
	Elapsed            int64  `json:"elapsed"`
	Foreground         bool   `json:"foreground"`
	SearchOpen         bool   `json:"searchOpen"`
}

func trackAttentionExecution(tx *store.Tx, id string, thread *model.ThreadRecord) error {
	if thread == nil {
		if err := tx.Delete(attentionHiddenPrefix + id); err != nil {
			return err
		}
		return tx.Delete(attentionPrefix + id)
	}
	e := thread.Observation.LatestExecution
	if e == nil {
		return nil
	}
	var s threadattention.Thread
	if _, err := tx.Get(attentionPrefix+id, &s); err != nil {
		return err
	}
	revision := s.Revision
	if s.LatestExecution != e.ExecutionID {
		s.Start(e.ExecutionID)
		if err := tx.Delete(attentionHiddenPrefix + id); err != nil {
			return err
		}
	}
	if e.Status == "completed" && e.FinishedAt != nil {
		s.Complete(e.ExecutionID, *e.FinishedAt, false)
	}
	if revision == s.Revision {
		return nil
	}
	return tx.Put(attentionPrefix+id, s)
}

func (r *Runtime) recordAttentionVisit(ctx context.Context, v attentionVisit) error {
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var t model.ThreadRecord
		ok, err := tx.Get("thread:"+v.ThreadID, &t)
		if err != nil {
			return err
		}
		if !ok || t.Moku || t.MokuHistory {
			return errors.New("unknown ordinary thread")
		}
		if err := trackAttentionExecution(tx, t.ID, &t); err != nil {
			return err
		}
		var s threadattention.Thread
		if _, err := tx.Get(attentionPrefix+t.ID, &s); err != nil {
			return err
		}
		wasHidden := s.Hidden
		oldRead := s.FirstReadAt
		now := time.Now().UnixMilli()
		readAt := now
		foreground := v.Foreground && v.CompletedExecution != "" && v.CompletedExecution == s.LatestExecution
		if foreground && v.AlreadyVisible && s.LastCompletedAt > 0 {
			readAt = s.LastCompletedAt
		}
		s.ObserveVisit(v.VisitID, now, v.Elapsed, readAt, foreground, v.SearchOpen)
		if !s.Hidden && tx.Has(attentionHiddenPrefix+t.ID) {
			if err := tx.Delete(attentionHiddenPrefix + t.ID); err != nil {
				return err
			}
		}
		if wasHidden != s.Hidden || oldRead != s.FirstReadAt {
			if err := attentionChanged(tx, attentionEligible(t) && !wasHidden, attentionEligible(t) && !s.Hidden); err != nil {
				return err
			}
		}
		return tx.Put(attentionPrefix+t.ID, s)
	})
	return err
}
