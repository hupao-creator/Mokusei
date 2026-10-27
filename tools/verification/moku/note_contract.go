package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	runtimepkg "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

func runNoteSchemaReplay() error {
	for _, binding := range moku.ToolSchemas(moku.ThreadCreationDescription{}) {
		if binding.Name != "update_note" {
			continue
		}
		var definition map[string]any
		mokuReplayMust(json.Unmarshal(binding.InputSchema, &definition))
		properties, ok := definition["properties"].(map[string]any)
		mokuReplayCheck(ok && len(properties) == 2, "update_note schema must expose text and expected")
		text, ok := properties["text"].(map[string]any)
		mokuReplayCheck(ok, "update_note schema omitted text")
		_, patterned := text["pattern"]
		mokuReplayCheck(!patterned, "update_note text must not carry a pattern: constrained decoders may truncate at its first match")
		_, minimum := text["minLength"]
		mokuReplayCheck(!minimum, "update_note text must allow an empty string as the explicit clear")
		mokuReplayCheck(text["type"] == "string" && text["maxLength"] == float64(moku.NoteTextMaxCharacters), "update_note schema lost its code-point bound")
		mokuReplayCheck(definition["additionalProperties"] == false, "update_note schema accepts extra properties")
		required, _ := definition["required"].([]any)
		mokuReplayCheck(len(required) == 2, "update_note schema requires text and expected")
		mokuReplayCheck(strings.Contains(binding.Description, "persistent") && strings.Contains(binding.Description, "1200"), "update_note description omits its purpose or budget")
		mokuReplayCheck(strings.Contains(moku.DefaultSystemPrompt(), "update_note") && strings.Contains(moku.DefaultSystemPrompt(), "talk"), "Moku prompt does not distinguish the note from talk")

		compiler := jsonschema.NewCompiler()
		compiler.DefaultDraft(jsonschema.Draft7)
		compiler.UseRegexpEngine(func(pattern string) (jsonschema.Regexp, error) {
			r, err := regexp2.Compile(pattern, regexp2.ECMAScript)
			if err != nil {
				return nil, err
			}
			r.MatchTimeout = time.Second
			return creationReplayRegexp{r}, nil
		})
		mokuReplayMust(compiler.AddResource("urn:note", definition))
		schema, err := compiler.Compile("urn:note")
		mokuReplayMust(err)
		mokuReplayCheck(schema.Validate(map[string]any{"text": "", "expected": nil}) == nil, "update_note schema rejected the explicit clear")
		mokuReplayCheck(schema.Validate(map[string]any{"text": strings.Repeat("界", moku.NoteTextMaxCharacters), "expected": nil}) == nil, "update_note schema rejected exact-limit text")
		mokuReplayCheck(schema.Validate(map[string]any{"text": strings.Repeat("界", moku.NoteTextMaxCharacters+1), "expected": nil}) != nil, "update_note schema accepted over-limit text")
		mokuReplayCheck(schema.Validate(map[string]any{"text": "ok", "expected": nil, "extra": true}) != nil, "update_note schema accepted an extra property")
		mokuReplayCheck(schema.Validate(map[string]any{}) != nil, "update_note schema accepted a missing text")
		fmt.Println("PASS update_note schema has no pattern, allows the empty clear and keeps the 1200 code-point bound")
		return nil
	}
	return fmt.Errorf("missing update_note binding")
}

