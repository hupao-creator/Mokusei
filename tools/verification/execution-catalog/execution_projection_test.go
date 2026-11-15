package executioncatalog_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	coreruntime "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

type harnessProjectionCase struct {
	name    string
	adapter plugin.SessionStateAdapter
	state   func(unrelated int) json.RawMessage
	latest  string
	reply   string
	target  string
}

func projectionCases() []harnessProjectionCase {
	return []harnessProjectionCase{
		{"claude", claude.StateAdapter{}, claudeProjectionState, "latest", "reply", `"messageId":"reply:message"`},
		{"codex", codex.NewSessionStateAdapter(), codexProjectionState, "latest", "reply", `"itemId":"reply:native"`},
		{"pi", pi.New(plugin.HostContext{}).SessionState(), piProjectionState, "latest", "reply", `"id":"reply:answer"`},
		{"opencode", opencode.StateAdapter{}, opencodeProjectionState, "latest", "reply", `"id":"reply:answer"`},
	}
}

func TestOverviewProjectionDoesNotGrowWithUnrelatedExecutions(t *testing.T) {
	for _, c := range projectionCases() {
		t.Run(c.name, func(t *testing.T) {
			small, err := c.adapter.ProjectRenderer(c.state(2), model.RendererScope{Kind: "overview"})
			if err != nil {
				t.Fatal(err)
			}
			large, err := c.adapter.ProjectRenderer(c.state(96), model.RendererScope{Kind: "overview"})
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(small, large) {
				t.Fatalf("overview changed with unrelated executions: %d -> %d bytes\nsmall=%s\nlarge=%s",
					len(small), len(large), previewBytes(small), previewBytes(large))
			}
			if len(large) > model.MaxThreadOverviewBytes {
				t.Fatalf("overview is %d bytes, budget is %d", len(large), model.MaxThreadOverviewBytes)
			}
			t.Logf("overview bytes=%d for 2 and 96 executions", len(large))
			if bytes.Contains(large, []byte("UNRELATED_BODY")) {
				t.Fatal("overview retained unrelated execution body")
			}
			if bytes.Contains(large, []byte(`"old-`)) {
				t.Fatal("overview retained an unrelated execution identity, author or usage key")
			}
			if bytes.Contains(large, []byte("INHERITED_BODY_MUST_NOT_APPEAR")) {
				t.Fatal("overview retained an inherited sibling message")
			}
			if !bytes.Contains(large, []byte(c.latest)) || !bytes.Contains(large, []byte(c.reply)) {
				t.Fatal("overview omitted the current card or last completed reply")
			}
			if !bytes.Contains(large, []byte(c.target)) {
				t.Fatalf("overview omitted the reply target identity %s", c.target)
			}
		})
	}
}

