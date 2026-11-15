// Command thread-detail-performance checks the production reader projection boundary.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

func main() {
	for _, status := range []string{"running", "completed", "failed", "interrupted"} {
		c := codex.StageExecution(codex.EmptyState(1), "one", codex.Map{"parts": []any{codex.Map{"kind": "text", "text": "prompt"}}}, 2, nil)
		steps := []any{}
		for i := 0; i < 100; i++ {
			steps = append(steps, codex.Map{"step": strings.Repeat("p", 1024), "status": "pending"})
		}
		c = codex.ReduceEvent(c, "one", codex.Map{"type": "plan", "steps": steps, "explanation": "hidden explanation", "at": 3})
		c = codex.ReduceEvent(c, "one", codex.Map{"type": "reasoning-delta", "delta": "reasoning", "at": 4})
		c = codex.ReduceEvent(c, "one", codex.Map{"type": "text-final", "itemId": "answer", "text": "answer", "at": 5})
		if status != "running" {
			c = codex.SettleExecution(c, "one", status, 6, "failure")
		}
		verify("codex/"+status, codex.NewSessionStateAdapter(), encode(c), "turn:one", false)
		if status != "running" {
			history := codex.EmptyState(7)
			history["forkHistory"] = c["turns"]
			verify("codex/history/"+status, codex.NewSessionStateAdapter(), encode(history), "turn:one", true)
		}

		s := claude.NewState()
		t := s.NewTurn("one", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, claude.Settings{})
		for _, step := range steps {
			t.Plan = append(t.Plan, step.(map[string]any))
		}
		t.PlanExplanation = "hidden explanation"
		t.Timeline = append(t.Timeline, map[string]any{"id": "plan", "kind": "plan", "createdAt": t.CreatedAt})
		t.Text = "answer"
		t.Reasoning = "reasoning"
		t.Timeline = append(t.Timeline, map[string]any{"id": "reasoning", "kind": "reasoning", "content": "reasoning", "createdAt": t.CreatedAt}, map[string]any{"id": "answer", "kind": "assistant", "content": "answer", "status": "complete", "createdAt": t.CreatedAt})
		t.Status = status
		if status != "running" {
			t.FinishedAt = &t.UpdatedAt
		}
		verify("claude/"+status, claude.StateAdapter{}, encode(s), "one", false)
	}
	verifyClaudeHistory()
	verifyDetailSelection()
	fmt.Println("PASS reader plans omitted; selected detail bodies bounded and complete; other fields, source, overview, context and full execution preserved")
}
func projectReader(name string, adapter plugin.SessionStateAdapter, raw json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	reader, ok := adapter.(plugin.ReaderProjectionAdapter)
	if !ok {
		return adapter.ProjectRenderer(raw, scope)
	}
	result, err := reader.ProjectReader(context.Background(), plugin.ReaderRequest{ThreadID: name, ContentID: sessioncache.Identity(raw), State: raw, Scope: scope, Generation: 1})
	if err != nil {
		return nil, err
	}
	if result == nil {
		return nil, fmt.Errorf("reader projection returned no value")
	}
	return result.Value, nil
}

func encode(value any) json.RawMessage { raw, err := json.Marshal(value); must(err); return raw }
func decode(raw json.RawMessage) map[string]any {
	var value map[string]any
	must(json.Unmarshal(raw, &value))
	return value
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}

