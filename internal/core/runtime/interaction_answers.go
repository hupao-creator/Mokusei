package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// Claim before native I/O, not after its acknowledgement: a lost response must
// not permit another client to apply an answer a second time. Command receipts
// reconcile the original attempt; a later fresh command is already handled.
func (r *Runtime) claimInteractionAnswer(ctx context.Context, id, executionID, interactionID string) error {
	identity, _ := json.Marshal([]string{executionID, interactionID})
	digest := sha256.Sum256(identity)
	key := "interaction-answer:" + id + ":" + hex.EncodeToString(digest[:])
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var thread model.ThreadRecord
		ok, err := tx.Get("thread:"+id, &thread)
		if err != nil {
			return err
		}
		if !ok || tx.Has(key) {
			return model.NewError("INTERACTION_STALE", "This interaction has already been handled or is no longer pending")
		}
		execution := thread.Observation.LatestExecution
		if execution == nil || execution.ExecutionID != executionID || execution.Status != "waiting-for-user" {
			return model.NewError("INTERACTION_STALE", "This interaction has already been handled or is no longer pending")
		}
		for _, interaction := range execution.Interactions {
			if interaction.ID == interactionID {
				return tx.Put(key, true)
			}
		}
		return model.NewError("INTERACTION_STALE", "This interaction has already been handled or is no longer pending")
	})
	return err
}
