package claude

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestActivityTimelineReferenceDeduplicatesUpdates(t *testing.T) {
	for _, status := range []string{"completed", "failed"} {
		t.Run(status, func(t *testing.T) {
			state := NewState()
			turn := state.NewTurn("execution-activity", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "run"}}}, Settings{})
			turn.activity(map[string]any{"id": "command-1", "kind": "command", "label": "Bash", "status": "running"})
			old := strings.Repeat("stale output\n", 5000)
			for update := 0; update < 20; update++ {
				turn.activity(map[string]any{"id": "command-1", "kind": "command", "label": "Bash", "status": "running", "detail": old + fmt.Sprint(update)})
			}
			final := strings.Repeat("final output\n", 5000)
			turn.activityEnd("command-1", status, final)

			raw, err := state.Encode()
			if err != nil {
				t.Fatal(err)
			}
			if _, err := ParseState(raw); err != nil {
				t.Fatal(err)
			}
			if len(turn.Activities) != 1 || turn.Activities[0]["status"] != status || turn.Activities[0]["detail"] != clip(final, 100000) {
				t.Fatalf("current activity = %#v", turn.Activities)
			}
			references := 0
			for _, item := range turn.Timeline {
				if str(item["kind"]) == "activity" {
					references++
					if str(item["activityId"]) != "command-1" || item["activity"] != nil {
						t.Fatalf("timeline activity = %#v", item)
					}
				}
			}
			if references != 1 {
				t.Fatalf("activity references = %d", references)
			}
			finalJSON, _ := json.Marshal(final)
			oldJSON, _ := json.Marshal(old)
			if count := strings.Count(string(raw), string(finalJSON)); count != 1 {
				t.Fatalf("final detail count = %d, wire bytes = %d", count, len(raw))
			}
			if count := strings.Count(string(raw), string(oldJSON)); count != 0 {
				t.Fatalf("stale detail count = %d", count)
			}
			if len(raw) > 200_000 {
				t.Fatalf("repeated updates accumulated wire payload: %d bytes", len(raw))
			}
			projection, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "execution", Key: "execution-activity"})
			if err != nil {
				t.Fatal(err)
			}
			if count := strings.Count(string(projection), string(finalJSON)); count != 1 {
				t.Fatalf("projected detail count = %d", count)
			}
		})
	}
}

func TestActivityTimelineWireGrowth(t *testing.T) {
	final := strings.Repeat("final output\n", 5000)
	build := func(updates int) json.RawMessage {
		state := NewState()
		turn := state.NewTurn("execution-growth", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "run"}}}, Settings{})
		turn.activity(map[string]any{"id": "command-1", "kind": "command", "label": "Bash", "status": "running"})
		for update := 0; update < updates; update++ {
			turn.activity(map[string]any{"id": "command-1", "kind": "command", "label": "Bash", "status": "running", "detail": strings.Repeat("stale output\n", 1000) + fmt.Sprint(update)})
		}
		turn.activityEnd("command-1", "completed", final)
		raw, err := state.Encode()
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	before, after := build(0), build(100)
	finalJSON, _ := json.Marshal(final)
	if count := strings.Count(string(after), string(finalJSON)); count != 1 {
		t.Fatalf("final detail count = %d", count)
	}
	if strings.Contains(string(after), "stale output") {
		t.Fatal("stale activity detail retained")
	}
	if len(after) > len(before)+1024 {
		t.Fatalf("wire grew from %d to %d bytes after 100 updates", len(before), len(after))
	}
	t.Logf("wire before=%d bytes after=100 updates %d bytes", len(before), len(after))
}