func verify(name string, adapter plugin.SessionStateAdapter, raw json.RawMessage, key string, history bool) {
	before := bytes.Clone(raw)
	full, err := projectReader(name, adapter, raw, model.RendererScope{Kind: "execution", Key: key})
	must(err)
	overview, err := projectReader(name, adapter, raw, model.RendererScope{Kind: "overview"})
	must(err)
	context, err := adapter.ReadContext(raw)
	must(err)
	reading, err := projectReader(name, adapter, raw, model.RendererScope{Kind: "turn", Key: key})
	must(err)
	value := decode(reading)
	if value["kind"] == "deferred-execution" {
		if len(value["nonempty"].([]any)) == 0 {
			panic(name + ": reasoning presence lost")
		}
		value = value["state"].(map[string]any)
	}
	field := "turns"
	if history {
		field = "forkHistory"
	}
	turn := value[field].([]any)[0].(map[string]any)
	if len(turn["plan"].([]any)) != 0 || turn["planExplanation"] != nil {
		panic(name + ": plan payload retained")
	}
	for _, item := range turn["timeline"].([]any) {
		if item.(map[string]any)["kind"] == "plan" {
			panic(name + ": plan timeline retained")
		}
	}

	fullTurn := decode(full)[field].([]any)[0].(map[string]any)
	if len(fullTurn["plan"].([]any)) != 100 || fullTurn["planExplanation"] != "hidden explanation" {
		panic(name + ": full execution lost plan")
	}
	if !history && (!bytes.Contains(overview, []byte(strings.Repeat("p", 100))) || !bytes.Contains(context, []byte("hidden explanation"))) {
		panic(name + ": overview/context lost plan")
	}
	ids := []any{}
	for _, item := range fullTurn["timeline"].([]any) {
		if item.(map[string]any)["kind"] != "plan" {
			ids = append(ids, item.(map[string]any)["id"])
		}
	}
	actualIDs := []any{}
	for _, item := range turn["timeline"].([]any) {
		actualIDs = append(actualIDs, item.(map[string]any)["id"])
	}
	if !reflect.DeepEqual(ids, actualIDs) {
		panic(name + ": reading timeline identities changed")
	}
	for _, field := range []string{"messages", "prompts", "promptAttachments", "answer", "text", "status", "usage"} {
		if !reflect.DeepEqual(fullTurn[field], turn[field]) {
			panic(name + ": reading field lost: " + field)
		}
	}
	// Removing only these known fields from the full view gives the same reader
	// content for running turns. Settled turns already have deferred redaction.
	if strings.HasSuffix(name, "/running") {
		expected := decode(full)
		expectedTurn := expected[field].([]any)[0].(map[string]any)
		expectedTurn["plan"] = []any{}
		delete(expectedTurn, "planExplanation")
		items := []any{}
		for _, item := range expectedTurn["timeline"].([]any) {
			if item.(map[string]any)["kind"] != "plan" {
				items = append(items, item)
			}
		}
		expectedTurn["timeline"] = items
		if !reflect.DeepEqual(expected, value) {
			panic(name + ": unrelated reader field changed")
		}
	}
	again, err := projectReader(name, adapter, raw, model.RendererScope{Kind: "execution", Key: key})
	must(err)
	overviewAgain, err := projectReader(name, adapter, raw, model.RendererScope{Kind: "overview"})
	must(err)
	contextAgain, err := adapter.ReadContext(raw)
	must(err)
	if !bytes.Equal(raw, before) || !reflect.DeepEqual(decode(full), decode(again)) || !bytes.Equal(overview, overviewAgain) || !bytes.Equal(context, contextAgain) {
		panic(name + ": another consumer changed")
	}
	fmt.Printf("%s full=%d reader=%d bytes\n", name, len(full), len(reading))
}

