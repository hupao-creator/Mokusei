package moku

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// executeToolHarness is the smallest Harness that can answer a create_thread
// resolution. Describe returns the advertised OpenCode-shaped schema so the
// native-settings boundary sees the same union the real adapter publishes.
type executeToolHarness struct {
	schema json.RawMessage
}

func (h *executeToolHarness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "opencode", DisplayName: "OpenCode"}
}
func (h *executeToolHarness) DefaultSettings() json.RawMessage { return json.RawMessage(`{}`) }
func (h *executeToolHarness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "available"}, nil
}
func (h *executeToolHarness) Settings() plugin.HarnessSettings         { return executeToolSettings{h: h} }
func (h *executeToolHarness) SessionState() plugin.SessionStateAdapter { return executeToolState{} }
func (h *executeToolHarness) Metadata() plugin.ThreadMetadataAdapter   { return executeToolMetadata{} }
func (h *executeToolHarness) Open(context.Context, plugin.OpenContext) (plugin.Handle, error) {
	return nil, errors.New("execute fixture never opens a native session")
}

type executeToolSettings struct{ h *executeToolHarness }

func (s executeToolSettings) Normalize(raw json.RawMessage) (json.RawMessage, error) {
	return model.CloneRaw(raw), nil
}
func (s executeToolSettings) SnapshotExecution(context.Context, plugin.SettingsRequest, bool) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (s executeToolSettings) Describe(context.Context, plugin.SettingsRequest) (json.RawMessage, error) {
	return model.CloneRaw(s.h.schema), nil
}
func (s executeToolSettings) DefaultThread(json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (s executeToolSettings) ResolveThread(_ context.Context, request plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	return model.CloneRaw(request.Requested), nil
}
func (s executeToolSettings) HasThreadContent(raw json.RawMessage) bool { return !model.IsNull(raw) }
func (s executeToolSettings) ApplyThreadUpdate(_ context.Context, request plugin.UpdateSettingsRequest) (json.RawMessage, error) {
	return model.CloneRaw(request.Update), nil
}
func (s executeToolSettings) PromptSettings(harnessSettings, _ json.RawMessage) (json.RawMessage, error) {
	return model.CloneRaw(harnessSettings), nil
}
func (s executeToolSettings) Presentation(context.Context, plugin.SettingsPresentationRequest) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}

type executeToolState struct{}

func (executeToolState) Project(json.RawMessage) (model.PublicObservation, error) {
	return model.PublicObservation{}, nil
}
func (executeToolState) ProjectRenderer(json.RawMessage, model.RendererScope) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (executeToolState) ReadContext(json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (executeToolState) ResolveExecution(json.RawMessage, string) (*model.PublicExecution, error) {
	return nil, nil
}
func (executeToolState) Settle(plugin.SettleRequest) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}

type executeToolMetadata struct{}

func (executeToolMetadata) Initialize(string, model.AgentInput, json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (executeToolMetadata) Project(json.RawMessage) (string, error) { return "", nil }
func (executeToolMetadata) Fork(json.RawMessage, string) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}

type executeToolFixture struct {
	record      *model.ThreadRecord
	coordinator *Coordinator
	harness     *executeToolHarness
	resolved    json.RawMessage
}

// newExecuteToolFixture wires the create_thread path through the real Execute
// closure: audit, schema validation and execution all run against the live
// coordinator fixture rather than the normalization helper alone.
func newExecuteToolFixture(t *testing.T) *executeToolFixture {
	t.Helper()
	record := &model.ThreadRecord{ID: "moku", Moku: true}
	record.Observation.LatestExecution = &model.PublicExecution{ExecutionID: "execution", Status: "running"}
	fixture := &executeToolFixture{
		record:  record,
		harness: &executeToolHarness{schema: openCodeNativeSchema()},
	}
	settings := model.DefaultSettings([]string{"opencode"})
	fixture.coordinator = &Coordinator{
		running: true, ctx: context.Background(), id: record.ID,
		scopes: map[string]executionScope{"execution": {threadID: record.ID, ctx: context.Background()}},
		config: Configuration{
			Workspace: t.TempDir(),
			Harnesses: map[string]plugin.Harness{"opencode": fixture.harness},
			Settings:  func() (model.Settings, int64, error) { return settings, 1, nil },
			Thread:    func(string) (model.ThreadRecord, error) { return *record, nil },
			UpdateThread: func(_ context.Context, _ string, update func(*model.ThreadRecord) error) error {
				return update(record)
			},
			CreateThread: func(ctx context.Context, request CreateThreadRequest) (CreatedThread, error) {
				resolved, err := request.ResolveSettings(ctx, "/workspace")
				if err != nil {
					return CreatedThread{}, err
				}
				fixture.resolved = resolved
				return CreatedThread{
					Record:    model.ThreadRecord{ID: "created"},
					Execution: SendResult{ExecutionID: "created-execution"},
				}, nil
			},
		},
	}
	return fixture
}

func (f *executeToolFixture) binding(t *testing.T, description ThreadCreationDescription, name string) plugin.ToolBinding {
	t.Helper()
	for _, candidate := range f.coordinator.tools(f.record.ID, description) {
		if candidate.Name == name {
			return candidate
		}
	}
	t.Fatalf("missing %s binding", name)
	return plugin.ToolBinding{}
}

