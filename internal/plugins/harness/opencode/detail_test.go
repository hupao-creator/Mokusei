package opencode

import (
	"encoding/json"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func openCodeDetailState() State {
	finished := int64(2)
	latest := "execution"
	return State{Version: StateVersion, NativeSessionID: "root", Messages: []*Message{
		{ID: "before", ExecutionID: "execution", Role: "tool", Result: "before", ToolName: "before", Status: "complete"},
		{ID: "child", ExecutionID: "execution", Role: "tool", Result: "child", ToolName: "child", Status: "complete", NativeSessionID: "child-session"},
		{ID: "after", ExecutionID: "execution", Role: "tool", Result: "after", ToolName: "after", Status: "complete"},
		{ID: "nested", ExecutionID: "execution", Role: "tool", Result: "nested", ToolName: "nested", Status: "complete", NativeSessionID: "nested-session"},
		{ID: "answer", ExecutionID: "execution", Role: "assistant", Status: "complete",
			Parts: []Part{{Type: "reasoning", Ordinal: 0, Text: "reasoning"}, {Type: "text", Ordinal: 0, Text: "answer"}}},
	}, Executions: []*model.PublicExecution{{ExecutionID: "execution", Status: "completed", StartedAt: 1, FinishedAt: &finished}},
		LatestExecutionID: &latest}
}

func openCodeChildRow(execution, native string) string {
	encoded, _ := json.Marshal([]string{execution, native})
	return "opencode-child-session:" + string(encoded)
}

func TestReaderDetailExpandsChildSessionInReaderOrder(t *testing.T) {
	raw, err := json.Marshal(openCodeDetailState())
	if err != nil {
		t.Fatal(err)
	}
	adapter := StateAdapter{}
	projection, err := adapter.ProjectDetail(raw, model.DetailRequest{ExecutionID: "execution",
		Items: []string{openCodeChildRow("execution", "child-session"), "after"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.Items) != 2 || projection.Items[0].ID != "child" || projection.Items[1].ID != "after" {
		t.Fatalf("child expansion order = %+v", projection.Items)
	}
	for _, item := range projection.Items {
		if item.Bodies[0].Text != "" {
			t.Fatalf("directory projection serialized a body: %+v", item)
		}
		// Tool display formatting is deferred; the first body page names the
		// authoritative length.
		if item.Bodies[0].Length != 0 {
			t.Fatalf("directory unexpectedly formatted tool display: %+v", item)
		}
	}
	body, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "execution", ItemID: "child", Slot: "result"})
	if err != nil || body.Text != "child" {
		t.Fatalf("child body = %q, %v", body.Text, err)
	}
}

func TestReaderDetailResolvesSeparateNestedChildBody(t *testing.T) {
	raw, err := json.Marshal(openCodeDetailState())
	if err != nil {
		t.Fatal(err)
	}
	adapter := StateAdapter{}
	projection, err := adapter.ProjectDetail(raw, model.DetailRequest{ExecutionID: "execution",
		Items: []string{openCodeChildRow("execution", "nested-session")}})
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.Items) != 1 || projection.Items[0].ID != "nested" {
		t.Fatalf("nested child projection = %+v", projection.Items)
	}
	body, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "execution", ItemID: "nested", Slot: "result"})
	if err != nil || body.Text != "nested" {
		t.Fatalf("nested child body = %q, %v", body.Text, err)
	}
}

func TestReaderDetailUsesOnlyOrderedParts(t *testing.T) {
	raw := json.RawMessage(`{"version":2,"nativeSessionId":"root","messages":[
		{"id":"legacy","executionId":"execution","role":"assistant","status":"complete","thinking":"retired aggregate reasoning"}
	],"executions":[{"executionId":"execution","status":"completed","startedAt":1,"finishedAt":2}],"latestExecutionId":"execution"}`)
	adapter := StateAdapter{}
	projection, err := adapter.ProjectDetail(raw, model.DetailRequest{ExecutionID: "execution", Items: []string{"legacy", "legacy:reasoning"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.Items) != 0 {
		t.Fatalf("retired aggregate thinking became detail rows: %+v", projection.Items)
	}
	if _, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "execution", ItemID: "legacy:reasoning", Slot: "content"}); err == nil {
		t.Fatal("retired aggregate thinking resolved a body")
	}
}