func TestInteractionTimelineWireGrowth(t *testing.T) {
	stale := strings.Repeat("stale-input\n", 1000)
	finalInput := strings.Repeat("final-input\n", 1000)
	finalSchema := map[string]any{"type": "object", "description": strings.Repeat("final-schema\n", 1000)}
	build := func(updates int) json.RawMessage {
		state := NewState()
		turn := state.NewTurn("execution-interaction-growth", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "ask"}}}, Settings{})
		interaction := func(input string) map[string]any {
			return map[string]any{
				"id": "permission-growth", "kind": "permission", "title": "Allow command", "status": "pending",
				"toolName": "Bash", "input": map[string]any{"command": input}, "schema": map[string]any{"type": "object", "description": input},
			}
		}
		turn.interaction(interaction(stale))
		for update := 0; update < updates; update++ {
			turn.interaction(interaction(stale + fmt.Sprint(update)))
		}
		turn.interaction(map[string]any{
			"id": "permission-growth", "kind": "permission", "title": "Allow command", "status": "pending",
			"toolName": "Bash", "input": map[string]any{"command": finalInput}, "schema": finalSchema,
		})
		raw, err := state.Encode()
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	before, after := build(0), build(100)
	finalJSON, _ := json.Marshal(finalInput)
	if count := strings.Count(string(after), string(finalJSON)); count != 1 {
		t.Fatalf("final interaction input count = %d", count)
	}
	if strings.Contains(string(after), "stale-input") {
		t.Fatal("stale interaction input retained")
	}
	if len(after) > len(before)+2048 {
		t.Fatalf("interaction wire grew from %d to %d bytes after 100 updates", len(before), len(after))
	}
	var decoded State
	if err := json.Unmarshal(after, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Turns[0].Interactions[0]["input"].(map[string]any)["command"] != finalInput {
		t.Fatal("current interaction input was not the final value")
	}
	if decoded.Turns[0].Interactions[0]["schema"].(map[string]any)["description"] != finalSchema["description"] {
		t.Fatal("current interaction schema was not the final value")
	}
	t.Logf("interaction wire before=%d bytes after=100 updates %d bytes", len(before), len(after))
}

func TestInteractionTimelineReferenceKeepsPendingAuthority(t *testing.T) {
	state := NewState()
	turn := state.NewTurn("execution-interaction", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "ask"}}}, Settings{})
	turn.interaction(map[string]any{
		"id": "permission-1", "kind": "permission", "title": "Allow command", "status": "pending",
		"toolName": "Bash", "canRemember": true, "input": map[string]any{"command": "rm -rf build"},
		"schema": map[string]any{"type": "object"},
	})
	for update := 0; update < 10; update++ {
		turn.interaction(map[string]any{
			"id": "permission-1", "kind": "permission", "title": fmt.Sprintf("Allow command %d", update), "status": "pending",
			"toolName": "Bash", "canRemember": true, "input": map[string]any{"command": fmt.Sprintf("rm -rf build-%d", update)},
			"schema": map[string]any{"type": "object"},
		})
	}
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseState(raw); err != nil {
		t.Fatal(err)
	}
	if count := strings.Count(string(raw), "permission-1"); count < 2 {
		t.Fatalf("current interaction identity missing: %d", count)
	}
	if count := strings.Count(string(raw), "rm -rf build-9"); count != 1 {
		t.Fatalf("current interaction input count = %d", count)
	}
	if len(turn.Interactions) != 1 || turn.Interactions[0]["input"].(map[string]any)["command"] != "rm -rf build-9" || turn.Interactions[0]["schema"] == nil {
		t.Fatalf("current interaction = %#v", turn.Interactions)
	}
	references := 0
	for _, item := range turn.Timeline {
		if str(item["kind"]) == "interaction" {
			references++
			if str(item["interactionId"]) != "permission-1" || item["interaction"] != nil {
				t.Fatalf("timeline interaction = %#v", item)
			}
		}
	}
	if references != 1 {
		t.Fatalf("interaction references = %d", references)
	}
	observation, err := (StateAdapter{}).Project(raw)
	if err != nil {
		t.Fatal(err)
	}
	if observation.LatestExecution == nil || observation.LatestExecution.Status != "waiting-for-user" || len(observation.LatestExecution.Interactions) != 1 {
		t.Fatalf("observation = %#v", observation)
	}
	public := observation.LatestExecution.Interactions[0]
	if public.ID != digest("interaction", "execution-interaction", "permission-1") || len(public.Actions) != 4 || public.Questions[0].Prompt != "Optional denial reason" {
		t.Fatalf("public interaction = %#v", public)
	}
}

