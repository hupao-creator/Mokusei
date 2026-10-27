package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"time"
)

// A process crash cannot leave transient Moku transcript items permanently
// streaming. Native execution recovery remains owned by the selected adapter.
func (r *Runtime) settleStaleMokuTranscript(ctx context.Context) error {
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		for _, key := range tx.Keys("thread:") {
			var thread model.ThreadRecord
			ok, err := tx.Get(key, &thread)
			if err != nil {
				return err
			}
			if !ok {
				continue
			}
			changed := thread.PendingInput
			thread.PendingInput = false
			at := max(time.Now().UnixMilli(), thread.UpdatedAt)
			for i, raw := range thread.Transcript {
				var item map[string]any
				if err := json.Unmarshal(raw, &item); err != nil {
					return fmt.Errorf("invalid Moku transcript: %w", err)
				}
				dirty := false
				if item["type"] == "message" && item["role"] == "assistant" && item["status"] == "streaming" {
					item["status"] = "cancelled"
					delete(item, "statusLabel")
					dirty = true
				}
				if item["type"] == "tool-operation" {
					if _, complete := item["completedAt"]; !complete {
						item["result"] = map[string]any{"error": "Moku runtime restarted before the tool completed"}
						item["isError"] = true
						item["completedAt"] = at
						dirty = true
					}
				}
				if dirty {
					encoded, err := json.Marshal(item)
					if err != nil {
						return err
					}
					thread.Transcript[i] = encoded
					changed = true
				}
			}
			if changed {
				thread.Revision++
				thread.UpdatedAt = at
				if err := tx.Put(key, thread); err != nil {
					return err
				}
			}
		}
		for _, key := range tx.Keys("private-session:") {
			var session plugin.PrivateSessionSnapshot
			if _, err := tx.Get(key, &session); err != nil {
				return err
			}
			if session.Record.PendingInput {
				session.Record.PendingInput = false
				session.Record.Revision++
				session.Record.UpdatedAt = max(time.Now().UnixMilli(), session.Record.UpdatedAt)
				if err := tx.Put(key, session); err != nil {
					return err
				}
			}
		}
		return nil
	})
	return err
}