func (f *executeToolFixture) assertResolvedThinking(t *testing.T, effort string) {
	t.Helper()
	var options map[string]any
	if err := json.Unmarshal(f.resolved, &options); err != nil {
		t.Fatal(err)
	}
	thinking, ok := options["thinking"].(map[string]any)
	if !ok || thinking["mode"] != "effort" || thinking["effort"] != effort {
		t.Fatalf("native settings did not receive normalized thinking: %s", f.resolved)
	}
}

func (f *executeToolFixture) transcriptArguments(t *testing.T) map[string]any {
	t.Helper()
	if len(f.record.Transcript) != 1 {
		t.Fatalf("expected one audited tool operation, got %d", len(f.record.Transcript))
	}
	var item struct {
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(f.record.Transcript[0], &item); err != nil {
		t.Fatal(err)
	}
	return item.Arguments
}

// A regression at tools.go's normalization call site (audit, validation and
// execution) fails this test: the logged target string never becomes an object,
// so schema validation rejects /target with "got string, want object".
func TestExecuteNormalizesLoggedStringifiedTarget(t *testing.T) {
	description, err := DescribeThreadCreation([]TargetDescription{{
		HarnessID:    "opencode",
		NativeSchema: openCodeNativeSchema(),
	}}, "/moku")
	if err != nil {
		t.Fatal(err)
	}
	fixture := newExecuteToolFixture(t)
	binding := fixture.binding(t, description, "create_thread")
	arguments := json.RawMessage(`{"prompt":"诊断用最小任务：请只回复「ok」两个字，不要做其他事。","target":"{\"opencode\":{\"agent\":\"build\",\"model\":\"deepseek-v4.1-flash\",\"provider\":\"opencode-go\",\"thinking\":{\"effort\":\"low\",\"mode\":\"effort\"}}}","worktree":false}`)
	result, err := binding.Execute(context.Background(), plugin.ToolCall{CallID: "native-call", Arguments: arguments})
	if err != nil {
		t.Fatalf("stringified target reached the tool boundary unnormalized: %v", err)
	}
	var created struct {
		OK       bool   `json:"ok"`
		ThreadID string `json:"threadId"`
	}
	if err := json.Unmarshal(result, &created); err != nil || !created.OK || created.ThreadID != "created" {
		t.Fatalf("unexpected create_thread result: %s", result)
	}
	audited := fixture.transcriptArguments(t)
	target, ok := audited["target"].(map[string]any)
	if !ok {
		t.Fatalf("audited target is not an object: %s", fixture.record.Transcript[0])
	}
	opencode, ok := target["opencode"].(map[string]any)
	if !ok {
		t.Fatalf("audited target key is not an object: %s", fixture.record.Transcript[0])
	}
	if _, ok := opencode["thinking"].(map[string]any); !ok {
		t.Fatalf("audited thinking is not an object: %s", fixture.record.Transcript[0])
	}
	fixture.assertResolvedThinking(t, "low")
}

// A regression at create_thread's native-settings normalization (tools.go's
// resolve path) fails this test: the deferred target schema hides thinking, so
// only the native schema discovered here can repair the stringified value
// before admission.
func TestExecuteNormalizesDeferredNativeSettings(t *testing.T) {
	description, err := DescribeThreadCreation([]TargetDescription{{
		HarnessID:      "opencode",
		DeferredNative: true,
	}}, "/moku")
	if err != nil {
		t.Fatal(err)
	}
	fixture := newExecuteToolFixture(t)
	binding := fixture.binding(t, description, "create_thread")
	arguments := json.RawMessage(`{"prompt":"inspect the repo","worktree":false,"target":{"opencode":{"provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":"{\"mode\":\"effort\",\"effort\":\"high\"}"}}}`)
	result, err := binding.Execute(context.Background(), plugin.ToolCall{CallID: "native-call", Arguments: arguments})
	if err != nil {
		t.Fatalf("stringified native settings reached admission unnormalized: %v", err)
	}
	if !strings.Contains(string(result), `"ok":true`) {
		t.Fatalf("unexpected create_thread result: %s", result)
	}
	fixture.assertResolvedThinking(t, "high")
}

func TestExecuteRejectsInvalidTargetString(t *testing.T) {
	description, err := DescribeThreadCreation([]TargetDescription{{
		HarnessID: "opencode", NativeSchema: openCodeNativeSchema(),
	}}, "/moku")
	if err != nil {
		t.Fatal(err)
	}
	fixture := newExecuteToolFixture(t)
	fixture.coordinator.config.CreateThread = func(context.Context, CreateThreadRequest) (CreatedThread, error) {
		t.Fatal("invalid target reached thread creation")
		return CreatedThread{}, nil
	}
	_, err = fixture.binding(t, description, "create_thread").Execute(context.Background(), plugin.ToolCall{
		Arguments: json.RawMessage(`{"prompt":"inspect the repo","worktree":false,"target":"not json"}`),
	})
	var callerError *plugin.ToolCallError
	if !errors.As(err, &callerError) || !strings.Contains(err.Error(), "/target") {
		t.Fatalf("invalid target must remain a caller error: %v", err)
	}
	if got := fixture.transcriptArguments(t)["target"]; got != "not json" {
		t.Fatalf("invalid target was rewritten in audit: %#v", got)
	}
}