func TestReadDetailBodyDoesNotFormatLargeSiblings(t *testing.T) {
	const siblingBytes = 24 << 20
	state := openCodeDetailState()
	state.Messages = append(state.Messages, &Message{
		ID: "huge-sibling", ExecutionID: "execution", Role: "tool", Status: "complete", ToolName: "huge",
		Result: map[string]any{"payload": strings.Repeat("x", siblingBytes)},
	})
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	adapter := StateAdapter{}
	// Warm the small path once so package initialization does not enter the
	// measured call.
	if _, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "execution", ItemID: "before", Slot: "result"}); err != nil {
		t.Fatal(err)
	}
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	start := time.Now()
	body, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "execution", ItemID: "before", Slot: "result"})
	elapsed := time.Since(start)
	runtime.ReadMemStats(&after)
	if err != nil || body.Text != "before" {
		t.Fatalf("small body = %q, %v", body.Text, err)
	}
	allocated := after.TotalAlloc - before.TotalAlloc
	t.Logf("small body read from a %d-byte sibling: %s, %d bytes allocated", siblingBytes, elapsed, allocated)
	// Formatting the 24 MiB sibling used to allocate >350 MiB here. Decoding
	// the State itself still dominates the exact read, but no sibling display
	// string is built.
	if allocated > 192<<20 {
		t.Fatalf("exact body read allocated %d bytes for a %d-byte sibling", allocated, siblingBytes)
	}
	timeLimit := 2 * time.Second
	if detailRaceEnabled {
		timeLimit = 15 * time.Second
	}
	if elapsed > timeLimit {
		t.Fatalf("exact body read took %s", elapsed)
	}
}

func TestProjectDetailDoesNotFormatLargeSiblings(t *testing.T) {
	const siblingBytes = 24 << 20
	state := openCodeDetailState()
	state.Messages = append(state.Messages, &Message{
		ID: "huge-sibling", ExecutionID: "execution", Role: "tool", Status: "complete", ToolName: "huge",
		Result: map[string]any{"payload": strings.Repeat("x", siblingBytes)},
	})
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	adapter := StateAdapter{}
	if _, err := adapter.ProjectDetail(raw, model.DetailRequest{ExecutionID: "execution", Items: []string{"before", "huge-sibling"}}); err != nil {
		t.Fatal(err)
	}
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	start := time.Now()
	projection, err := adapter.ProjectDetail(raw, model.DetailRequest{ExecutionID: "execution", Items: []string{"before", "huge-sibling"}})
	elapsed := time.Since(start)
	runtime.ReadMemStats(&after)
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.Items) != 2 || projection.Items[0].ID != "before" || projection.Items[1].ID != "huge-sibling" {
		t.Fatalf("directory projection = %+v", projection.Items)
	}
	for _, item := range projection.Items {
		if len(item.Bodies) != 1 || item.Bodies[0].Text != "" || item.Bodies[0].Length != 0 {
			t.Fatalf("directory formatted a selected tool body: %+v", item)
		}
	}
	allocated := after.TotalAlloc - before.TotalAlloc
	t.Logf("directory read with a %d-byte sibling: %s, %d bytes allocated", siblingBytes, elapsed, allocated)
	if allocated > 192<<20 {
		t.Fatalf("directory projection allocated %d bytes for a %d-byte sibling", allocated, siblingBytes)
	}
	timeLimit := 2 * time.Second
	if detailRaceEnabled {
		timeLimit = 15 * time.Second
	}
	if elapsed > timeLimit {
		t.Fatalf("directory projection took %s", elapsed)
	}
}
