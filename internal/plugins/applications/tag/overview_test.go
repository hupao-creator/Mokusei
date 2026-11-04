package tag

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestOverviewAllViewRetainsScopedEvidence(t *testing.T) {
	own := model.ThreadRef{ThreadID: "alpha-thread", TypeID: "agent"}
	foreign := model.ThreadRef{ThreadID: "beta-thread", TypeID: "agent"}
	request := "Repair the Alpha build"
	for _, test := range []struct {
		name                       string
		selected, followUp         *model.ThreadRef
		wantSelected, wantFollowUp *model.ThreadRef
	}{
		{"local selection", &own, &foreign, &own, nil},
		{"local follow-up", &foreign, &own, nil, &own},
	} {
		t.Run(test.name, func(t *testing.T) {
			client := overviewClient()
			client.SelectedTag, client.SelectedScope = nil, nil // All
			client.SelectedThread, client.FollowUpThread = test.selected, test.followUp
			client.RecentActions = []plugin.OverviewUserAction{
				{Kind: "thread-input", At: 10, Thread: &foreign, Text: stringPointer("Beta request")},
				{Kind: "thread-input", At: 11, Thread: &own, Text: &request},
				{Kind: "view", At: 12, View: "archived"},
			}
			other := plugin.OverviewClientSnapshot{ClientID: "other-desktop", OverviewClientContext: plugin.OverviewClientContext{
				ContextID: "other-context", Revision: 5, View: "default", RecentActions: []plugin.OverviewUserAction{},
				Filters: []plugin.OverviewFilter{{Tag: "Shared", Scope: "workspace-beta", Kind: "semantic", Aliases: []string{}, Count: 1, Threads: []model.ThreadRef{foreign}}},
			}}
			native := &overviewFixture{clients: []plugin.OverviewClientSnapshot{client, other}}
			tools := overviewTools(t, native)
			observation := readOverview(t, tools)
			if observation.SelectedTag != nil {
				t.Fatalf("All view selection changed: %+v", observation)
			}
			wantFilters := []plugin.OverviewFilter{
				{Tag: "Alpha", Scope: "workspace-alpha", Kind: "directory", Aliases: []string{}, Count: 1, Threads: []model.ThreadRef{own}},
				{Tag: "Shared", Scope: "workspace-alpha", Kind: "semantic", Aliases: []string{}, Count: 1, Threads: []model.ThreadRef{own}},
			}
			if !reflect.DeepEqual(observation.Filters, wantFilters) {
				t.Fatalf("scope filters = %+v; want %+v", observation.Filters, wantFilters)
			}
			if !reflect.DeepEqual(observation.SelectedThread, test.wantSelected) || !reflect.DeepEqual(observation.FollowUpThread, test.wantFollowUp) {
				t.Fatalf("scope thread references = selected %v, follow-up %v", observation.SelectedThread, observation.FollowUpThread)
			}
			wantActions := []plugin.OverviewUserAction{
				{Kind: "thread-input", At: 11, Thread: &own, Text: &request},
				{Kind: "view", At: 12, View: "archived"},
			}
			if !reflect.DeepEqual(observation.RecentActions, wantActions) {
				t.Fatalf("classification evidence = %+v; want %+v", observation.RecentActions, wantActions)
			}
		})
	}
}

// The fixture supplies external desktop state; evidence filtering runs in production.
type overviewFixture struct {
	clients []plugin.OverviewClientSnapshot
}

func (f *overviewFixture) ReadClients(context.Context) ([]plugin.OverviewClientSnapshot, error) {
	raw, err := json.Marshal(f.clients)
	if err != nil {
		return nil, err
	}
	var clients []plugin.OverviewClientSnapshot
	err = json.Unmarshal(raw, &clients)
	return clients, err
}

func overviewClient() plugin.OverviewClientSnapshot {
	own := model.ThreadRef{ThreadID: "alpha-thread", TypeID: "agent"}
	foreign := model.ThreadRef{ThreadID: "beta-thread", TypeID: "agent"}
	return plugin.OverviewClientSnapshot{ClientID: "desktop-alpha", OverviewClientContext: plugin.OverviewClientContext{
		ContextID: "context-alpha", Revision: 7, OverviewVisible: true, Focused: true, DocumentVisible: true,
		View: "default", RecentActions: []plugin.OverviewUserAction{}, SelectedTag: stringPointer("Shared"), SelectedScope: stringPointer("workspace-alpha"),
		Filters: []plugin.OverviewFilter{
			{Tag: "Alpha", Scope: "workspace-alpha", Kind: "directory", Aliases: []string{}, Count: 1, Threads: []model.ThreadRef{own}},
			{Tag: "Shared", Scope: "workspace-alpha", Kind: "semantic", Aliases: []string{}, Count: 1, Threads: []model.ThreadRef{own}},
			{Tag: "Shared", Scope: "workspace-beta", Kind: "semantic", Aliases: []string{}, Count: 1, Threads: []model.ThreadRef{foreign}},
			{Tag: "Beta only", Scope: "workspace-beta", Kind: "semantic", Aliases: []string{}, Count: 1, Threads: []model.ThreadRef{foreign}},
		},
	}}
}

func overviewTools(t *testing.T, native plugin.OverviewControl) map[string]plugin.ToolBinding {
	t.Helper()
	bindings := []plugin.ToolBinding{overviewContextTool(native, t.Context(), "workspace-alpha")}
	tools := map[string]plugin.ToolBinding{}
	for _, binding := range bindings {
		tools[binding.Name] = binding
	}
	return tools
}

type overviewObservation struct {
	plugin.OverviewClientContext
}

func readOverview(t *testing.T, tools map[string]plugin.ToolBinding) overviewObservation {
	t.Helper()
	raw := executeOverview(t, tools, "read_overview_context", map[string]any{"offset": 0, "limit": 64000})
	var page struct {
		Text       string `json:"text"`
		NextOffset *int   `json:"nextOffset"`
	}
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	if page.NextOffset != nil {
		t.Fatal("small Overview fixture unexpectedly paginated")
	}
	var observations []overviewObservation
	if err := json.Unmarshal([]byte(page.Text), &observations); err != nil {
		t.Fatal(err)
	}
	if len(observations) != 1 {
		t.Fatalf("visible scope clients = %d; want one, got %s", len(observations), page.Text)
	}
	return observations[0]
}

func executeOverview(t *testing.T, tools map[string]plugin.ToolBinding, name string, args map[string]any) json.RawMessage {
	t.Helper()
	tool, ok := tools[name]
	if !ok {
		t.Fatalf("missing %s tool", name)
	}
	raw, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	result, err := tool.Execute(t.Context(), plugin.ToolCall{Arguments: raw})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return result
}

func stringPointer(value string) *string { return &value }

func TestOverviewRetiredToolsCannotRead(t *testing.T) {
	lifetime, cancel := context.WithCancel(t.Context())
	native := &overviewFixture{clients: []plugin.OverviewClientSnapshot{overviewClient()}}
	tools := []plugin.ToolBinding{overviewContextTool(native, lifetime, "workspace-alpha")}
	cancel()
	for _, tool := range tools {
		if _, err := tool.Execute(t.Context(), plugin.ToolCall{Arguments: json.RawMessage(`{}`)}); err == nil {
			t.Fatalf("retired %s retained authority", tool.Name)
		}
	}
}