func TestAssistantAndReasoningHaveSingleTimelineRepresentation(t *testing.T) {
	state := NewState()
	turn := state.NewTurn("execution-text", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, Settings{})
	turn.text("Hello ", "message-1", false)
	turn.text("world", "message-1", false)
	turn.reasoning("think")
	turn.reasoning("ing")
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	turnValue := decoded["turns"].([]any)[0].(map[string]any)
	for _, key := range []string{"text", "reasoning", "lastAssistantMessage", "diff", "review"} {
		if _, ok := turnValue[key]; ok {
			t.Fatalf("duplicate turn field %q retained", key)
		}
	}
	if turn.assistantText() != "Hello world" || turn.reasoningText() != "thinking" || turn.lastAssistantText() != "Hello world" {
		t.Fatalf("derived text = %q / %q / %q", turn.assistantText(), turn.reasoningText(), turn.lastAssistantText())
	}
	assistant, reasoning := 0, 0
	for _, item := range turn.Timeline {
		switch str(item["kind"]) {
		case "assistant":
			assistant++
			if str(item["content"]) != "Hello world" {
				t.Fatalf("assistant content = %q", str(item["content"]))
			}
		case "reasoning":
			reasoning++
			if str(item["content"]) != "thinking" {
				t.Fatalf("reasoning content = %q", str(item["content"]))
			}
		}
	}
	if assistant != 1 || reasoning != 1 {
		t.Fatalf("timeline text = %d assistant, %d reasoning", assistant, reasoning)
	}
}

func TestParseRejectsInlineEntitySnapshots(t *testing.T) {
	state := NewState()
	turn := state.NewTurn("execution-inline", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, Settings{})
	turn.activity(map[string]any{"id": "activity-1", "kind": "tool", "label": "Read", "status": "completed"})
	turn.Timeline[1] = map[string]any{"id": turn.Timeline[1]["id"], "kind": "activity", "createdAt": turn.Timeline[1]["createdAt"], "activity": cloneObject(turn.Activities[0])}
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseState(raw); err == nil {
		t.Fatal("inline activity snapshot accepted")
	}

	state = NewState()
	turn = state.NewTurn("execution-duplicate", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, Settings{})
	turn.activity(map[string]any{"id": "activity-1", "kind": "tool", "label": "Read", "status": "completed"})
	turn.Timeline = append(turn.Timeline, cloneObject(turn.Timeline[1]))
	raw, err = json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseState(raw); err == nil {
		t.Fatal("duplicate activity reference accepted")
	}
}

func TestForkResolvesCurrentEntities(t *testing.T) {
	state := timelineReaderState()
	normalizeTimelineReaderState(state)
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	fork, err := (&Harness{}).Fork(context.Background(), plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{SessionState: raw}}})
	if err != nil {
		t.Fatal(err)
	}
	result, err := ParseState(fork.SessionState)
	if err != nil {
		t.Fatal(err)
	}
	items := arr(result.ForkHistory["items"])
	if len(items) == 0 {
		t.Fatal("fork history is empty")
	}
	activities, interactions, notices := 0, 0, 0
	for _, value := range items {
		item := obj(value)
		switch str(item["kind"]) {
		case "activity":
			activities++
			if item["activityId"] != nil || obj(item["activity"]) == nil {
				t.Fatalf("fork activity = %#v", item)
			}
		case "interaction":
			interactions++
			if item["interactionId"] != nil || obj(item["interaction"])["status"] != "cancelled" {
				t.Fatalf("fork interaction = %#v", item)
			}
		case "notice":
			notices++
			if item["noticeId"] != nil || obj(item["notice"])["message"] != "Fixture warning" {
				t.Fatalf("fork notice = %#v", item)
			}
		case "plan", "usage", "diff":
			t.Fatalf("unshown fork item retained: %#v", item)
		}
	}
	if activities != 3 || interactions != 2 || notices != 1 {
		t.Fatalf("fork entities = %d activities, %d interactions, %d notices", activities, interactions, notices)
	}
	if len(result.ForkHistory["items"].([]any)) > len(state.Turns[0].Timeline) {
		t.Fatalf("fork history did not follow timeline order")
	}
}