// runNoteOrchestratorReplay exercises the production tool binding, audit rows,
// monotonic revisions and the per-send context injection.
func runNoteOrchestratorReplay() {
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("coordinate the milestone note")))
	w.mu.Lock()
	initialContext := append([]plugin.ContextEntry(nil), w.sends[0].context...)
	w.mu.Unlock()
	mokuReplayCheck(noteContext(initialContext) == moku.MokuNoteContext(model.NoteState{}), "a send without a note did not receive null note state")

	first := "# Milestones\n- Dispatched the migration"
	result, err := w.call("update_note", string(mokuReplayRaw(map[string]any{"text": first, "expected": nil})))
	mokuReplayMust(err)
	mokuReplayCheck(noteResult(result).OK, "update_note did not return a committed state")
	record := w.mokuRecord()
	mokuReplayCheck(record.Note != nil && record.Note.Text == first, "update_note did not persist the exact text")
	mokuReplayCheck(record.Note.Revision == 1, "first note revision was not 1")
	mokuReplayCheck(record.Note.ID != "", "the first note has no incarnation identity")
	incarnation := record.Note.ID
	mokuReplayCheck(record.Note.UpdatedAt > 0, "note update timestamp was not recorded")
	mokuReplayCheck(noteAudit(record, "update_note", first), "successful update_note lacked a completed audit record")

	// Every outbound Moku input carries the note first, even after later turns.
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("continue")))
	w.mu.Lock()
	injected := append([]plugin.ContextEntry(nil), w.sends[len(w.sends)-1].context...)
	w.mu.Unlock()
	mokuReplayCheck(len(injected) > 0 && injected[0].ID == "moku-note", "note was not prepended to the next send")
	mokuReplayCheck(injected[0].Content == moku.MokuNoteContext(model.SnapshotNote(record.Note)), "note context did not carry the exact note state")

	second, err := w.call("update_note", noteArgs("# Milestones\n- Pending review", record.Note))
	mokuReplayMust(err)
	mokuReplayCheck(noteResult(second).OK, "second update_note failed")
	mokuReplayCheck(w.mokuRecord().Note.Revision == 2, "note revisions are not monotonic")
	mokuReplayCheck(w.mokuRecord().Note.ID == incarnation, "an in-place update changed the note incarnation")

	// Rejected calls leave the note unchanged but still leave an audit record.
	before := w.mokuRecord()
	audits := noteAuditCount(before)
	for name, arguments := range map[string]string{
		"over-budget":     `{"text":` + string(mokuReplayRaw(strings.Repeat("界", moku.NoteTextMaxCharacters+1))) + `,"expected":null}`,
		"whitespace-only": `{"text":" \n\t","expected":null}`,
		"nel-only":        `{"text":"\u0085","expected":null}`,
		"nul":             `{"text":"a\u0000b","expected":null}`,
		"extra-property":  `{"text":"ok","expected":null,"extra":true}`,
		"non-string":      `{"text":3,"expected":null}`,
	} {
		if _, err := w.call("update_note", arguments); err == nil {
			panic("update_note accepted " + name)
		}
		after := w.mokuRecord()
		mokuReplayCheck(after.Note != nil && after.Note.Text == before.Note.Text && after.Note.Revision == before.Note.Revision, name+" changed the note")
		mokuReplayCheck(noteAuditCount(after) == audits+1, name+" did not leave exactly one audit record")
		audits++
	}

	cleared, err := w.call("update_note", noteArgs("", w.mokuRecord().Note))
	mokuReplayMust(err)
	mokuReplayCheck(noteResult(cleared).OK, "clearing update_note failed")
	record = w.mokuRecord()
	mokuReplayCheck(record.Note != nil && record.Note.Text == "" && record.Note.Revision == 3, "clear did not store empty text with an incremented revision")
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("after clear")))
	w.mu.Lock()
	afterClear := append([]plugin.ContextEntry(nil), w.sends[len(w.sends)-1].context...)
	w.mu.Unlock()
	mokuReplayCheck(noteContext(afterClear) == moku.MokuNoteContext(model.SnapshotNote(record.Note)), "clear context lost the empty note basis")
	fmt.Println("PASS update_note persists, audits, rejects without changing the note, injects every send and clears")
}

func noteContext(entries []plugin.ContextEntry) string {
	for _, entry := range entries {
		if entry.ID == "moku-note" {
			return entry.Content
		}
	}
	return ""
}

