package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	ctx := context.Background()
	root, err := os.MkdirTemp("", "mokusei-command-boundaries-")
	must(err)
	defer os.RemoveAll(root)
	verifyInputFileBoundaries(ctx, root)
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	must(err)
	defer db.Close()
	runtime, err := core.New(ctx, core.Config{Store: db, DataDir: root, DefaultCwd: root, Harnesses: map[string]plugin.Harness{}})
	must(err)
	defer runtime.Close(ctx)
	raw := func(value any) json.RawMessage { data, err := json.Marshal(value); must(err); return data }
	reject := func(channel string, args ...any) {
		encoded := []json.RawMessage{}
		for _, value := range args {
			encoded = append(encoded, raw(value))
		}
		_, err := runtime.Invoke(ctx, channel, encoded)
		if err == nil || !strings.Contains(err.Error(), "Invalid command argument") {
			panic(fmt.Sprintf("%s was not rejected at the command boundary: %v", channel, err))
		}
	}
	reject("thread:set-archived", "missing", nil)
	reject("application:archive", map[string]any{"typeId": "report.report", "threadId": "missing"}, nil)
	reject("thread:fork", map[string]any{"threadId": "missing"})
	reject("thread:fork", map[string]any{"threadId": "missing", "request": strings.Repeat("界", 3_000_000)})
	reject("harness:extension", map[string]any{"harnessId": "codex", "method": "query"})
	reject("harness:extension", map[string]any{"harnessId": "codex", "method": "query", "payload": strings.Repeat("界", 3_000_000)})
	reject("thread:update-settings", map[string]any{"threadId": "missing", "harnessId": "codex", "expectedSettingsRevision": 0, "change": map[string]any{"note": strings.Repeat("界", 400_000)}})
	reject("thread:update-settings", map[string]any{"threadId": "missing", "harnessId": "codex", "expectedSettingsRevision": 0, "change": nil})
	reject("thread:interaction-respond", map[string]any{"threadId": "missing", "executionId": "native-execution", "interactionId": "native", "actionId": "submit", "answers": map[string]any{"note": strings.Repeat("界", 400_000)}})
	reject("application:query", map[string]any{"pluginId": "report", "operationId": "report.html", "input": strings.Repeat("界", 700_000)})
	reject("application:query", map[string]any{"pluginId": "report", "operationId": "report.html", "input": nil, "requestId": nil})
	reject("harness:settings-presentation", map[string]any{"scope": "global", "harnessId": "codex", "refresh": nil})
	reject("harness:settings-presentation", map[string]any{"scope": "thread", "threadId": "missing", "executionOwner": "moku"})
	reject("moku:stage-attachments", []any{map[string]any{"source": "path", "path": "/tmp/example", "displayName": strings.Repeat("🚀", 513)}})
	ids := make([]string, 21)
	for i := range ids {
		ids[i] = "123e4567-e89b-42d3-a456-426614174000"
	}
	reject("attachment:discard", ids)
	reject("thread:read", map[string]any{"threadId": strings.Repeat("x", 129), "question": "question"})
	validNoteID := "123e4567-e89b-42d3-a456-426614174000"
	reject("moku:record-note-exposure", map[string]any{"noteId": validNoteID, "revision": 0, "signal": model.NoteExposureSignal})
	reject("moku:record-note-exposure", map[string]any{"noteId": "not-a-uuid", "revision": 1, "signal": model.NoteExposureSignal})
	reject("moku:record-note-exposure", map[string]any{"noteId": validNoteID, "revision": 1.5, "signal": model.NoteExposureSignal})
	reject("moku:record-note-exposure", map[string]any{"noteId": validNoteID, "revision": model.MaximumSafeInteger + 1, "signal": model.NoteExposureSignal})
	reject("moku:record-note-exposure", map[string]any{"noteId": validNoteID, "revision": 1, "signal": "understood"})
	reject("moku:record-note-exposure", map[string]any{"noteId": validNoteID, "revision": 1, "signal": model.NoteExposureSignal, "text": "client asserted"})
	reject("moku:submit", map[string]any{"input": nil, "directoryScopeId": 1})
	reject("moku:submit", map[string]any{"input": nil, "directoryScopeId": ""})
	reject("moku:submit", map[string]any{"input": nil, "directoryScopeId": "scope\x00"})
	reject("moku:submit", map[string]any{"input": nil, "directoryScopeId": strings.Repeat("x", 4097)})
	_, err = runtime.Invoke(ctx, "state:load", nil)
	must(err)
	must(model.ValidateCommandArguments("thread:fork", []json.RawMessage{raw(map[string]any{"threadId": "missing", "request": nil})}))
	must(model.ValidateCommandArguments("application:query", []json.RawMessage{raw(map[string]any{"pluginId": "report", "operationId": "report.html", "input": nil})}))
	must(model.ValidateCommandArguments("moku:stage-attachments", []json.RawMessage{raw(nil)}))
	must(model.ValidateCommandArguments("moku:submit", []json.RawMessage{raw(map[string]any{"input": nil})}))
	must(model.ValidateCommandArguments("moku:submit", []json.RawMessage{raw(map[string]any{"input": nil, "directoryTag": "Project", "directoryScopeId": "scope-1"})}))
	must(model.ValidateCommandArguments("moku:submit", []json.RawMessage{raw(map[string]any{"input": nil, "directoryScopeId": strings.Repeat("x", 4096)})}))
	// GO-2026-5026 must be rejected by the public parser before a media URL
	// can reach a Harness; legitimate IDNs must retain their normalization.
	for _, kind := range []string{"image-url", "audio-url"} {
		for _, fixture := range []struct{ url, normalized string }{
			{"https://example.com/media", "https://example.com/media"},
			{"https://bücher.example/media", "https://xn--bcher-kva.example/media"},
			{"https://xn--bcher-kva.example/media", "https://xn--bcher-kva.example/media"},
			{"https://xn--example-.com/media", ""},
			{"https://xn--abc-.example/media", ""},
		} {
			payload := map[string]any{"parts": []any{map[string]any{"kind": kind, "url": fixture.url}}}
			input, err := model.ParsePublicAgentInput(raw(payload))
			if fixture.normalized == "" {
				if err == nil {
					panic(fmt.Sprintf("%s accepted ASCII-only Punycode URL %q", kind, fixture.url))
				}
				_, err = runtime.Invoke(ctx, "thread:follow-up", []json.RawMessage{raw(map[string]any{"threadId": "missing", "input": payload})})
				if err == nil || !strings.Contains(err.Error(), "invalid media URL") {
					panic(fmt.Sprintf("%s was not rejected before thread lookup: %v", fixture.url, err))
				}
				continue
			}
			must(err)
			if len(input.Parts) != 1 || input.Parts[0].URL != fixture.normalized {
				panic(fmt.Sprintf("%s normalized %q incorrectly: %+v", kind, fixture.url, input))
			}
		}
	}
	fmt.Println("PASS public media URL parser: ASCII-only Punycode rejected; ASCII and internationalized domains preserved")
	fmt.Println("PASS real Runtime command admission: required fields, null/boolean distinction, UTF-16 strings, UTF-8 JSON payload limits, closed scopes, Moku submit directory scopes and attachment counts; valid opaque null/empty imports preserved")
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