func TestThreadProjectionRetainsAssistantSummary(t *testing.T) {
	state := threadReaderState()
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	threadRaw, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "thread"})
	if err != nil {
		t.Fatal(err)
	}
	projected, err := ParseState(threadRaw)
	if err != nil {
		t.Fatal(err)
	}
	if len(projected.Turns) != 2 {
		t.Fatalf("thread turns = %d", len(projected.Turns))
	}
	for index, expected := range []string{strings.Repeat("T", 600), "SECOND EXECUTION ANSWER"} {
		turn := projected.Turns[index]
		if turn.assistantText() != expected {
			t.Fatalf("thread turn %d assistant = %q", index, turn.assistantText())
		}
		assistant, activities := 0, 0
		for _, item := range turn.Timeline {
			switch str(item["kind"]) {
			case "assistant":
				assistant++
			case "activity":
				activities++
			}
		}
		if assistant != 1 || activities != 0 {
			t.Fatalf("thread turn %d timeline = %d assistant, %d activity references", index, assistant, activities)
		}
	}
}

func TestTerminalOverviewKeepsAssistantPreview(t *testing.T) {
	for _, test := range []struct {
		name, status, expected, unexpected string
	}{
		{"failed", "failed", "FAILED ASSISTANT", "LATER REASONING"},
		{"interrupted", "interrupted", "INTERRUPTED ASSISTANT", "LATER REASONING"},
		{"completed-reasoning", "completed", "COMPLETED ASSISTANT", "LATER REASONING"},
	} {
		t.Run(test.name, func(t *testing.T) {
			state := terminalReaderState(test.status)
			raw, err := state.Encode()
			if err != nil {
				t.Fatal(err)
			}
			observation, err := (StateAdapter{}).Project(raw)
			if err != nil {
				t.Fatal(err)
			}
			if observation.LatestExecution == nil || observation.LatestExecution.Summary == nil || *observation.LatestExecution.Summary != test.expected {
				t.Fatalf("observation summary = %#v", observation.LatestExecution)
			}
			overviewRaw, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "overview"})
			if err != nil {
				t.Fatal(err)
			}
			overview, err := ParseState(overviewRaw)
			if err != nil {
				t.Fatal(err)
			}
			if got := overview.Turns[0].assistantText(); got != test.expected {
				t.Fatalf("overview assistant = %q", got)
			}
			if strings.Contains(string(overviewRaw), "LATER REASONING") {
				t.Fatal("overview retained later reasoning instead of assistant reply")
			}
			turnRaw, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "turn", Key: "execution-terminal"})
			if err != nil {
				t.Fatal(err)
			}
			var envelope map[string]any
			if err := json.Unmarshal(turnRaw, &envelope); err != nil {
				t.Fatal(err)
			}
			turnState := envelope
			if envelope["kind"] == "deferred-execution" {
				turnState = obj(envelope["state"])
			}
			turn := obj(arr(turnState["turns"])[0])
			text := ""
			for _, value := range arr(turn["timeline"]) {
				item := obj(value)
				if str(item["kind"]) == "assistant" {
					text += str(item["content"])
				}
			}
			if text != test.expected {
				t.Fatalf("turn reader assistant = %q", text)
			}
		})
	}
}

func TestCheckpointForkUsesCurrentEntitiesAndLatestMarkers(t *testing.T) {
	result := checkpointFork(t, checkpointForkState(), "cp-2")
	activities, interactions, reviews, errors := 0, 0, 0, 0
	activityStatuses, interactionStatuses := []string{}, []string{}
	for _, value := range arr(result.ForkHistory["items"]) {
		item := obj(value)
		switch str(item["kind"]) {
		case "activity":
			activities++
			activityStatuses = append(activityStatuses, str(obj(item["activity"])["status"]))
		case "interaction":
			interactions++
			interactionStatuses = append(interactionStatuses, str(obj(item["interaction"])["status"]))
		case "review":
			reviews++
		case "error":
			errors++
		}
	}
	if activities != 2 || interactions != 2 {
		t.Fatalf("checkpoint fork entities = %d activities, %d interactions", activities, interactions)
	}
	if !slices.Equal(activityStatuses, []string{"completed", "cancelled"}) {
		t.Fatalf("checkpoint activity statuses = %v", activityStatuses)
	}
	if !slices.Equal(interactionStatuses, []string{"resolved", "cancelled"}) {
		t.Fatalf("checkpoint interaction statuses = %v", interactionStatuses)
	}
	if reviews != 0 || errors != 0 {
		t.Fatalf("checkpoint fork inherited latest-only markers: %d review, %d error", reviews, errors)
	}
}

