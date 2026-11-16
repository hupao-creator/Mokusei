package opencode

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const testTransportContentLimit = 32<<20 - 256<<10

func TestRendererBoundsLargeToolField(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	state := State{
		Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages: []*Message{
			{ID: "user", ExecutionID: "exec", Role: "user", Text: "hello"},
			{ID: "assistant", ExecutionID: "exec", Role: "assistant"},
			{ID: "tool", ExecutionID: "exec", Role: "tool", ToolCallID: "call", ToolName: "read", Status: "complete",
				Arguments: Object{"path": "a"}, Result: strings.Repeat("x", 34<<20)},
		},
	}
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	if len(projected) > rendererWireBudget || len(projected) > testTransportContentLimit {
		t.Fatalf("projection escaped both budgets: %d bytes", len(projected))
	}
	var value map[string]any
	if err := json.Unmarshal(projected, &value); err != nil {
		t.Fatal(err)
	}
	if value["contentTruncated"] != true {
		t.Fatal("large projection did not advertise truncation")
	}
	tool := value["messages"].([]any)[2].(map[string]any)
	if text := tool["resultDisplay"].(string); len(text) > rendererStages[0].tool {
		t.Fatalf("tool resultDisplay retained %d bytes", len(text))
	}
	for _, key := range []string{"text", "result", "arguments"} {
		if _, exists := tool[key]; exists {
			t.Fatalf("tool projection retained retired field %q", key)
		}
	}
}