func verifyDetailSelection() {
	small := "small detail body"
	huge := "HUGE_BODY_MARKER" + strings.Repeat("大🙂", 30000)

	s := claude.NewState()
	turn := s.NewTurn("detail-execution", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, claude.Settings{})
	turn.Timeline = append(turn.Timeline,
		map[string]any{"id": "small-row", "kind": "activity", "createdAt": 1,
			"activity": map[string]any{"id": "small", "kind": "command", "label": "small tool", "status": "completed", "detail": small}},
		map[string]any{"id": "reply-row", "kind": "assistant", "content": "separator", "status": "complete", "createdAt": 2},
		map[string]any{"id": "huge-row", "kind": "activity", "createdAt": 3,
			"activity": map[string]any{"id": "huge", "kind": "command", "label": "huge tool", "status": "completed", "detail": huge}},
	)
	claudeRaw := encode(s)
	verifyAdapterDetail("claude", claude.StateAdapter{}, claudeRaw, "detail-execution", "small-row", "huge-row", "detail", small, huge, false)
	messageDetail := any(claude.StateAdapter{}).(plugin.DetailStateAdapter)
	messageProjection, err := messageDetail.ProjectDetail(claudeRaw, model.DetailRequest{ExecutionID: "detail-execution", Items: []string{"reply-row"}})
	must(err)
	if len(messageProjection.Items) != 1 || messageProjection.Items[0].ID != "reply-row" || messageProjection.Items[0].Kind != "message" {
		panic("explicit assistant message detail did not resolve its stable identity")
	}
	canonical := claude.NewState()
	canonicalTurn := canonical.NewTurn("canonical", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, claude.Settings{})
	canonicalTurn.Activities = []map[string]any{{"id": "tool", "kind": "command", "label": "final label", "status": "completed", "detail": "final detail", "toolName": "command"}}
	canonicalTurn.Timeline = append(canonicalTurn.Timeline,
		map[string]any{"id": "start-row", "kind": "activity", "createdAt": 1, "activity": map[string]any{"id": "tool", "status": "running", "detail": "start detail"}},
		map[string]any{"id": "end-row", "kind": "activity", "createdAt": 2, "activity": map[string]any{"id": "tool", "status": "completed", "detail": "end detail"}},
	)
	canonicalRaw := encode(canonical)
	canonicalProjection, err := messageDetail.ProjectDetail(canonicalRaw, model.DetailRequest{ExecutionID: "canonical", Items: []string{"start-row"}})
	must(err)
	if len(canonicalProjection.Items) != 1 || canonicalProjection.Items[0].Label != "final label" || canonicalProjection.Items[0].Bodies[0].Length != len("final detail") {
		panic("Claude canonical activity was not selected once with final detail")
	}
	canonicalBody, err := messageDetail.ReadDetailBody(canonicalRaw, model.DetailBodyRequest{ExecutionID: "canonical", ItemID: "start-row", Slot: "detail"})
	must(err)
	if canonicalBody.Text != "final detail" {
		panic("Claude canonical activity body did not use the final detail")
	}

	codexState := codex.StageExecution(codex.EmptyState(1), "codex-detail",
		codex.Map{"parts": []any{codex.Map{"kind": "text", "text": "prompt"}}}, 2, nil)
	codexState = codex.ReduceEvent(codexState, "codex-detail", codex.Map{"type": "activity-start", "activity": codex.Map{"id": "small", "kind": "command", "label": "small tool", "toolCall": true}, "at": 3})
	codexState = codex.ReduceEvent(codexState, "codex-detail", codex.Map{"type": "activity-end", "activityId": "small", "status": "completed", "detail": small, "at": 4})
	codexState = codex.ReduceEvent(codexState, "codex-detail", codex.Map{"type": "text-final", "itemId": "separator", "text": "separator", "at": 5})
	codexMap := decode(encode(codexState))
	codexTurn := codexMap["turns"].([]any)[0].(map[string]any)
	codexTimeline := codexTurn["timeline"].([]any)
	for index, value := range codexTimeline {
		if value.(map[string]any)["activityId"] == "small" {
			duplicate := map[string]any{"id": "duplicate-small-row", "kind": "activity", "activityId": "small", "createdAt": 4}
			codexTimeline = append(codexTimeline[:index+1], append([]any{duplicate}, codexTimeline[index+1:]...)...)
			break
		}
	}
	codexTurn["timeline"] = codexTimeline
	codexState = codexMap
	codexState = codex.ReduceEvent(codexState, "codex-detail", codex.Map{"type": "activity-start", "activity": codex.Map{"id": "huge", "kind": "command", "label": "huge tool", "toolCall": true}, "at": 6})
	codexState = codex.ReduceEvent(codexState, "codex-detail", codex.Map{"type": "activity-end", "activityId": "huge", "status": "completed", "detail": huge, "at": 7})
	codexState = codex.ReduceEvent(codexState, "codex-detail", codex.Map{"type": "done", "outcome": "completed", "at": 8})
	smallRow, hugeRow := codexActivityRows(codexState)
	verifyAdapterDetail("codex", codex.NewSessionStateAdapter(), encode(codexState), "turn:codex-detail", smallRow, hugeRow, "detail", small, huge, false)

	piState := pi.State{Version: 1, Messages: []pi.MessageState{
		{ID: "small-row", ExecutionID: "pi-detail", Role: "tool", Text: small, ToolCallID: "small", ToolName: "tool"},
		{ID: "huge-row", ExecutionID: "pi-detail", Role: "tool", Text: huge, ToolCallID: "huge", ToolName: "tool"},
	}, Executions: []model.PublicExecution{{ExecutionID: "pi-detail", Status: "completed", StartedAt: 1, FinishedAt: int64Pointer(2)}}, LatestExecutionID: stringPointer("pi-detail")}
	verifyAdapterDetail("pi", (&pi.Adapter{}).SessionState(), encode(piState), "pi-detail", "small-row", "huge-row", "text", small, huge, false)
	verifyPiIdentityCollisions()

	openCodeState := opencode.State{Version: openCodeFixtureVersion(), NativeSessionID: "session", Messages: []*opencode.Message{
		{ID: "small-row", ExecutionID: "oc-detail", Role: "tool", Result: small, ToolName: "tool", Status: "complete"},
		{ID: "huge-row", ExecutionID: "oc-detail", Role: "tool", Result: huge, ToolName: "tool", Status: "complete"},
		{ID: "child-row", ExecutionID: "oc-detail", Role: "tool", Result: small, ToolName: "child tool", Status: "complete", NativeSessionID: "child"},
		{ID: "assistant-row", ExecutionID: "oc-detail", Role: "assistant", Status: "complete",
			Parts: []opencode.Part{{Type: "text", Ordinal: 0, Text: "assistant detail"}}},
	}, Executions: []*model.PublicExecution{{ExecutionID: "oc-detail", Status: "completed", StartedAt: 1, FinishedAt: int64Pointer(2)}}, LatestExecutionID: stringPointer("oc-detail")}
	openCodeRaw := encode(openCodeState)
	verifyAdapterDetail("opencode", opencode.StateAdapter{}, openCodeRaw, "oc-detail", "small-row", "huge-row", "result", small, huge, true)
	childRow := "opencode-child-session:" + string(encode([]string{"oc-detail", "child"}))
	childDetail, ok := any(opencode.StateAdapter{}).(plugin.DetailStateAdapter)
	if !ok {
		panic("OpenCode adapter does not expose detail resources")
	}
	childProjection, err := childDetail.ProjectDetail(openCodeRaw, model.DetailRequest{ExecutionID: "oc-detail", Items: []string{childRow}})
	must(err)
	if len(childProjection.Items) != 1 || childProjection.Items[0].ID != "child-row" {
		panic(fmt.Sprintf("OpenCode child-session detail did not resolve its message identities: row=%q items=%+v", childRow, childProjection.Items))
	}
	assistantProjection, err := childDetail.ProjectDetail(openCodeRaw, model.DetailRequest{ExecutionID: "oc-detail", Items: []string{"assistant-row:text:0"}})
	must(err)
	if len(assistantProjection.Items) != 1 || assistantProjection.Items[0].Kind != "message" ||
		len(assistantProjection.Items[0].Bodies) != 1 || assistantProjection.Items[0].Bodies[0].Length != len("assistant detail") {
		panic("OpenCode #318 assistant parts did not resolve into detail metadata")
	}
	assistantBody, err := childDetail.ReadDetailBody(openCodeRaw, model.DetailBodyRequest{ExecutionID: "oc-detail", ItemID: "assistant-row:text:0", Slot: "content"})
	must(err)
	if assistantBody.Text != "assistant detail" {
		panic("OpenCode #318 assistant parts did not resolve into body text")
	}
	verifyOpenCodeChildOrder(childDetail)
}