func TestCheckpointForkGolden(t *testing.T) {
	state := checkpointForkState()
	source, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	fork, err := forkCheckpoint(state, "cp-2")
	if err != nil {
		t.Fatal(err)
	}
	compareGolden(t, filepath.Join("testdata", "checkpoint-fork.golden.json"), struct {
		Source json.RawMessage `json:"source"`
		Fork   json.RawMessage `json:"fork"`
	}{source, fork})
}

func checkpointForkState() *State {
	state := NewState()
	state.PrimarySessionID = "claude-native-session"
	turn := state.NewTurn("checkpoint-turn", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "first prompt"}}}, Settings{})
	turn.checkpoint(0, "cp-1")
	parser := newParser()
	parser.messageStart(turn, "assistant-before", "claude-sonnet-4-5")
	turn.text("before checkpoint", "assistant-before", false)
	parser.messageEnd(turn, "assistant-before")
	parser.startTool(turn, &nativeTool{ID: "command-late", Name: "Bash", Input: map[string]any{"command": "go test"}}, "", nil)
	parser.startTool(turn, &nativeTool{ID: "command-running", Name: "Bash", Input: map[string]any{"command": "sleep"}}, "", nil)
	turn.interaction(map[string]any{"id": "permission-late", "kind": "permission", "title": "Allow late command", "status": "pending", "toolName": "Bash", "input": map[string]any{"command": "go test"}})
	turn.interaction(map[string]any{"id": "permission-pending", "kind": "permission", "title": "Still pending", "status": "pending", "toolName": "Bash", "input": map[string]any{"command": "sleep"}})
	turn.review("review before checkpoint")
	turn.fail("error before checkpoint")
	turn.addPrompt(model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "second prompt"}}}, "cp-2")
	turn.activityEnd("command-late", "completed", "late completed detail")
	turn.interaction(map[string]any{"id": "permission-late", "kind": "permission", "title": "Allow late command", "status": "resolved", "toolName": "Bash", "input": map[string]any{"command": "go test"}})
	turn.review("review after checkpoint")
	turn.fail("error after checkpoint")
	normalizeReaderState(state, 1000)
	return state
}

func checkpointFork(t *testing.T, state *State, checkpoint string) *State {
	t.Helper()
	fork, err := forkCheckpoint(state, checkpoint)
	if err != nil {
		t.Fatal(err)
	}
	result, err := ParseState(fork)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func forkCheckpoint(state *State, checkpoint string) (json.RawMessage, error) {
	raw, err := state.Encode()
	if err != nil {
		return nil, err
	}
	fork, err := (&Harness{}).Fork(context.Background(), plugin.ForkRequest{
		Source:  model.ThreadRecord{SessionRecord: model.SessionRecord{SessionState: raw}},
		Request: json.RawMessage(fmt.Sprintf(`{"checkpointId":%q}`, checkpoint)),
	})
	return fork.SessionState, err
}

func TestParseRejectsMalformedTimelineReferences(t *testing.T) {
	base := func() (*State, *Turn) {
		state := NewState()
		turn := state.NewTurn("execution-malformed", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, Settings{})
		turn.activity(map[string]any{"id": "activity-1", "kind": "tool", "label": "Read", "status": "completed"})
		return state, turn
	}
	for _, test := range []struct {
		name   string
		mutate func(*Turn)
	}{
		{"missing reference", func(turn *Turn) { delete(turn.Timeline[1], "activityId") }},
		{"missing entity", func(turn *Turn) { turn.Timeline[1]["activityId"] = "missing" }},
		{"unknown kind", func(turn *Turn) { turn.Timeline[1]["kind"] = "mystery" }},
		{"inline snapshot", func(turn *Turn) {
			delete(turn.Timeline[1], "activityId")
			turn.Timeline[1]["activity"] = cloneObject(turn.Activities[0])
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			state, turn := base()
			test.mutate(turn)
			raw, err := json.Marshal(state)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := ParseState(raw); err == nil {
				t.Fatal("malformed timeline accepted")
			}
		})
	}
}

func TestElicitationReaderGolden(t *testing.T) {
	state := elicitationReaderState()
	normalizeTimelineReaderState(state)
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	observation, err := (StateAdapter{}).Project(raw)
	if err != nil {
		t.Fatal(err)
	}
	overview, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "overview"})
	if err != nil {
		t.Fatal(err)
	}
	if observation.LatestExecution == nil || len(observation.LatestExecution.Interactions) != 1 {
		t.Fatalf("elicitation observation = %#v", observation)
	}
	prompt := observation.LatestExecution.Interactions[0].Questions[0].Prompt
	expected := "JSON form values matching this schema:\n" + displayJSON(state.Turns[0].Interactions[0]["schema"])
	if prompt != expected || !strings.Contains(prompt, "& < >") || !strings.Contains(prompt, "\u2028") {
		t.Fatalf("elicitation prompt = %q", prompt)
	}
	compareGolden(t, filepath.Join("testdata", "elicitation-reader.golden.json"), struct {
		State       json.RawMessage         `json:"state"`
		Observation model.PublicObservation `json:"observation"`
		Overview    json.RawMessage         `json:"overview"`
	}{raw, observation, overview})
}