func noteResult(raw json.RawMessage) model.NoteUpdateResult {
	var result model.NoteUpdateResult
	mokuReplayMust(json.Unmarshal(raw, &result))
	return result
}

func noteArgs(text string, note *model.ThreadNote) string {
	var expected *model.NoteBasis
	if note != nil {
		expected = model.SnapshotNote(note).Basis
	}
	return string(mokuReplayRaw(map[string]any{"text": text, "expected": expected}))
}

func noteAuditCount(record model.ThreadRecord) int {
	count := 0
	for _, raw := range record.Transcript {
		var item map[string]any
		if json.Unmarshal(raw, &item) == nil && item["type"] == "tool-operation" && item["name"] == "update_note" {
			count++
		}
	}
	return count
}

func noteAudit(record model.ThreadRecord, name, text string) bool {
	for _, raw := range record.Transcript {
		var item map[string]any
		if json.Unmarshal(raw, &item) != nil || item["type"] != "tool-operation" || item["name"] != name {
			continue
		}
		arguments, _ := item["arguments"].(map[string]any)
		_, completed := item["completedAt"]
		if completed && item["isError"] != true && arguments["text"] == text {
			return true
		}
	}
	return false
}

// runNoteRuntimeReplay checks the durable record, host replacement migration and
// history reset against the real SQLite store and runtime.
func runNoteRuntimeReplay() {
	root, e := os.MkdirTemp("", "mokusei-moku-note-")
	mokuReplayMust(e)
	defer os.RemoveAll(root)
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
	s := startReplaySystem(root, h)
	defer s.close()
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("materialize the Moku session")))
	h.awaitTools(1)
	old := s.record()

	h.mu.Lock()
	handle := h.handles[len(h.handles)-1]
	h.mu.Unlock()
	var updateNote func(string, *model.NoteBasis) (json.RawMessage, error)
	for _, binding := range handle.open.Injection.Tools.Bindings {
		if binding.Name == "update_note" {
			binding := binding
			updateNote = func(text string, expected *model.NoteBasis) (json.RawMessage, error) {
				return binding.Execute(mokuReplayContext(), plugin.ToolCall{CallID: "note-replay", Arguments: mokuReplayRaw(map[string]any{"text": text, "expected": expected})})
			}
		}
	}
	mokuReplayCheck(updateNote != nil, "update_note binding missing from the real runtime injection")
	_, e = updateNote("# Durable\n- Milestone recorded", nil)
	mokuReplayMust(e)

	stored, e := s.r.Thread(old.ID)
	mokuReplayMust(e)
	mokuReplayCheck(stored.Note != nil && stored.Note.Text == "# Durable\n- Milestone recorded" && stored.Note.Revision == 1, "SQLite did not retain the note")
	mokuReplayCheck(stored.Note.ID != "", "the first note has no incarnation identity")
	incarnation := stored.Note.ID
	requested := mokuReplayRaw(map[string]any{"noteId": incarnation, "revision": stored.Note.Revision, "signal": model.NoteExposureSignal})
	for _, invalid := range []json.RawMessage{
		mokuReplayRaw(map[string]any{"noteId": incarnation, "revision": 0, "signal": model.NoteExposureSignal}),
		mokuReplayRaw(map[string]any{"noteId": incarnation, "revision": stored.Note.Revision, "signal": "understood"}),
		mokuReplayRaw(map[string]any{"noteId": incarnation, "revision": stored.Note.Revision, "signal": model.NoteExposureSignal, "text": stored.Note.Text}),
	} {
		_, err := s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{invalid})
		mokuReplayCheck(err != nil, "invalid exposure command was accepted")
	}
	beforeReceipt := s.db.Snapshot().Revision()
	response, e := s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{requested})
	mokuReplayMust(e)
	mokuReplayCheck(response.(runtimepkg.NoteExposureResult).Status == "accepted", "current exposure was not accepted")
	exposed, e := s.r.Thread(old.ID)
	mokuReplayMust(e)
	mokuReplayCheck(exposed.Note.LastExposure != nil && exposed.Note.LastExposure.Text == stored.Note.Text && exposed.Note.LastExposure.Revision == 1 && exposed.Note.ReadingRevision == 1, "receipt lost exact server-owned content")
	mokuReplayCheck(exposed.Note.UpdatedAt == stored.Note.UpdatedAt && s.db.Snapshot().Revision() == beforeReceipt+1, "receipt changed content time or lacked one durable write")
	duplicateStoreRevision := s.db.Snapshot().Revision()
	response, e = s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{requested})
	mokuReplayMust(e)
	mokuReplayCheck(response.(runtimepkg.NoteExposureResult).Status == "duplicate" && s.db.Snapshot().Revision() == duplicateStoreRevision, "duplicate exposure was not a true no-op")
	changed, e := s.r.UpdateMokuNote(mokuReplayContext(), old.ID, "# Accidentally stale", model.SnapshotNote(stored.Note).Basis)
	mokuReplayMust(e)
	mokuReplayCheck(!changed.OK && changed.Code == "note_state_changed" && changed.State.LastExposure.Text == stored.Note.Text, "old reading basis overwrote the newly exposed note")
	changed, e = s.r.UpdateMokuNote(mokuReplayContext(), old.ID, "# Durable\n- Pending review", model.SnapshotNote(exposed.Note).Basis)
	mokuReplayMust(e)
	mokuReplayCheck(changed.OK && changed.State.Note.Revision == 2 && changed.State.LastExposure.Text == stored.Note.Text, "fresh basis did not preserve exact earlier exposure")
	response, e = s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{requested})
	mokuReplayMust(e)
	mokuReplayCheck(response.(runtimepkg.NoteExposureResult).Status == "stale" && s.db.Snapshot().Revision() == duplicateStoreRevision+1, "late old-version exposure changed current state")
	future := mokuReplayRaw(map[string]any{"noteId": incarnation, "revision": 3, "signal": model.NoteExposureSignal})
	_, e = s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{future})
	mokuReplayCheck(e != nil, "future note exposure was accepted")
	// The catalog publishes the whole Thread record; audit previews only touch
	// the transcript and must not strip or truncate this value.
	state, e := s.r.Snapshot()
	mokuReplayMust(e)
	published := false
	for _, thread := range state.Threads {
		if thread.ID == old.ID && thread.Note != nil && thread.Note.Text == changed.State.Note.Text && thread.Note.Revision == changed.State.Note.Revision && thread.Note.LastExposure != nil && thread.Note.LastExposure.Text == stored.Note.Text {
			published = true
		}
	}
	mokuReplayCheck(published, "the published catalog lost the note")

	configuration, e := s.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	configuration.PreserveNote = true
	replacement, e := s.r.ReplaceConfiguredMokuThread(mokuReplayContext(), old.ID, configuration)
	mokuReplayMust(e)
	mokuReplayCheck(replacement.ID != old.ID, "Moku host replacement did not create a new Thread")
	mokuReplayCheck(replacement.Note != nil && replacement.Note.Text == "# Durable\n- Pending review" && replacement.Note.Revision == 2, "host replacement did not copy the note")
	mokuReplayCheck(replacement.Note.ID == incarnation, "host replacement changed the note incarnation")
	mokuReplayCheck(replacement.Note.LastExposure != nil && replacement.Note.LastExposure.Text == stored.Note.Text && replacement.Note.ReadingRevision == 1, "host replacement lost the old text evidence")
	cleared, e := s.r.UpdateMokuNote(mokuReplayContext(), replacement.ID, "", model.SnapshotNote(replacement.Note).Basis)
	mokuReplayMust(e)
	mokuReplayCheck(cleared.OK && cleared.State.LastExposure == nil && cleared.State.Basis.ReadingRevision == 2 && cleared.State.Note.Revision == 3, "clear did not revoke prior exposure")
	response, e = s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{mokuReplayRaw(map[string]any{"noteId": incarnation, "revision": 3, "signal": model.NoteExposureSignal})})
	mokuReplayMust(e)
	mokuReplayCheck(response.(runtimepkg.NoteExposureResult).Status == "stale", "empty note accepted exposure")
	response, e = s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{mokuReplayRaw(map[string]any{"noteId": "123e4567-e89b-42d3-a456-426614174000", "revision": 3, "signal": model.NoteExposureSignal})})
	mokuReplayMust(e)
	mokuReplayCheck(response.(runtimepkg.NoteExposureResult).Status == "stale", "wrong incarnation accepted exposure")
	// Two valid writers can race, but the transaction basis admits only one.
	var group sync.WaitGroup
	results := make(chan model.NoteUpdateResult, 2)
	errorsSeen := make(chan error, 2)
	for _, text := range []string{"# Concurrent A", "# Concurrent B"} {
		group.Add(1)
		go func(text string) {
			defer group.Done()
			result, err := s.r.UpdateMokuNote(mokuReplayContext(), replacement.ID, text, cleared.State.Basis)
			results <- result
			errorsSeen <- err
		}(text)
	}
	group.Wait()
	close(results)
	close(errorsSeen)
	for err := range errorsSeen {
		mokuReplayMust(err)
	}
	wins := 0
	conflicts := 0
	for result := range results {
		if result.OK {
			wins++
		} else if result.Code == "note_state_changed" {
			conflicts++
		}
	}
	mokuReplayCheck(wins == 1 && conflicts == 1, "same-basis writers did not yield one commit and one current-state conflict")

	// A history reset is a fresh Thread with no note.
	mokuReplayMust(s.r.ClearHistory(mokuReplayContext()))
	afterReset := s.record()
	mokuReplayCheck(afterReset.ID != replacement.ID, "history reset kept the Moku Thread identity")
	mokuReplayCheck(afterReset.Note == nil, "history reset kept the note")
	response, e = s.r.Invoke(mokuReplayContext(), "moku:record-note-exposure", []json.RawMessage{requested})
	mokuReplayMust(e)
	mokuReplayCheck(response.(runtimepkg.NoteExposureResult).Status == "stale", "history reset accepted old incarnation")
	_, e = s.r.UpdateMokuNote(mokuReplayContext(), replacement.ID, "retired", nil)
	mokuReplayCheck(e != nil, "retired null-basis tool wrote into fresh history")
	fmt.Println("PASS the note survives SQLite publication and host replacement, and a history reset clears it")
	runNoteRestartReplay()
}

func runNoteRestartReplay() {
	root, err := os.MkdirTemp("", "mokusei-note-restart-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
	s := startReplaySystem(root, h)
	initial := s.record()
	created, err := s.r.UpdateMokuNote(mokuReplayContext(), initial.ID, "# Durable exposure", nil)
	mokuReplayMust(err)
	mokuReplayCheck(created.OK, "restart fixture note creation failed")
	receipt := runtimepkg.NoteExposureReceipt{NoteID: created.State.Note.ID, Revision: created.State.Note.Revision, Signal: model.NoteExposureSignal}
	accepted, err := s.r.RecordNoteExposure(mokuReplayContext(), receipt)
	mokuReplayMust(err)
	mokuReplayCheck(accepted.Status == "accepted", "restart fixture receipt failed")
	s.close()
	reopened := startReplaySystem(root, &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)})
	defer reopened.close()
	note := reopened.record().Note
	mokuReplayCheck(note != nil && note.ID == receipt.NoteID && note.ReadingRevision == 1 && note.LastExposure != nil && note.LastExposure.Text == "# Durable exposure" && note.LastExposure.Revision == 1, "SQLite restart lost exact exposure state")
	fmt.Println("PASS exact exposure survives SQLite close and runtime restart")
}
