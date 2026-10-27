package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// exportNativeNoteRecords writes real Thread records produced by the production
// Coordinator tool binding, for the native note replay. It is a no-op unless the
// fixture path is requested.
func exportNativeNoteRecords() error {
	path := os.Getenv("MOKU_NOTE_NATIVE_FIXTURE")
	if path == "" {
		return nil
	}
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("coordinate the milestone note")))
	texts := []string{
		"# Milestones\n\n- Dispatched the schema migration\n- Waiting for review",
		"# Milestones\n\n- Schema migration merged\n- Review scheduled",
		"",
	}
	records := []model.ThreadRecord{}
	for _, text := range texts {
		result, err := w.call("update_note", noteArgs(text, w.mokuRecord().Note))
		mokuReplayMust(err)
		if !noteResult(result).OK {
			return fmt.Errorf("update_note fixture returned %s", result)
		}
		records = append(records, w.mokuRecord())
	}
	raw, err := json.MarshalIndent(map[string]any{
		"source":  "production Coordinator update_note audit records",
		"records": records,
		"texts":   texts,
	}, "", "  ")
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if err = os.WriteFile(path, raw, 0o600); err != nil {
		return err
	}
	fmt.Println("PASS exported real update_note records for the native note replay")
	return nil
}