func verifyOpenCodeChildOrder(detail plugin.DetailStateAdapter) {
	state := opencode.State{Version: openCodeFixtureVersion(), NativeSessionID: "root", Messages: []*opencode.Message{
		{ID: "before-row", ExecutionID: "oc-order", Role: "tool", Result: "before", ToolName: "before", Status: "complete"},
		{ID: "child-row", ExecutionID: "oc-order", Role: "tool", Result: "child", ToolName: "child", Status: "complete", NativeSessionID: "child"},
		{ID: "after-row", ExecutionID: "oc-order", Role: "tool", Result: "after", ToolName: "after", Status: "complete"},
		{ID: "nested-row", ExecutionID: "oc-order", Role: "tool", Result: "nested", ToolName: "nested", Status: "complete", NativeSessionID: "nested"},
	}, Executions: []*model.PublicExecution{{ExecutionID: "oc-order", Status: "completed", StartedAt: 1, FinishedAt: int64Pointer(2)}}, LatestExecutionID: stringPointer("oc-order")}
	raw := encode(state)
	childRow := "opencode-child-session:" + string(encode([]string{"oc-order", "child"}))
	nestedRow := "opencode-child-session:" + string(encode([]string{"oc-order", "nested"}))
	projection, err := detail.ProjectDetail(raw, model.DetailRequest{ExecutionID: "oc-order", Items: []string{childRow, "after-row"}})
	must(err)
	var ids []string
	for _, item := range projection.Items {
		ids = append(ids, item.ID)
	}
	if len(ids) != 2 || ids[0] != "child-row" || ids[1] != "after-row" {
		panic(fmt.Sprintf("OpenCode child detail order diverged from the reader: %v", ids))
	}
	nestedProjection, err := detail.ProjectDetail(raw, model.DetailRequest{ExecutionID: "oc-order", Items: []string{nestedRow}})
	must(err)
	if len(nestedProjection.Items) != 1 || nestedProjection.Items[0].ID != "nested-row" {
		panic(fmt.Sprintf("OpenCode separate child session did not resolve: %+v", nestedProjection.Items))
	}
	nestedBody, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "oc-order", ItemID: "nested-row", Slot: "result"})
	must(err)
	if nestedBody.Text != "nested" {
		panic("OpenCode child-session body did not resolve its exact native message")
	}
}

