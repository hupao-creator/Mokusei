package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

const cardCount = 40
const activeCount = 4
const sourceInterval = 25 * time.Millisecond

// This public, synthetic source is deliberately independent of user rollouts.
const publicText = "Build the overview incrementally. Keep thread identity stable while messages change. Measure the foreground window with four visible running cards. Preserve the full update sequence and compare the final text. A narrow update should reuse geometry. Record the source deadline, committed revision, and publication boundary separately. "

type cardExpectation struct {
	ID         string `json:"id"`
	Seq        int64  `json:"seq"`
	Revision   int64  `json:"revision"`
	MessageID  string `json:"messageID"`
	ItemID     string `json:"itemID"`
	TextSHA256 string `json:"textSHA256"`
	TextLength int    `json:"textLength"`
}

func initialText() string { return "Overview CI append: " }

func messageText(condition string, seed int64, card, sequence int) string {
	if sequence < 0 || condition == "R0" {
		return initialText()
	}
	if condition == "S4" {
		offset := (sequence*13 + card*17 + int(seed%int64(len(publicText)))) % len(publicText)
		return strings.Repeat(publicText, 2)[offset : offset+240]
	}
	words := []string{"oak ", "elm ", "fir ", "ash "}
	var text strings.Builder
	text.WriteString(initialText())
	for index := 0; index <= sequence; index++ {
		text.WriteString(words[(index+card+int(seed%4))%len(words)])
	}
	return text.String()
}

func executionID(card int) string { return fmt.Sprintf("ci-execution-card-%d", card) }
func itemID(card int) string      { return fmt.Sprintf("ci-message-card-%d", card) }

func makeState(card int, text string, at int64) (codex.Map, error) {
	state, err := codex.StageExecutionChecked(codex.EmptyState(at), executionID(card), codex.Map{
		"parts": []any{codex.Map{"kind": "text", "text": "Inspect the public Overview performance fixture."}},
	}, at, nil)
	if err != nil {
		return nil, err
	}
	state = codex.ReduceEvent(state, executionID(card), codex.Map{
		"type": "text-final", "itemId": itemID(card), "text": text, "at": at + 1,
	})
	if card < activeCount {
		// A live derived agent is what the production Codex Overview projects
		// into the second card slot and its scan, not running status alone.
		state = codex.ReduceEvent(state, executionID(card), codex.Map{
			"type": "activity-start", "at": at + 2,
			"activity": codex.Map{"id": fmt.Sprintf("ci-derived-card-%d", card), "kind": "subagent", "label": "Inspect overview"},
		})
	} else {
		state = codex.SettleExecution(state, executionID(card), "completed", at+2, "")
	}
	if _, err := codex.DecodeState(state); err != nil {
		return nil, fmt.Errorf("seed card %d: %w", card, err)
	}
	return state, nil
}

func encodeState(record *model.ThreadRecord, state codex.Map, adapter plugin.SessionStateAdapter) error {
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	observation, err := adapter.Project(raw)
	if err != nil {
		return err
	}
	record.SessionState, record.Observation = raw, observation
	return nil
}

func seedStore(ctx context.Context, db *store.Store, cwd string, adapter *codex.Adapter) ([]model.ThreadRecord, error) {
	records := make([]model.ThreadRecord, cardCount)
	at := time.Now().Add(-time.Second).UnixMilli()
	settings := json.RawMessage(`{"useDefaultThreadSettings":false,"threadSettings":{"model":"overview-ci-fixture","thinking":{"mode":"off"},"serviceTier":"default"}}`)
	threadSettings, err := adapter.Settings().DefaultThread(settings)
	if err != nil {
		return nil, err
	}
	for index := range records {
		state, err := makeState(index, initialText(), at+int64(index))
		if err != nil {
			return nil, err
		}
		archived := false
		record := model.ThreadRecord{SessionRecord: model.SessionRecord{
			ID: fmt.Sprintf("card-%d", index), HarnessID: "codex", Revision: 0,
			Cwd: cwd, Settings: threadSettings, CreatedAt: at + int64(index), UpdatedAt: at + int64(index) + 3,
		}, Title: fmt.Sprintf("Overview CI thread %02d", index), Tags: []string{}, TagEmojis: map[string]string{}, Archived: &archived}
		if err := encodeState(&record, state, adapter.SessionState()); err != nil {
			return nil, err
		}
		records[index] = record
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		global := model.DefaultSettings([]string{"codex"})
		global.Harnesses["codex"] = settings
		global.Moku.HostHarnessPreference = "codex"
		global.Moku.ExecutionHarnesses["codex"] = settings
		if err := tx.Put("settings", global); err != nil {
			return err
		}
		if err := tx.Put("settings-revision", int64(0)); err != nil {
			return err
		}
		ids := make([]string, 0, len(records))
		for _, record := range records {
			if err := tx.Put("thread:"+record.ID, record); err != nil {
				return err
			}
			ids = append(ids, record.ID)
		}
		return tx.SetOrder("threads", ids)
	})
	return records, err
}

func expectedCard(record model.ThreadRecord, adapter plugin.SessionStateAdapter) (cardExpectation, error) {
	projection, err := adapter.ProjectRenderer(record.SessionState, model.RendererScope{Kind: "overview"})
	if err != nil {
		return cardExpectation{}, err
	}
	var state struct {
		Turns []struct {
			Timeline []struct {
				ID      string `json:"id"`
				ItemID  string `json:"itemId"`
				Kind    string `json:"kind"`
				Content string `json:"content"`
			} `json:"timeline"`
		} `json:"turns"`
	}
	if err := json.Unmarshal(projection, &state); err != nil {
		return cardExpectation{}, err
	}
	for _, turn := range state.Turns {
		for _, item := range turn.Timeline {
			if item.Kind == "assistant" {
				hash := sha256.Sum256([]byte(item.Content))
				return cardExpectation{ID: record.ID, Seq: record.Revision - 1, Revision: record.Revision,
					MessageID: item.ID, ItemID: item.ItemID, TextSHA256: hex.EncodeToString(hash[:]),
					TextLength: len([]rune(item.Content))}, nil
			}
		}
	}
	return cardExpectation{}, fmt.Errorf("public overview projection for %s has no assistant message", record.ID)
}

func updateRecord(record model.ThreadRecord, condition string, seed int64, card, sequence int, at int64,
	adapter plugin.SessionStateAdapter) (model.ThreadRecord, error) {
	var state codex.Map
	if err := json.Unmarshal(record.SessionState, &state); err != nil {
		return record, err
	}
	// The production reducer owns item identity and public projection semantics.
	// A4 is cumulative message replacement, not a claim about provider text-delta.
	state = codex.ReduceEvent(state, executionID(card), codex.Map{
		"type": "text-final", "itemId": itemID(card), "text": messageText(condition, seed, card, sequence), "at": at,
	})
	record.Revision = int64(sequence + 1)
	// Stable recency isolates content updates from ordering/structural changes.
	err := encodeState(&record, state, adapter)
	return record, err
}