func TestDirectoryPaginatesEveryExecutionAndPreviewStaysExact(t *testing.T) {
	for _, c := range projectionCases() {
		t.Run(c.name, func(t *testing.T) {
			state := c.state(4)
			expected := []string{"old-0", "old-1", "old-2", "old-3", c.reply, c.latest}
			var collected []string
			offset := 0
			for {
				raw, err := c.adapter.ProjectRenderer(state, model.RendererScope{Kind: "directory", Offset: offset, Limit: 2})
				if err != nil {
					t.Fatal(err)
				}
				if len(raw) > 64*1024 {
					t.Fatalf("directory page is %d bytes for two executions", len(raw))
				}
				var page model.ExecutionDirectoryPage
				if err := json.Unmarshal(raw, &page); err != nil {
					t.Fatal(err)
				}
				if page.Version != 1 || page.Offset != offset || page.Total != len(expected) {
					t.Fatalf("unexpected page identity: %+v", page)
				}
				if len(page.Executions) == 0 {
					break
				}
				for _, entry := range page.Executions {
					collected = append(collected, entry.ExecutionID)
				}
				if page.NextOffset == nil {
					break
				}
				offset = *page.NextOffset
			}
			if strings.Join(collected, ",") != strings.Join(expected, ",") {
				t.Fatalf("directory order changed: %v != %v", collected, expected)
			}
			beyond, err := c.adapter.ProjectRenderer(state, model.RendererScope{Kind: "directory", Offset: 100, Limit: 2})
			if err != nil {
				t.Fatal(err)
			}
			var empty model.ExecutionDirectoryPage
			if err := json.Unmarshal(beyond, &empty); err != nil {
				t.Fatal(err)
			}
			if empty.Offset != len(expected) || empty.Total != len(expected) || len(empty.Executions) != 0 || empty.NextOffset != nil {
				t.Fatalf("out-of-range directory page is invalid: %+v", empty)
			}
			preview, err := c.adapter.ProjectRenderer(state, model.RendererScope{Kind: "preview", Key: c.reply})
			if err != nil {
				t.Fatal(err)
			}
			var digest model.ExecutionDigest
			if err := json.Unmarshal(preview, &digest); err != nil {
				t.Fatal(err)
			}
			if digest.ExecutionID != c.reply || !strings.Contains(digest.Excerpt, "REPLY_MARKER") ||
				strings.Contains(digest.Excerpt, "LATEST_MARKER") || strings.Contains(digest.Excerpt, "INHERITED_BODY") ||
				digest.FinishedAt == nil || digest.Status != "completed" {
				t.Fatalf("reply preview lost its identity: %+v", digest)
			}
			current, err := c.adapter.ProjectRenderer(state, model.RendererScope{Kind: "preview", Key: c.latest})
			if err != nil {
				t.Fatal(err)
			}
			var currentDigest model.ExecutionDigest
			if err := json.Unmarshal(current, &currentDigest); err != nil {
				t.Fatal(err)
			}
			if currentDigest.ExecutionID != c.latest || !strings.Contains(currentDigest.Excerpt, "LATEST_MARKER") ||
				currentDigest.FinishedAt != nil || currentDigest.Status != "running" {
				t.Fatalf("running preview lost its identity: %+v", currentDigest)
			}
		})
	}
}