func verifyPiIdentityCollisions() {
	errorText := "execution detail"
	state := pi.State{Version: 1, Messages: []pi.MessageState{
		{ID: "foo", ExecutionID: "pi-collision", Role: "assistant", Text: "base text", Thinking: "foo reasoning", Status: "complete"},
		{ID: "foo:thinking", ExecutionID: "pi-collision", Role: "assistant", Text: "literal suffix text", Status: "complete"},
		{ID: "execution-error", ExecutionID: "pi-collision", Role: "assistant", Text: "literal error id text", Status: "complete"},
	}, Executions: []model.PublicExecution{{ExecutionID: "pi-collision", Status: "failed", StartedAt: 1, FinishedAt: int64Pointer(2), Error: &errorText}}, LatestExecutionID: stringPointer("pi-collision")}
	raw := encode(state)
	detail := (&pi.Adapter{}).SessionState().(plugin.DetailStateAdapter)
	items := []string{"foo", "\x00pi:thinking:foo", "foo:thinking", "\x00pi:execution-error", "execution-error"}
	projection, err := detail.ProjectDetail(raw, model.DetailRequest{ExecutionID: "pi-collision", Items: items})
	must(err)
	ids := map[string]model.DetailItem{}
	for _, item := range projection.Items {
		ids[item.ID] = item
	}
	if len(ids) != 4 {
		panic(fmt.Sprintf("Pi synthetic identities collided: %+v", ids))
	}
	if body, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "pi-collision", ItemID: "foo:thinking", Slot: "text"}); err != nil || body.Text != "literal suffix text" {
		panic("Pi literal :thinking id was misread as a reasoning suffix")
	}
	if body, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "pi-collision", ItemID: "\x00pi:thinking:foo", Slot: "thinking"}); err != nil || body.Text != "foo reasoning" {
		panic("Pi synthetic thinking id did not resolve")
	}
	if body, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "pi-collision", ItemID: "execution-error", Slot: "text"}); err != nil || body.Text != "literal error id text" {
		panic("Pi literal execution-error id was misread as the synthetic error")
	}
	if _, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "pi-collision", ItemID: "\x00pi:execution-error", Slot: "detail"}); err == nil {
		panic("Pi execution error is still exposed as an unreachable detail resource")
	}
	verifyPiLongIdentities(detail)
}