func TestThreadReaderGolden(t *testing.T) {
	state := threadReaderState()
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	thread, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "thread"})
	if err != nil {
		t.Fatal(err)
	}
	compareGolden(t, filepath.Join("testdata", "thread-reader.golden.json"), struct {
		State  json.RawMessage `json:"state"`
		Thread json.RawMessage `json:"thread"`
	}{raw, thread})
}

func TestTerminalReaderGolden(t *testing.T) {
	fixtures := map[string]any{}
	for _, status := range []string{"failed", "interrupted", "completed"} {
		state := terminalReaderState(status)
		raw, err := state.Encode()
		if err != nil {
			t.Fatal(err)
		}
		observation, err := (StateAdapter{}).Project(raw)
		if err != nil {
			t.Fatal(err)
		}
		overview, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "overview"})
		if err != nil {
			t.Fatal(err)
		}
		fixtures[status] = struct {
			State       json.RawMessage         `json:"state"`
			Observation model.PublicObservation `json:"observation"`
			Overview    json.RawMessage         `json:"overview"`
		}{raw, observation, overview}
	}
	compareGolden(t, filepath.Join("testdata", "terminal-reader.golden.json"), fixtures)
}

func compareGolden(t *testing.T, path string, value any) {
	t.Helper()
	fixture, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if os.Getenv("MOKUSEI_UPDATE_CLAUDE_GOLDEN") == "1" {
		if err := os.WriteFile(path, append(fixture, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	expected, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(fixture) != strings.TrimSpace(string(expected)) {
		t.Fatalf("Claude %s golden is stale; rerun with MOKUSEI_UPDATE_CLAUDE_GOLDEN=1", filepath.Base(path))
	}
}

func threadReaderState() *State {
	state := NewState()
	for index, text := range []string{strings.Repeat("T", 2000), "SECOND EXECUTION ANSWER"} {
		id := fmt.Sprintf("execution-thread-%d", index)
		turn := state.NewTurn(id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: fmt.Sprintf("prompt %d", index)}}}, Settings{})
		parser := newParser()
		parser.startTool(turn, &nativeTool{ID: fmt.Sprintf("tool-%d", index), Name: "Read", Input: nil}, "", nil)
		turn.activityEnd(fmt.Sprintf("tool-%d", index), "completed", "")
		parser.messageStart(turn, id+"-message", "claude-sonnet-4-5")
		turn.text(text, id+"-message", false)
		parser.messageEnd(turn, id+"-message")
		turn.settle("completed", turn.UpdatedAt+1, nil)
	}
	normalizeReaderState(state, 1000)
	return state
}

func terminalReaderState(status string) *State {
	state := NewState()
	turn := state.NewTurn("execution-terminal", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "terminal prompt"}}}, Settings{})
	switch status {
	case "failed":
		turn.text("FAILED ASSISTANT", "failed-message", false)
	case "interrupted":
		turn.text("INTERRUPTED ASSISTANT", "interrupted-message", false)
	default:
		parser := newParser()
		parser.messageStart(turn, "completed-message", "claude-sonnet-4-5")
		turn.text("COMPLETED ASSISTANT", "completed-message", false)
		parser.messageEnd(turn, "completed-message")
		turn.reasoning("LATER REASONING")
	}
	turn.settle(status, turn.UpdatedAt+1, nil)
	normalizeTimelineReaderState(state)
	return state
}