func TestRendererBoundsDeferredNonempty(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	messages := make([]*Message, 1_000)
	for index := range messages {
		parts := make([]Part, 64)
		for part := range parts {
			parts[part] = Part{Type: "reasoning", Ordinal: part, Text: "x"}
		}
		messages[index] = &Message{ID: fmt.Sprintf("m-%d", index), ExecutionID: "exec", Role: "assistant", Status: "complete", Parts: parts}
	}
	state := State{
		Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages:   messages,
	}
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "turn", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal(projected, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope["kind"] != "deferred-execution" {
		t.Fatalf("unexpected deferred envelope: %v", envelope["kind"])
	}
	if nonempty := envelope["nonempty"].([]any); len(nonempty) != len(messages)*64 {
		t.Fatalf("fixture presence count = %d", len(nonempty))
	}
	// Every marker references a real deferred reasoning part. The full set is
	// larger than the first degradation stage's 2 MiB presence budget, so this
	// exercises truncation rather than the syntactic field filter. A fresh
	// oversized user body forces that stage during the second encode.
	hostile := make([]any, 0, len(messages)*64)
	for message := range messages {
		for part := 0; part < 64; part++ {
			hostile = append(hostile, map[string]any{
				"id": fmt.Sprintf("m-%d", message), "field": fmt.Sprintf("parts:reasoning:%d", part),
			})
		}
	}
	envelope["nonempty"] = hostile
	stateValue := envelope["state"].(map[string]any)
	stateValue["messages"] = append(stateValue["messages"].([]any), map[string]any{
		"id": "huge-user", "executionId": "exec", "role": "user", "text": strings.Repeat("u", 25<<20),
	})
	bounded, err := rendererMarshalProjection(envelope)
	if err != nil {
		t.Fatal(err)
	}
	if len(bounded) > rendererWireBudget || len(bounded) > testTransportContentLimit {
		t.Fatalf("deferred projection escaped both budgets: %d bytes", len(bounded))
	}
	if err := json.Unmarshal(bounded, &envelope); err != nil {
		t.Fatal(err)
	}
	stateValue = envelope["state"].(map[string]any)
	if stateValue["contentTruncated"] != true {
		t.Fatal("deferred projection did not advertise truncation")
	}
	messagesByID := map[string]map[string]any{}
	for _, raw := range stateValue["messages"].([]any) {
		message := raw.(map[string]any)
		messagesByID[message["id"].(string)] = message
	}
	nonempty := envelope["nonempty"].([]any)
	if len(nonempty) == 0 || len(nonempty) >= len(hostile) {
		t.Fatalf("presence budget retained %d of %d entries", len(nonempty), len(hostile))
	}
	encoded, err := json.Marshal(nonempty)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > 2<<20 {
		t.Fatalf("presence budget escaped: %d bytes", len(encoded))
	}
	seen := map[string]bool{}
	for _, raw := range nonempty {
		entry := raw.(map[string]any)
		id, field := entry["id"].(string), entry["field"].(string)
		key := id + "\x00" + field
		if seen[key] {
			t.Fatalf("duplicate presence entry %q/%q", id, field)
		}
		seen[key] = true
		message, exists := messagesByID[id]
		if !exists {
			t.Fatalf("nonempty references omitted message %q", id)
		}
		if !rendererPresenceField(message, field) {
			t.Fatalf("nonempty references a missing part %q/%q", id, field)
		}
	}
}

func TestRendererFilterNonemptyBudgetKeepsNewestUniqueReferences(t *testing.T) {
	messages := make([]Object, 0, 100)
	original := make([]Object, 0, 4_000)
	for message := 0; message < 100; message++ {
		parts := make([]Object, 0, 40)
		for part := 0; part < 40; part++ {
			parts = append(parts, Object{"type": "reasoning", "ordinal": part, "text": ""})
			original = append(original, Object{"id": fmt.Sprintf("m-%d", message), "field": fmt.Sprintf("parts:reasoning:%d", part)})
		}
		messages = append(messages, Object{"id": fmt.Sprintf("m-%d", message), "executionId": "exec", "role": "assistant", "parts": parts})
	}
	original = append(original, original[:200]...)
	value := Object{"kind": "deferred-execution", "nonempty": original}
	state := Object{"messages": messages}
	rendererFilterNonempty(value, state, original, 2_000)
	entries := value["nonempty"].([]Object)
	if len(entries) == 0 || len(entries) >= len(original) {
		t.Fatalf("presence budget retained %d of %d entries", len(entries), len(original))
	}
	encoded, err := json.Marshal(entries)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > 2_000 {
		t.Fatalf("presence budget escaped: %d bytes", len(encoded))
	}
	seen := map[string]bool{}
	for _, entry := range entries {
		key := rendererText(entry["id"]) + "\x00" + rendererText(entry["field"])
		if seen[key] {
			t.Fatalf("duplicate presence entry %q", key)
		}
		seen[key] = true
	}
	// Filtering walks the newest entries first, then restores chronological
	// order, so the retained suffix must contain the last original marker.
	last := original[len(original)-1]
	if entries[len(entries)-1]["id"] != last["id"] || entries[len(entries)-1]["field"] != last["field"] {
		t.Fatalf("newest presence entry was dropped: %#v", entries[len(entries)-1])
	}
}

func TestRendererPartsTypesAndSkeleton(t *testing.T) {
	limits := rendererStages[1]
	toolMessage := Object{"id": "tool", "executionId": "exec", "role": "tool", "toolCallId": "call", "resultDisplay": "output", "parts": []any{
		Object{"type": "tool", "toolCallId": "call", "ordinal": 7, "text": "unexpected"},
	}}
	rendererBoundMessage(toolMessage, limits)
	toolPart := toolMessage["parts"].([]Object)[0]
	if _, exists := toolPart["ordinal"]; exists {
		t.Fatal("tool part retained a non-contract ordinal")
	}
	if _, exists := toolPart["text"]; exists {
		t.Fatal("tool part retained a non-contract text field")
	}
	for _, parts := range []any{
		[]any{Object{"type": "reasoning", "ordinal": 0, "text": strings.Repeat("x", limits.text+1)}},
		[]Object{{"type": "reasoning", "ordinal": 0, "text": strings.Repeat("x", limits.text+1)}},
	} {
		message := Object{"id": "m", "executionId": "exec", "role": "assistant", "text": "", "parts": parts}
		rendererBoundMessage(message, limits)
		if _, exists := message["text"]; exists {
			t.Fatal("empty assistant aggregate survived bounding")
		}
		bound := message["parts"].([]Object)
		if len(bound) != 1 {
			t.Fatalf("parts normalization lost the part: %#v", message["parts"])
		}
		if text := rendererText(bound[0]["text"]); len(text) > limits.text {
			t.Fatalf("parts text retained %d bytes", len(text))
		}
	}

	state := Object{"messages": make([]Object, 600)}
	messages := state["messages"].([]Object)
	for index := range messages {
		parts := make([]Object, 40)
		for part := range parts {
			parts[part] = Object{"type": "reasoning", "ordinal": part, "text": strings.Repeat("x", 10_000)}
		}
		messages[index] = Object{"id": fmt.Sprintf("m-%d", index), "executionId": "exec", "role": "assistant", "parts": parts}
	}
	rendererApplyLimits(state, state, nil, rendererStages[2])
	messages = state["messages"].([]Object)
	if len(messages) != 500 {
		t.Fatalf("skeleton retained %d messages", len(messages))
	}
	if parts := messages[0]["parts"].([]Object); len(parts) > rendererStages[2].parts {
		t.Fatalf("skeleton retained %d parts", len(parts))
	}
	if _, exists := messages[0]["text"]; exists {
		t.Fatal("bound assistant gained a synthetic text field")
	}
	if text := rendererText(messages[0]["parts"].([]Object)[0]["text"]); len(text) > rendererStages[2].text {
		t.Fatalf("skeleton retained %d part text bytes", len(text))
	}
	rendererApplyLimits(state, state, nil, rendererStages[3])
	if messages = state["messages"].([]Object); len(messages) != rendererStages[3].messages {
		t.Fatalf("hard limit retained %d messages", len(messages))
	}
}

func TestRendererBoundsExecutionsAndInteractions(t *testing.T) {
	latest := "exec-000"
	executions := make([]Object, 501)
	for index := range executions {
		executions[index] = Object{
			"executionId": fmt.Sprintf("exec-%03d", index), "status": "completed",
			"startedAt": 0, "finishedAt": 1, "summary": strings.Repeat("s", 10_000),
		}
	}
	state := Object{"executions": executions, "latestExecutionId": &latest}
	rendererBoundExecutions(state, rendererStages[1])
	bound := state["executions"].([]Object)
	if len(bound) > rendererStages[1].executions {
		t.Fatalf("retained %d executions", len(bound))
	}
	if current, ok := state["latestExecutionId"].(string); !ok || current != latest {
		t.Fatalf("latestExecutionId normalized to %#v", state["latestExecutionId"])
	}
	found := false
	for _, execution := range bound {
		found = found || execution["executionId"] == latest
	}
	if !found {
		t.Fatal("latest execution was trimmed")
	}

	interactions := make([]Object, 501)
	for index := range interactions {
		interactions[index] = Object{
			"id": fmt.Sprintf("int-%d", index), "executionId": "exec", "sessionId": "session",
			"kind": "permission", "title": strings.Repeat("t", 10_000), "status": "pending",
			"action": "allow", "resources": []any{"resource"}, "save": []any{},
		}
	}
	top := Object{"interactions": interactions}
	rendererBoundTopInteractions(top, rendererStages[1])
	boundInteractions := top["interactions"].([]Object)
	if len(boundInteractions) > rendererStages[1].interactions {
		t.Fatalf("retained %d native interactions", len(boundInteractions))
	}
	if title := boundInteractions[0]["title"].(string); len(title) > rendererStages[1].short {
		t.Fatalf("interaction title retained %d bytes", len(title))
	}

	waitingInteractions := make([]Object, 100)
	for index := range waitingInteractions {
		waitingInteractions[index] = Object{
			"id": fmt.Sprintf("public-%d", index), "kind": "permission",
			"title":     strings.Repeat("t", 10_000),
			"actions":   []any{Object{"id": "allow", "intent": "allow", "label": strings.Repeat("l", 10_000)}},
			"questions": []any{},
		}
	}
	waiting := Object{"executionId": "exec", "status": "waiting-for-user", "startedAt": 0, "interactions": waitingInteractions}
	execution, ok := rendererBoundExecution(waiting, rendererStages[1], map[string]bool{})
	if !ok {
		t.Fatal("waiting execution was dropped")
	}
	if list := execution["interactions"].([]Object); len(list) > rendererStages[1].interactions {
		t.Fatalf("retained %d public interactions", len(list))
	}

	latestPointer := latest
	wholeState := Object{
		"version": 1, "messages": []Object{}, "executions": executions,
		"latestExecutionId": &latestPointer,
		"interactions": []Object{{
			"id": "huge", "executionId": "exec", "sessionId": "session", "kind": "permission",
			"title": strings.Repeat("t", 34<<20), "status": "pending", "action": "allow",
			"resources": []any{"/workspace/document"}, "save": []any{},
		}},
	}
	projected, err := rendererMarshalProjection(wholeState)
	if err != nil {
		t.Fatal(err)
	}
	if len(projected) > rendererWireBudget || len(projected) > testTransportContentLimit {
		t.Fatalf("whole execution envelope escaped both budgets: %d bytes", len(projected))
	}
	var value map[string]any
	if err = json.Unmarshal(projected, &value); err != nil {
		t.Fatal(err)
	}
	if value["contentTruncated"] != true || value["latestExecutionId"] != latest {
		t.Fatalf("whole envelope lost truncation/latest state: %#v", value["latestExecutionId"])
	}
}

func TestRendererBudgetBoundaryAndMinimalFallback(t *testing.T) {
	underState := Object{
		"version": 1, "messages": []Object{{"id": "m", "executionId": "exec", "role": "user",
			"text": strings.Repeat("u", rendererWireBudget-128<<10)}},
		"executions": []Object{}, "latestExecutionId": nil, "interactions": []Object{},
	}
	under, err := rendererMarshalProjection(underState)
	if err != nil {
		t.Fatal(err)
	}
	var underValue map[string]any
	if err := json.Unmarshal(under, &underValue); err != nil {
		t.Fatal(err)
	}
	if len(under) > rendererWireBudget || underValue["contentTruncated"] != nil {
		t.Fatalf("projection below the budget changed: %d bytes", len(under))
	}

	overState := Object{
		"version": 1, "messages": []Object{{"id": "m", "executionId": "exec", "role": "user",
			"text": strings.Repeat("u", rendererWireBudget+64<<10)}},
		"executions": []Object{}, "latestExecutionId": nil, "interactions": []Object{},
	}
	over, err := rendererMarshalProjection(overState)
	if err != nil {
		t.Fatal(err)
	}
	var overValue map[string]any
	if err := json.Unmarshal(over, &overValue); err != nil {
		t.Fatal(err)
	}
	if len(over) > rendererWireBudget || overValue["contentTruncated"] != true {
		t.Fatalf("projection above the budget was not degraded: %d bytes", len(over))
	}

	latest := "exec"
	hostile := Object{
		"version": 1, "messages": []Object{}, "executions": []Object{
			{"executionId": latest, "status": "completed", "startedAt": 10, "finishedAt": 20},
		}, "latestExecutionId": latest, "interactions": []Object{},
		"junk": map[string]any{strings.Repeat("k", rendererWireBudget+1): true},
	}
	envelope := Object{"kind": "deferred-execution", "state": hostile, "nonempty": []Object{}}
	minimal, err := rendererMarshalProjection(envelope)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(minimal, &value); err != nil {
		t.Fatal(err)
	}
	if len(minimal) > testTransportContentLimit || value["kind"] == "deferred-execution" ||
		value["contentTruncated"] != true || value["junk"] != nil {
		t.Fatalf("final fallback was not minimal/legal: %d bytes %#v", len(minimal), value)
	}
	execution := value["executions"].([]any)[0].(map[string]any)
	if execution["status"] != "completed" || execution["startedAt"] != float64(10) || execution["finishedAt"] != float64(20) {
		t.Fatal("minimal fallback invented a different execution outcome")
	}
}

func TestRendererBoundsAssistantTextWithoutSyntheticAggregate(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	state := State{
		Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages: []*Message{
			{ID: "user", ExecutionID: "exec", Role: "user", Text: "hello"},
			{ID: "assistant", ExecutionID: "exec", Role: "assistant", Status: "complete",
				Parts: []Part{{Type: "text", Ordinal: 0, Text: strings.Repeat("x", 25<<20)}}},
		},
	}
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	if len(projected) > rendererWireBudget {
		t.Fatalf("projection escaped budget: %d bytes", len(projected))
	}
	var value map[string]any
	if err = json.Unmarshal(projected, &value); err != nil {
		t.Fatal(err)
	}
	if value["contentTruncated"] != true {
		t.Fatal("oversized assistant projection did not advertise truncation")
	}
	assistant := value["messages"].([]any)[1].(map[string]any)
	if text, exists := assistant["text"]; exists {
		t.Fatalf("assistant projection gained text %#v", text)
	}
	parts := assistant["parts"].([]any)
	if len(parts) != 1 || parts[0].(map[string]any)["type"] != "text" {
		t.Fatalf("assistant text part was lost: %#v", parts)
	}
	if text := parts[0].(map[string]any)["text"].(string); text == "" {
		t.Fatal("assistant text part was erased by degradation")
	}
}

func TestRendererFormConditionUsesKey(t *testing.T) {
	field := Object{
		"type": "string", "key": "detail", "required": false,
		"when": []any{Object{"key": "mode", "op": "eq", "value": "a"}},
	}
	bound, ok := rendererBoundFormField(field, rendererStages[1])
	if !ok {
		t.Fatal("conditional form field was dropped")
	}
	conditions := rendererObjects(bound["when"])
	if len(conditions) != 1 || conditions[0]["key"] != "mode" {
		t.Fatalf("conditional form condition lost its key: %#v", conditions)
	}
	if _, exists := conditions[0]["questionId"]; exists {
		t.Fatal("native form condition used public questionId field")
	}
}

func TestRendererDeferredPresenceSurvivesTruncation(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	state := State{
		Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages: []*Message{{
			ID: "assistant", ExecutionID: "exec", Role: "assistant", Status: "complete",
			Parts: []Part{
				{Type: "reasoning", Ordinal: 0, Text: "retained reasoning"},
				{Type: "text", Ordinal: 1, Text: strings.Repeat("a", 30<<20)},
			},
		}},
	}
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "turn", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal(projected, &envelope); err != nil {
		t.Fatal(err)
	}
	nonempty := envelope["nonempty"].([]any)
	if len(nonempty) == 0 {
		t.Fatal("deferred presence collapsed to an empty array")
	}
	found := false
	for _, raw := range nonempty {
		entry := raw.(map[string]any)
		if entry["id"] == "assistant" && entry["field"] == "parts:reasoning:0" {
			found = true
		}
	}
	if !found {
		t.Fatalf("retained reasoning presence was lost: %#v", nonempty)
	}
}

func TestRendererRejectsUnreferenceableIDs(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	long := strings.Repeat("x", 300)
	state := State{
		Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages: []*Message{
			{ID: "user", ExecutionID: "exec", Role: "user", Text: "hello"},
			{ID: long, ExecutionID: "exec", Role: "assistant", Parts: []Part{{Type: "text", Ordinal: 0, Text: "long message id"}}},
			{ID: "assistant", ExecutionID: "exec", Role: "assistant", Parts: []Part{{Type: "tool", ToolCallID: long}}},
			{ID: "tool", ExecutionID: "exec", Role: "tool", ToolCallID: long, ToolName: "read", Result: "output"},
			{ID: "huge", ExecutionID: "exec", Role: "assistant", Parts: []Part{{Type: "text", Ordinal: 0, Text: strings.Repeat("h", 30<<20)}}},
		},
		Interactions: []*Interaction{{ID: long, ExecutionID: "exec", SessionID: "session", Kind: "permission", Title: "Long", Status: "pending"}},
	}
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(projected, &value); err != nil {
		t.Fatal(err)
	}
	if value["contentTruncated"] != true {
		t.Fatal("long-ID fixture did not exercise the fallback")
	}
	if strings.Contains(string(projected), long) {
		t.Fatal("projection retained an unreferenceable identity")
	}
	for _, message := range rendererObjects(value["messages"]) {
		if message["id"] == long || message["toolCallId"] == long {
			t.Fatal("oversized message identity survived")
		}
		for _, part := range rendererObjects(message["parts"]) {
			if part["toolCallId"] == long {
				t.Fatal("oversized tool identity survived")
			}
		}
	}
	if list := rendererObjects(value["interactions"]); len(list) != 0 {
		t.Fatalf("oversized native interaction survived: %#v", list)
	}

	longExecution := strings.Repeat("e", 200)
	message := &Message{ID: "message", ExecutionID: longExecution, Role: "assistant", Parts: []Part{{Type: "text", Ordinal: 0, Text: "text"}}}
	latestLong := longExecution
	summary := strings.Repeat("s", 30<<20)
	invalid := State{
		Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latestLong,
		Executions: []*model.PublicExecution{{ExecutionID: longExecution, Status: "completed", StartedAt: 0, FinishedAt: &finished, Summary: &summary}},
		Messages:   []*Message{message},
	}
	projected, err = (StateAdapter{}).ProjectRenderer(invalid.Encode(), model.RendererScope{Kind: "execution", Key: longExecution})
	if err != nil {
		t.Fatal(err)
	}
	var invalidValue map[string]any
	if err := json.Unmarshal(projected, &invalidValue); err != nil {
		t.Fatal(err)
	}
	if invalidValue["contentTruncated"] != true {
		t.Fatal("invalid execution fixture did not exercise the fallback")
	}
	if len(rendererObjects(invalidValue["executions"])) != 0 || len(rendererObjects(invalidValue["messages"])) != 0 ||
		invalidValue["latestExecutionId"] != nil {
		t.Fatalf("invalid execution identity was not rejected: %#v", invalidValue)
	}
}

func TestRendererWaitingInteractionCorrespondence(t *testing.T) {
	const executionID = "exec"
	public := make([]Object, 50)
	native := make([]Object, 0, 100)
	for index := 0; index < 50; index++ {
		nativeID := fmt.Sprintf("int-%d", index)
		public[index] = Object{
			"id": opaque("interaction", executionID, nativeID), "kind": "permission", "title": "Request",
			"actions": []any{Object{"id": "allow", "intent": "allow", "label": "Allow"}}, "questions": []any{},
		}
		native = append(native, Object{
			"id": nativeID, "executionId": executionID, "sessionId": "session", "kind": "permission",
			"title": "Request", "status": "pending", "action": "allow", "resources": []any{}, "save": []any{},
		})
	}
	for index := 0; index < 50; index++ {
		native = append(native, Object{
			"id": fmt.Sprintf("old-%d", index), "executionId": executionID, "sessionId": "session", "kind": "permission",
			"title": "Old", "status": "answered", "action": "allow", "resources": []any{}, "save": []any{},
		})
	}
	state := Object{
		"version": 1, "messages": []Object{}, "latestExecutionId": executionID,
		"executions": []Object{{
			"executionId": executionID, "status": "waiting-for-user", "startedAt": 0, "interactions": public,
		}},
		"interactions": native,
	}
	rendererApplyLimits(state, state, nil, rendererStages[1])
	top := state["interactions"].([]Object)
	execution := state["executions"].([]Object)[0]
	public = execution["interactions"].([]Object)
	if len(top) == 0 || len(public) == 0 {
		t.Fatalf("waiting interaction pair collapsed: native=%d public=%d", len(top), len(public))
	}
	nativeIDs := map[string]bool{}
	for _, interaction := range top {
		if interaction["status"] != "pending" {
			t.Fatal("answered interaction crowded out pending interaction")
		}
		nativeIDs[opaque("interaction", rendererText(interaction["executionId"]), rendererText(interaction["id"]))] = true
	}
	for _, interaction := range public {
		if !nativeIDs[rendererText(interaction["id"])] {
			t.Fatalf("public interaction %q lost its native counterpart", interaction["id"])
		}
	}
}

func TestRendererBoundHelperContracts(t *testing.T) {
	limits := rendererStages[1]

	question, ok := rendererBoundQuestion(Object{
		"id": "opencode-question-1", "prompt": strings.Repeat("p", 10_000),
		"multiple": true, "allowOther": true, "secret": false,
		"options": []any{
			Object{"value": strings.Repeat("a", 3_000), "label": strings.Repeat("b", 3_000)},
			Object{"value": strings.Repeat("a", 2_999) + "b", "label": "Second"},
		},
	}, limits)
	if !ok || len(question["options"].([]Object)) != 2 {
		t.Fatalf("question fallback failed: %#v", question)
	}
	first, second := question["options"].([]Object)[0], question["options"].([]Object)[1]
	if first["value"] != strings.Repeat("a", 3_000) || second["value"] != strings.Repeat("a", 2_999)+"b" {
		t.Fatal("question option response values changed during display bounding")
	}

	executionState := Object{"executions": []Object{{"executionId": "exec"}}}
	authors := rendererBoundAuthors(map[string]Object{
		"exec":   {"model": strings.Repeat("m", 10_000), "effort": "high"},
		"orphan": {"model": "orphan"},
	}, executionState, limits)
	if len(authors) != 1 || authors["exec"] == nil {
		t.Fatalf("author fallback retained invalid keys: %#v", authors)
	}
	if model := rendererText(authors["exec"]["model"]); len(model) > 4_096 {
		t.Fatalf("author scalar retained %d bytes", len(model))
	}

	foregrounds := rendererBoundForegrounds([]Object{
		{"executionId": "exec", "foreground": Object{"kind": "reasoning", "sequence": 1, "text": strings.Repeat("r", 40_000)}},
		{"executionId": strings.Repeat("x", 200), "foreground": Object{"kind": "assistant-text", "sequence": 1}},
		{"executionId": "exec", "foreground": Object{"kind": "tool-call", "sequence": 2, "callId": "call", "toolName": strings.Repeat("t", 100)}},
	}, limits)
	if len(foregrounds) != 2 {
		t.Fatalf("foreground fallback retained invalid execution: %#v", foregrounds)
	}
	reasoning := foregrounds[0]["foreground"].(Object)
	if units := len([]rune(rendererText(reasoning["text"]))); units > 32_768 {
		t.Fatalf("reasoning retained %d code points", units)
	}

	auxiliary := rendererBoundAuxiliaryUsage([]Object{
		{"id": "sample", "nativeSessionId": "native", "executionId": "exec", "kind": "compaction", "createdAt": 1, "usage": Object{"input": 1}},
		{"id": "bad", "nativeSessionId": "native", "executionId": "exec", "kind": "other", "createdAt": 1, "usage": Object{"input": 1}},
		{"id": "huge", "nativeSessionId": "native", "executionId": "exec", "kind": "compaction", "createdAt": 1, "usage": map[string]any{strings.Repeat("k", 20_000): true}},
	}, limits)
	if len(auxiliary) != 1 || auxiliary[0]["id"] != "sample" {
		t.Fatalf("auxiliary fallback retained invalid samples: %#v", auxiliary)
	}

	if fork, ok := rendererBoundForkSource(Object{"sessionId": "native", "transcript": Object{"data": "dropped"}}, limits); !ok || len(fork["transcript"].(Object)) != 0 {
		t.Fatal("fork source did not drop transcript payload")
	}
	if _, ok := rendererBoundForkSource(Object{"sessionId": strings.Repeat("x", 600)}, limits); ok {
		t.Fatal("fork source accepted an oversized session identity")
	}

	sessions := rendererBoundBackgroundSessions([]Object{
		{"sessionId": "session", "status": "running"},
		{"sessionId": strings.Repeat("x", 600), "status": "running"},
	})
	if len(sessions) != 1 || sessions[0]["sessionId"] != "session" {
		t.Fatalf("background session fallback retained invalid identity: %#v", sessions)
	}
	shells := rendererBoundBackgroundShells([]Object{
		{"shellId": "shell", "sessionId": "session", "status": "idle"},
		{"shellId": strings.Repeat("x", 600), "sessionId": "session", "status": "idle"},
	})
	if len(shells) != 1 || shells[0]["shellId"] != "shell" {
		t.Fatalf("background shell fallback retained invalid identity: %#v", shells)
	}

	value := Object{"text": "<>&\"\n😀", "nested": []any{Object{"key": "value"}}}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if estimate := rendererEncodedSize(value); estimate < len(encoded)-8 || estimate > len(encoded)+32 {
		t.Fatalf("size estimator %d differs from encoding %d", estimate, len(encoded))
	}
}
func TestRendererFallbackPreservesPendingFormContract(t *testing.T) {
	choiceKey := strings.Repeat("k", 17<<10)
	chosen := strings.Repeat("v", 3_000)
	options := make([]any, 70)
	for index := range options {
		options[index] = Object{"value": fmt.Sprintf("option-%d", index), "label": fmt.Sprintf("Option %d", index)}
	}
	options[len(options)-1] = Object{"value": chosen, "label": "Selected option"}
	fields := make([]Object, 65)
	fields[0] = Object{"type": "string", "key": choiceKey, "title": "Choice", "required": true, "options": options, "default": chosen}
	for index := 1; index < len(fields); index++ {
		fields[index] = Object{"type": "string", "key": fmt.Sprintf("field-%d", index), "title": "Required answer", "required": true}
	}
	fields[2]["when"] = []any{Object{"key": "field-1", "op": "neq", "value": "never"}}
	if err := ValidateFields(fields); err != nil {
		t.Fatalf("invalid native form fixture: %v", err)
	}
	latest := "exec"
	state := State{Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions:   []*model.PublicExecution{{ExecutionID: latest, Status: "running", StartedAt: 0}},
		Messages:     []*Message{{ID: "tool", ExecutionID: latest, Role: "tool", ToolCallID: "call", ToolName: "read", Status: "complete", Result: strings.Repeat("x", rendererWireBudget+1)}},
		Interactions: []*Interaction{{ID: "form", ExecutionID: latest, SessionID: "session", Kind: "form", Title: "Required form", Status: "pending", Fields: fields}},
	}
	state.RefreshInteractions(latest)
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: latest})
	if err != nil {
		t.Fatal(err)
	}
	var decoded State
	if err := json.Unmarshal(projected, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(projected) > rendererWireBudget || len(decoded.Interactions) != 1 || len(decoded.Executions) != 1 {
		t.Fatalf("fallback lost the bounded form/execution pair: bytes=%d native=%d executions=%d", len(projected), len(decoded.Interactions), len(decoded.Executions))
	}
	actualFields := decoded.Interactions[0].Fields
	if len(actualFields) != len(fields) {
		t.Errorf("fallback dropped required fields: got %d, want %d", len(actualFields), len(fields))
	}
	if err := ValidateFields(actualFields); err != nil {
		t.Error("fallback corrupted the native form contract")
	}
	if actualFields[0]["key"] != choiceKey {
		t.Error("fallback changed the field key used to derive the public question ID")
	}
	if len(fieldOptions(actualFields[0])) != len(options) || fieldOptions(actualFields[0])[len(fieldOptions(actualFields[0]))-1]["value"] != chosen {
		t.Error("fallback changed the option set/value used to derive response IDs")
	}
	if decoded.Executions[0].Status != "waiting-for-user" || len(decoded.Executions[0].Interactions) != 1 || len(decoded.Executions[0].Interactions[0].Questions) != len(fields) {
		t.Error("fallback changed the authoritative waiting state or public questions")
	}
	answers := make(map[string]json.RawMessage, len(actualFields))
	for index, field := range actualFields {
		key := str(field["key"])
		answer := "answer"
		if index == 0 {
			answer = optionID(decoded.Interactions[0], key, chosen)
		}
		answers[questionID(decoded.Interactions[0], key)], _ = json.Marshal(answer)
	}
	if result := model.ValidatePublicInteractionAnswers(state.Executions[0].Interactions[0], answers); !result.Valid {
		t.Fatalf("answers generated from the fallback form no longer satisfy Core: %v", result.Errors)
	}
}

func TestRendererRejectsUnrepresentablePermissionContract(t *testing.T) {
	latest := "exec"
	state := State{Version: StateVersion, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions:   []*model.PublicExecution{{ExecutionID: latest, Status: "running", StartedAt: 0}},
		Interactions: []*Interaction{{ID: "permission", ExecutionID: latest, SessionID: "session", Kind: "permission", Title: "Allow request", Status: "pending", Action: "read", Resources: []string{strings.Repeat("x", rendererWireBudget+1)}}},
	}
	state.RefreshInteractions(latest)
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: latest})
	if err == nil || !strings.Contains(err.Error(), "response contract") || len(projected) != 0 {
		t.Fatalf("unrepresentable permission must fail without rewriting authorization resources: bytes=%d err=%v", len(projected), err)
	}
}