func verifyPiLongIdentities(detail plugin.DetailStateAdapter) {
	short := strings.Repeat("a", 243)
	long := strings.Repeat("a", 244)
	overlong := strings.Repeat("m", 300)
	state := pi.State{Version: 1, Messages: []pi.MessageState{
		{ID: short, ExecutionID: "pi-long", Role: "assistant", Text: "short text", Thinking: "short thinking", Status: "complete"},
		{ID: long, ExecutionID: "pi-long", Role: "assistant", Text: "long text", Thinking: "long thinking", Status: "complete"},
		{ID: overlong, ExecutionID: "pi-long", Role: "assistant", Text: "overlong text", Status: "complete"},
	}, Executions: []model.PublicExecution{{ExecutionID: "pi-long", Status: "completed", StartedAt: 1, FinishedAt: int64Pointer(2)}}, LatestExecutionID: stringPointer("pi-long")}
	raw := encode(state)
	thinkingPrefix, messagePrefix := "\x00pi:thinking:", "\x00pi:message:"
	digest := func(id string) string {
		sum := sha256.Sum256([]byte(id))
		return hex.EncodeToString(sum[:])
	}
	thinkingShort := thinkingPrefix + short
	thinkingLong := thinkingPrefix + digest(long)
	messageOverlong := messagePrefix + digest(overlong)
	projection, err := detail.ProjectDetail(raw, model.DetailRequest{ExecutionID: "pi-long",
		Items: []string{short, thinkingShort, long, thinkingLong, messageOverlong}})
	must(err)
	if len(projection.Items) != 5 {
		panic(fmt.Sprintf("Pi long identity selection dropped rows: %+v", projection.Items))
	}
	for _, item := range projection.Items {
		if utf16LengthOf(item.ID) > 256 {
			panic("Pi long identity exceeded the transport bound")
		}
	}
	if projection.Items[0].ID != thinkingShort || projection.Items[1].ID != short {
		panic("Pi identity changed before the NUL suffix reached the bound")
	}
	if projection.Items[2].ID != thinkingLong || projection.Items[3].ID != long {
		panic("Pi message identity changed before the transport bound")
	}
	if projection.Items[4].ID != messageOverlong {
		panic("Pi overlong message identity was not namespaced")
	}
	for itemID, expected := range map[string][2]string{
		thinkingLong:    {"thinking", "long thinking"},
		messageOverlong: {"text", "overlong text"},
	} {
		body, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: "pi-long", ItemID: itemID, Slot: expected[0]})
		must(err)
		if body.Text != expected[1] {
			panic("Pi overlong identity did not resolve its body")
		}
	}
}

func utf16LengthOf(text string) int {
	length := 0
	for _, value := range text {
		if value > 0xffff {
			length += 2
		} else {
			length++
		}
	}
	return length
}