func TestCodexForkRuntimeScopesOverlayTitles(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	state := codex.EmptyState(10_000)
	state["turns"] = []any{}
	state["forkHistory"] = []any{codexTurn("inherited", "completed", "INHERITED_MARKER", 5)}
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{
		SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "codex", Revision: 1,
			SessionState: raw, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1},
		Title: "Forked thread", Tags: []string{}, TagEmojis: map[string]string{},
		ExecutionTitles: map[string]string{"inherited": "Inherited title"},
	}
	if _, err := db.Update(context.Background(), func(tx *store.Tx) error {
		if err := tx.Put("thread:thread", thread); err != nil {
			return err
		}
		return tx.Put("threads", []string{"thread"})
	}); err != nil {
		t.Fatal(err)
	}
	harness := codex.New(plugin.HostContext{})
	defer harness.Close()
	r, err := coreruntime.New(context.Background(), coreruntime.Config{Store: db, DataDir: dir, DefaultCwd: dir,
		Harnesses: map[string]plugin.Harness{"codex": harness}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := r.Close(context.Background()); err != nil {
			t.Error(err)
		}
	}()
	directory, err := r.ReadThreadContent(context.Background(), "thread",
		transport.ContentScope{Kind: "directory", Limit: 10}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var page model.ExecutionDirectoryPage
	if err := json.Unmarshal(directory.Value, &page); err != nil {
		t.Fatal(err)
	}
	if page.Total != 1 || len(page.Executions) != 1 || page.Executions[0].ExecutionID != "inherited" ||
		page.Executions[0].Title != "Inherited title" || !strings.Contains(page.Executions[0].Excerpt, "INHERITED_MARKER") {
		t.Fatalf("runtime fork directory lost title or excerpt: %+v", page)
	}
	previews, err := r.ExecutionPreviews(context.Background(), []model.ExecutionRef{{
		Thread: model.ThreadRef{ThreadID: "thread", TypeID: "agent"}, ExecutionID: "inherited",
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].Title != "Inherited title" ||
		!strings.Contains(previews[0].Excerpt, "INHERITED_MARKER") || previews[0].ThreadID != "thread" {
		t.Fatalf("runtime fork preview lost identity: %+v", previews)
	}
}

func previewBytes(value []byte) string {
	if len(value) > 512 {
		return string(value[:512]) + "..."
	}
	return string(value)
}

func TestAdaptersAcceptConcurrentSharedState(t *testing.T) {
	for _, c := range projectionCases() {
		t.Run(c.name, func(t *testing.T) {
			state := c.state(16)
			before := bytes.Clone(state)
			scopes := []model.RendererScope{{Kind: "overview"}, {Kind: "thread"},
				{Kind: "directory", Limit: 8}, {Kind: "preview", Key: "reply"}}
			var wg sync.WaitGroup
			errors := make(chan error, 64)
			for worker := 0; worker < 16; worker++ {
				for _, scope := range scopes {
					wg.Add(1)
					go func(scope model.RendererScope) {
						defer wg.Done()
						if _, err := c.adapter.ProjectRenderer(state, scope); err != nil {
							errors <- err
						}
					}(scope)
				}
			}
			wg.Wait()
			close(errors)
			for err := range errors {
				t.Fatal(err)
			}
			if !bytes.Equal(before, state) {
				t.Fatal("projection mutated shared state bytes")
			}
		})
	}
}

func TestCodexDirectoryAndPreviewIncludeForkHistory(t *testing.T) {
	state := codex.EmptyState(10_000)
	state["turns"] = []any{}
	state["forkHistory"] = []any{codexTurn("inherited", "completed", "INHERITED_MARKER", 5)}
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	adapter := codex.NewSessionStateAdapter()
	pageRaw, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "directory", Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	var page model.ExecutionDirectoryPage
	if err := json.Unmarshal(pageRaw, &page); err != nil {
		t.Fatal(err)
	}
	if page.Total != 1 || len(page.Executions) != 1 || page.Executions[0].ExecutionID != "inherited" {
		t.Fatalf("fork-only directory lost inherited execution: %+v", page)
	}
	previewRaw, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "preview", Key: "inherited"})
	if err != nil {
		t.Fatal(err)
	}
	var preview model.ExecutionDigest
	if err := json.Unmarshal(previewRaw, &preview); err != nil {
		t.Fatal(err)
	}
	if preview.ExecutionID != "inherited" || !strings.Contains(preview.Excerpt, "INHERITED_MARKER") {
		t.Fatalf("fork-only preview lost inherited execution: %+v", preview)
	}
	resolved, err := adapter.ResolveExecution(raw, "inherited")
	if err != nil {
		t.Fatal(err)
	}
	if resolved == nil || resolved.ExecutionID != "inherited" || resolved.FinishedAt == nil || resolved.Status != "completed" {
		t.Fatalf("fork-only ResolveExecution lost inherited timing: %+v", resolved)
	}

	state["turns"] = []any{codexTurn("current", "running", "CURRENT_MARKER", 6)}
	raw, err = json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	pageRaw, err = adapter.ProjectRenderer(raw, model.RendererScope{Kind: "directory", Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(pageRaw, &page); err != nil {
		t.Fatal(err)
	}
	if page.Total != 2 || page.Executions[0].ExecutionID != "inherited" || page.Executions[1].ExecutionID != "current" {
		t.Fatalf("fork chronology changed: %+v", page)
	}
}

func claudeProjectionState(unrelated int) json.RawMessage {
	turns := []*claude.Turn{}
	for index := 0; index < unrelated; index++ {
		turns = append(turns, claudeTurn(fmt.Sprintf("old-%d", index), "completed",
			"UNRELATED_BODY "+strings.Repeat("old", 8_000), true, ""))
	}
	turns = append(turns, claudeTurn("reply", "completed", "", true, "REPLY_MARKER"))
	turns = append(turns, claudeTurn("latest", "running", "", false, "LATEST_MARKER"))
	raw, err := json.Marshal(&claude.State{Version: 1, Turns: turns, NativeNotifications: []map[string]any{}})
	if err != nil {
		panic(err)
	}
	return raw
}

func claudeTurn(id, status, text string, finished bool, marker string) *claude.Turn {
	turn := &claude.Turn{ExecutionID: id, CreatedAt: 1, UpdatedAt: 2, Status: status,
		Prompts: []string{"prompt"}, PromptAttachments: [][]map[string]any{{}},
		Plan: []map[string]any{}, Activities: []map[string]any{}, Interactions: []map[string]any{},
		Notices: []map[string]any{}, Text: text}
	if finished {
		at := int64(2)
		turn.FinishedAt = &at
	}
	if marker != "" {
		kind := "assistant"
		if status == "running" {
			kind = "reasoning"
		}
		turn.Timeline = []map[string]any{{"id": id + ":item", "kind": kind, "createdAt": 1,
			"messageId": id + ":message", "content": marker, "status": "complete"}}
	} else {
		turn.Timeline = []map[string]any{}
	}
	return turn
}

func codexProjectionState(unrelated int) json.RawMessage {
	state := codex.EmptyState(10_000)
	turns := []any{}
	for index := 0; index < unrelated; index++ {
		turns = append(turns, codexTurn(fmt.Sprintf("old-%d", index), "completed",
			"UNRELATED_BODY "+strings.Repeat("old", 8_000), int64(index+1)))
	}
	turns = append(turns, codexTurn("reply", "completed", "REPLY_MARKER", 900))
	turns = append(turns, codexTurn("latest", "running", "LATEST_MARKER", 901))
	state["turns"] = turns
	raw, err := json.Marshal(state)
	if err != nil {
		panic(err)
	}
	return raw
}

func codexTurn(id, status, text string, at int64) map[string]any {
	turn := map[string]any{
		"executionId": id, "createdAt": at, "updatedAt": at, "status": status,
		"statusLabel": "", "messages": []any{}, "answer": text, "reasoning": "",
		"plan": []any{}, "activities": []any{}, "interactions": []any{}, "notices": []any{},
		"reasoningTokensByGeneration": map[string]any{},
		"author":                      map[string]any{"model": "fixture"},
		"timeline": []any{map[string]any{
			"id": id + ":item", "kind": "assistant", "itemId": id + ":native",
			"content": text, "status": "complete", "createdAt": at,
		}},
	}
	if status != "running" {
		turn["finishedAt"] = at
	}
	return turn
}

func piProjectionState(unrelated int) json.RawMessage {
	latest := "latest"
	messages := []pi.MessageState{}
	executions := []model.PublicExecution{}
	authors := map[string]json.RawMessage{}
	for index := 0; index < unrelated; index++ {
		id := fmt.Sprintf("old-%d", index)
		executions = append(executions, finishedExecution(id, int64(index+1)))
		messages = append(messages,
			pi.MessageState{ID: id + ":user", ExecutionID: id, Role: "user", Text: "prompt"},
			pi.MessageState{ID: id + ":answer", ExecutionID: id, Role: "assistant", Status: "complete",
				Text: "UNRELATED_BODY " + strings.Repeat("old", 8_000), Usage: &pi.Usage{Input: 1}})
		authors[id] = json.RawMessage(`{"model":"fixture"}`)
	}
	executions = append(executions, finishedExecution("reply", 900))
	messages = append(messages,
		pi.MessageState{ID: "reply:user", ExecutionID: "reply", Role: "user", Text: "prompt"},
		pi.MessageState{ID: "reply:answer", ExecutionID: "reply", Role: "assistant", Status: "complete", Text: "REPLY_MARKER"})
	authors["reply"] = json.RawMessage(`{"model":"fixture"}`)
	executions = append(executions, model.PublicExecution{ExecutionID: "latest", Status: "running", StartedAt: 901})
	messages = append(messages, pi.MessageState{ID: "latest:user", ExecutionID: "latest", Role: "user", Text: "prompt"},
		pi.MessageState{ID: "latest:answer", ExecutionID: "latest", Role: "assistant", Status: "streaming",
			Thinking: "LATEST_MARKER", Usage: &pi.Usage{Input: 2}})
	authors["latest"] = json.RawMessage(`{"model":"fixture"}`)
	raw, err := json.Marshal(&pi.State{Version: 1, Messages: messages, Executions: executions,
		ExecutionAuthors: authors, LatestExecutionID: &latest})
	if err != nil {
		panic(err)
	}
	return raw
}

func finishedExecution(id string, at int64) model.PublicExecution {
	finished := at
	return model.PublicExecution{ExecutionID: id, Status: "completed", StartedAt: at, FinishedAt: &finished}
}

func opencodeProjectionState(unrelated int) json.RawMessage {
	latest := "latest"
	messages := []*opencode.Message{}
	executions := []*model.PublicExecution{}
	authors := map[string]opencode.Object{}
	auxiliary := []opencode.AuxiliaryUsage{}
	for index := 0; index < unrelated; index++ {
		id := fmt.Sprintf("old-%d", index)
		execution := finishedExecution(id, int64(index+1))
		executions = append(executions, &execution)
		messages = append(messages,
			&opencode.Message{ID: id + ":user", ExecutionID: id, Role: "user", Text: "prompt"},
			&opencode.Message{ID: id + ":answer", ExecutionID: id, Role: "assistant", Status: "complete",
				Parts: []opencode.Part{{Type: "text", Text: "UNRELATED_BODY " + strings.Repeat("old", 8_000)}}, Usage: &opencode.Usage{Input: 1}})
		authors[id] = opencode.Object{"model": "fixture"}
		auxiliary = append(auxiliary, opencode.AuxiliaryUsage{ID: id + ":aux", ExecutionID: id, Usage: opencode.Usage{Input: 1}})
	}
	reply := finishedExecution("reply", 900)
	executions = append(executions, &reply)
	messages = append(messages,
		&opencode.Message{ID: "reply:user", ExecutionID: "reply", Role: "user", Text: "prompt"},
		&opencode.Message{ID: "reply:answer", ExecutionID: "reply", Role: "assistant", Status: "complete", Parts: []opencode.Part{{Type: "text", Text: "REPLY_MARKER"}}},
		&opencode.Message{ID: "reply:inherited", ExecutionID: "reply", Role: "assistant", Status: "complete",
			Parts: []opencode.Part{{Type: "text", Text: "INHERITED_BODY_MUST_NOT_APPEAR"}}, Inherited: true, NativeSessionID: "source-session"})
	authors["reply"] = opencode.Object{"model": "fixture"}
	running := model.PublicExecution{ExecutionID: "latest", Status: "running", StartedAt: 901}
	executions = append(executions, &running)
	messages = append(messages,
		&opencode.Message{ID: "latest:user", ExecutionID: "latest", Role: "user", Text: "prompt"},
		&opencode.Message{ID: "latest:answer", ExecutionID: "latest", Role: "assistant", Status: "streaming",
			Usage: &opencode.Usage{Input: 2},
			Parts: []opencode.Part{{Type: "reasoning", Ordinal: 1, Text: "LATEST_MARKER"}}})
	authors["latest"] = opencode.Object{"model": "fixture"}
	auxiliary = append(auxiliary, opencode.AuxiliaryUsage{ID: "latest:aux", ExecutionID: "latest", Usage: opencode.Usage{Input: 2}})
	raw, err := json.Marshal(&opencode.State{Version: opencode.StateVersion, NativeSessionID: "fixture",
		Messages: messages, Executions: executions, LatestExecutionID: &latest,
		ExecutionAuthors: authors, AuxiliaryUsage: auxiliary})
	if err != nil {
		panic(err)
	}
	return raw
}

func TestDirectoryOffsetAndLimitMatchScopeForEveryHarness(t *testing.T) {
	for _, c := range projectionCases() {
		t.Run(c.name, func(t *testing.T) {
			state := c.state(4)
			for _, request := range []model.RendererScope{
				{Kind: "directory", Offset: 2, Limit: 2},
				{Kind: "directory", Offset: 5, Limit: 3},
				{Kind: "directory", Offset: -1, Limit: 2},
				{Kind: "directory", Offset: 0, Limit: 0},
				{Kind: "directory", Offset: 0, Limit: 201},
			} {
				raw, err := c.adapter.ProjectRenderer(state, request)
				if err != nil {
					t.Fatal(err)
				}
				var page model.ExecutionDirectoryPage
				if err := json.Unmarshal(raw, &page); err != nil {
					t.Fatal(err)
				}
				expectedLimit := request.Limit
				if expectedLimit <= 0 {
					expectedLimit = model.DefaultExecutionDirectoryLimit
				}
				if expectedLimit > model.MaximumExecutionDirectoryLimit {
					expectedLimit = model.MaximumExecutionDirectoryLimit
				}
				expectedOffset := max(0, request.Offset)
				if expectedOffset > page.Total {
					expectedOffset = page.Total
				}
				if page.Offset != expectedOffset || page.Limit != expectedLimit {
					t.Fatalf("scope %+v returned offset=%d limit=%d total=%d", request, page.Offset, page.Limit, page.Total)
				}
				for _, execution := range page.Executions {
					if execution.ExecutionID == "" || execution.Title != "" {
						t.Fatalf("directory entry has unexpected title/identity: %+v", execution)
					}
				}
			}
		})
	}
}