func elicitationReaderState() *State {
	state := NewState()
	turn := state.NewTurn("execution-elicitation", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "fill form"}}}, Settings{})
	turn.interaction(map[string]any{
		"id": "ask-elicitation", "kind": "elicitation", "title": "MCP form", "description": "Provide the remote fields",
		"status": "pending", "toolName": "mcp__remote__form", "elicitationMode": "form",
		"elicitationId": "elicitation-1", "serverName": "remote",
		"schema": map[string]any{"type": "object", "properties": map[string]any{
			"name": map[string]any{"type": "string", "description": "Use & < > and \u2028 safely"},
		}},
	})
	return state
}

func TestTimelineReaderGolden(t *testing.T) {
	state := timelineReaderState()
	normalizeTimelineReaderState(state)
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	observation, err := (StateAdapter{}).Project(raw)
	if err != nil {
		t.Fatal(err)
	}
	fork, err := (&Harness{}).Fork(context.Background(), plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{SessionState: raw}}})
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := json.MarshalIndent(struct {
		State       json.RawMessage         `json:"state"`
		Observation model.PublicObservation `json:"observation"`
		Fork        json.RawMessage         `json:"fork"`
	}{raw, observation, fork.SessionState}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("testdata", "timeline-reader.golden.json")
	if os.Getenv("MOKUSEI_UPDATE_CLAUDE_GOLDEN") == "1" {
		if err := os.WriteFile(path, append(fixture, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	expected, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(fixture) != strings.TrimSpace(string(expected)) {
		t.Fatalf("Claude timeline reader golden is stale; rerun with MOKUSEI_UPDATE_CLAUDE_GOLDEN=1")
	}

	turn := obj(arr(obj(rawMap(t, fixture)["state"])["turns"])[0])
	for _, key := range []string{"text", "reasoning", "lastAssistantMessage", "diff", "review"} {
		if _, ok := turn[key]; ok {
			t.Fatalf("duplicate turn field %q retained", key)
		}
	}
	activityRefs, interactionRefs, noticeRefs := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, value := range arr(turn["timeline"]) {
		item := obj(value)
		switch str(item["kind"]) {
		case "activity":
			id := str(item["activityId"])
			if item["activity"] != nil || activityRefs[id] {
				t.Fatalf("activity timeline item = %#v", item)
			}
			activityRefs[id] = true
		case "interaction":
			id := str(item["interactionId"])
			if item["interaction"] != nil || interactionRefs[id] {
				t.Fatalf("interaction timeline item = %#v", item)
			}
			interactionRefs[id] = true
		case "notice":
			id := str(item["noticeId"])
			if item["notice"] != nil || noticeRefs[id] {
				t.Fatalf("notice timeline item = %#v", item)
			}
			noticeRefs[id] = true
		}
	}
	if !activityRefs["command-ok"] || !activityRefs["command-fail"] || !activityRefs["hook-1"] || !interactionRefs["ask-question"] || !interactionRefs["ask-permission"] || !noticeRefs["notice-1"] {
		t.Fatalf("reader references = %#v / %#v / %#v", activityRefs, interactionRefs, noticeRefs)
	}
}

func rawMap(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func timelineReaderState() *State {
	state := NewState()
	state.PrimarySessionID = "claude-native-session"
	turn := state.NewTurn("execution-timeline", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Inspect the command"}}}, Settings{Model: "claude-sonnet-4-5"})
	parser := newParser()
	parser.messageStart(turn, "assistant-1", "claude-sonnet-4-5")
	turn.reasoning("Check the output. ")
	turn.text("First answer.", "assistant-1", false)
	parser.messageEnd(turn, "assistant-1")

	parser.startTool(turn, &nativeTool{ID: "command-ok", Name: "Bash", Input: map[string]any{"command": "go test ./..."}}, "", nil)
	turn.activity(map[string]any{"id": "command-ok", "kind": "command", "label": "Bash", "status": "running", "toolName": "Bash", "detail": "partial output"})
	turn.activityEnd("command-ok", "completed", "success output\nsuccess output\n")
	turn.interaction(map[string]any{
		"id": "ask-question", "kind": "question", "title": "Pick a target", "status": "pending", "toolName": "AskUserQuestion",
		"questions": []any{map[string]any{"question": "Choose", "header": "Target", "multiSelect": false, "options": []any{
			map[string]any{"label": "A", "description": "First"}, map[string]any{"label": "B"},
		}}},
	})
	turn.interaction(map[string]any{
		"id": "ask-question", "kind": "question", "title": "Pick the target", "status": "pending", "toolName": "AskUserQuestion",
		"questions": []any{map[string]any{"question": "Choose", "header": "Target", "multiSelect": false, "options": []any{
			map[string]any{"label": "A", "description": "First"}, map[string]any{"label": "B"},
		}}},
	})

	parser.startTool(turn, &nativeTool{ID: "command-fail", Name: "Bash", Input: map[string]any{"command": "false"}}, "", nil)
	turn.activityEnd("command-fail", "failed", "permission denied")
	parser.startTool(turn, &nativeTool{ID: "hook-1", Name: "Hook", Input: nil}, "", nil)
	turn.activityEnd("hook-1", "completed", "")
	turn.interaction(map[string]any{
		"id": "ask-permission", "kind": "permission", "title": "Allow the next command", "status": "pending",
		"toolName": "Bash", "canRemember": true, "input": map[string]any{"command": "rm -rf build"},
	})
	turn.notice("warning", "Fixture warning")
	turn.review("review first")
	turn.review("review final")

	parser.messageStart(turn, "assistant-2", "claude-sonnet-4-5")
	turn.text("Final ", "assistant-2", false)
	turn.text("answer.", "assistant-2", false)
	parser.messageEnd(turn, "assistant-2")
	return state
}

func normalizeTimelineReaderState(state *State) { normalizeReaderState(state, 1000) }

func normalizeReaderState(state *State, base int64) {
	for turnIndex, turn := range state.Turns {
		turn.CreatedAt = base
		for index, item := range turn.Timeline {
			at := base + 1 + int64(index)
			item["createdAt"] = at
			item["id"] = fmt.Sprintf("%s:%d:%d", str(item["kind"]), at, index)
		}
		turn.UpdatedAt = base + int64(len(turn.Timeline)) + 1
		if turn.Status == "running" {
			turn.FinishedAt = nil
		} else {
			finished := turn.UpdatedAt
			turn.FinishedAt = &finished
		}
		for index, notice := range turn.Notices {
			old := str(notice["id"])
			id := fmt.Sprintf("notice-%d", turnIndex*100+index+1)
			notice["id"] = id
			for _, item := range turn.Timeline {
				if str(item["kind"]) == "notice" && str(item["noticeId"]) == old {
					item["noticeId"] = id
				}
			}
		}
		base = turn.UpdatedAt + 1
	}
}

func BenchmarkActivityTimelineDecode(b *testing.B) {
	raw := benchmarkActivityTimeline(b)
	b.SetBytes(int64(len(raw)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := ParseState(raw); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkActivityTimelineBuildEncode(b *testing.B) {
	for i := 0; i < b.N; i++ {
		if raw := benchmarkActivityTimeline(b); len(raw) == 0 {
			b.Fatal("empty state")
		}
	}
}

func benchmarkActivityTimeline(b *testing.B) json.RawMessage {
	b.Helper()
	state := NewState()
	turn := state.NewTurn("execution-benchmark", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "run"}}}, Settings{})
	turn.activity(map[string]any{"id": "command-1", "kind": "command", "label": "Bash", "status": "running"})
	for update := 0; update < 100; update++ {
		turn.activity(map[string]any{"id": "command-1", "kind": "command", "label": "Bash", "status": "running", "detail": strings.Repeat("stale output\n", 1000)})
	}
	turn.activityEnd("command-1", "completed", strings.Repeat("final output\n", 5000))
	raw, err := state.Encode()
	if err != nil {
		b.Fatal(err)
	}
	return raw
}