func verifyAdapterDetail(name string, adapter plugin.SessionStateAdapter, raw json.RawMessage, execution, smallRow, hugeRow, slot, small, huge string, deferredLength bool) {
	detail, ok := adapter.(plugin.DetailStateAdapter)
	if !ok {
		panic(name + " adapter does not expose detail resources")
	}
	projection, err := detail.ProjectDetail(raw, model.DetailRequest{ExecutionID: execution, Items: []string{smallRow}})
	must(err)
	expectedLength := len(small)
	if deferredLength {
		// OpenCode defers tool display formatting; the first body page names
		// the authoritative length.
		expectedLength = 0
	}
	if len(projection.Items) != 1 || projection.Items[0].ID != smallRow || len(projection.Items[0].Bodies) != 1 ||
		projection.Items[0].Bodies[0].Length != expectedLength || projection.Items[0].Bodies[0].Text != "" {
		panic(name + ": detail selection did not preserve only the requested row metadata")
	}
	selected, err := json.Marshal(projection)
	must(err)
	if bytes.Contains(selected, []byte("HUGE_BODY_MARKER")) || bytes.Contains(selected, []byte(small)) {
		panic(name + ": a body entered the directory projection")
	}
	smallBody, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: execution, ItemID: smallRow, Slot: slot})
	must(err)
	if smallBody.Text != small {
		panic(name + ": exact small body did not resolve")
	}
	body, err := detail.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: execution, ItemID: hugeRow, Slot: slot})
	must(err)
	// Harnesses may retain a bounded native window; the detail body must expose
	// exactly that retained value rather than the original fixture input.
	if len(body.Text) <= 4096 || len(body.Text) > len(huge) || !utf8.ValidString(body.Text) {
		panic(name + ": selected detail body is not the retained source content")
	}
	version := model.DetailBodyVersion(execution, hugeRow, slot, body.Text)
	if model.DetailBodyVersion(execution, hugeRow, slot, body.Text+"changed") == version {
		panic(name + ": detail version did not bind changed content")
	}
	var assembled strings.Builder
	offset, envelopes := 0, 0
	for {
		chunk, next, err := model.DetailChunkText(body.Text, offset, 4096)
		must(err)
		if !utf8.ValidString(chunk) {
			panic(name + ": detail chunk split Unicode")
		}
		assembled.WriteString(chunk)
		envelopes++
		if next == len(body.Text) {
			break
		}
		cursorVersion, cursorOffset, ok := model.DecodeDetailCursor(model.EncodeDetailCursor(version, next))
		if !ok || cursorVersion != version || cursorOffset != next {
			panic(name + ": detail cursor did not round trip")
		}
		offset = next
	}
	if envelopes < 2 || assembled.String() != body.Text {
		panic(name + ": detail chunks did not reassemble the source body")
	}
	fmt.Printf("%s/detail selected=%d bytes huge=%d chunks=%d bytes\n", name, len(selected), len(body.Text), envelopes)
}

func openCodeFixtureVersion() int {
	for _, version := range []int{2, 1} {
		raw := encode(map[string]any{"version": version, "messages": []any{}, "executions": []any{}})
		if _, err := opencode.DecodeState(raw); err == nil {
			return version
		}
	}
	return 1
}

func codexActivityRows(state codex.Map) (string, string) {
	turn := decode(encode(state))["turns"].([]any)[0].(map[string]any)
	rows := []string{}
	for _, value := range turn["timeline"].([]any) {
		item := value.(map[string]any)
		if item["kind"] == "activity" {
			rows = append(rows, item["id"].(string))
		}
	}
	if len(rows) < 2 {
		panic("Codex fixture did not produce separated activity rows")
	}
	return rows[0], rows[len(rows)-1]
}

func stringPointer(value string) *string { return &value }
func int64Pointer(value int64) *int64    { return &value }

func verifyClaudeHistory() {
	s := claude.NewState()
	s.ForkHistory = map[string]any{"sourceSessionId": "source", "items": []any{
		map[string]any{"id": "prompt", "kind": "user-message", "content": "prompt", "createdAt": 1},
		map[string]any{"id": "plan", "kind": "plan", "plan": []any{map[string]any{"step": "hidden", "status": "pending"}}, "createdAt": 2},
	}}
	raw := encode(s)
	adapter := claude.StateAdapter{}
	full, err := projectReader("claude-history", adapter, raw, model.RendererScope{Kind: "execution", Key: "fork-history"})
	must(err)
	reading, err := projectReader("claude-history", adapter, raw, model.RendererScope{Kind: "turn", Key: "fork-history"})
	must(err)
	state := decode(reading)["state"].(map[string]any)
	items := state["forkHistory"].(map[string]any)["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["content"] != "prompt" {
		panic("Claude inherited reader lost prompt or retained plan")
	}
	if len(decode(full)["forkHistory"].(map[string]any)["items"].([]any)) != 2 {
		panic("Claude inherited full execution lost plan")
	}
	fmt.Printf("claude/history full=%d reader=%d bytes\n", len(full), len(reading))
}
