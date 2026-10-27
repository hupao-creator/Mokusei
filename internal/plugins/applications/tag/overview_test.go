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
			if observation.ObservationID != "" || observation.SelectedTag != nil {
				t.Fatalf("All view gained selection authority: %+v", observation)
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

func TestOverviewSelectionAuthorityIsScopeQualified(t *testing.T) {
	for _, test := range []struct {
		name, selectedTag, selectedScope string
		canSelect                        bool
	}{
		{"local semantic filter", "Shared", "workspace-alpha", true},
		{"local directory filter", "Alpha", "workspace-alpha", true},
		{"same tag in another scope", "Shared", "workspace-beta", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			client := overviewClient()
			client.SelectedTag, client.SelectedScope = &test.selectedTag, &test.selectedScope
			native := &overviewFixture{clients: []plugin.OverviewClientSnapshot{client}}
			tools := overviewTools(t, native)
			observation := readOverview(t, tools)
			if (observation.ObservationID != "") != test.canSelect {
				t.Fatalf("selection authority for %s/%s = %q", test.selectedScope, test.selectedTag, observation.ObservationID)
			}
			if test.canSelect {
				selectOverview(t, tools, observation.ObservationID, "Shared", "applied")
				assertOverviewSelections(t, native, []plugin.OverviewFilterSelection{{
					ClientID: "desktop-alpha", ContextID: "context-alpha", Revision: 7,
					Scope: "workspace-alpha", Tag: stringPointer("Shared"),
				}})
			}
		})
	}
}

func TestOverviewSelectionRejectsNonSemanticScopeTargets(t *testing.T) {
	for _, target := range []string{"Alpha", "Beta only"} {
		t.Run(target, func(t *testing.T) {
			native := &overviewFixture{clients: []plugin.OverviewClientSnapshot{overviewClient()}}
			tools := overviewTools(t, native)
			observation := readOverview(t, tools)
			selectOverview(t, tools, observation.ObservationID, target, "stale")
			// Even a rejected target consumes the observed decision. It must not
			// become a reusable handle for trying other filters on the desktop.
			selectOverview(t, tools, observation.ObservationID, "Shared", "stale")
			assertOverviewSelections(t, native, nil)

			observation = readOverview(t, tools)
			selectOverview(t, tools, observation.ObservationID, "Shared", "applied")
			selectOverview(t, tools, observation.ObservationID, nil, "stale")
			observation = readOverview(t, tools)
			selectOverview(t, tools, observation.ObservationID, nil, "applied")
			assertOverviewSelections(t, native, []plugin.OverviewFilterSelection{
				{ClientID: "desktop-alpha", ContextID: "context-alpha", Revision: 7, Scope: "workspace-alpha", Tag: stringPointer("Shared")},
				{ClientID: "desktop-alpha", ContextID: "context-alpha", Revision: 7},
			})
		})
	}
}

// The fixture supplies external desktop state and records native requests. All
// evidence filtering, opaque authority and target validation run in production.
type overviewFixture struct {
	clients    []plugin.OverviewClientSnapshot
	selections []plugin.OverviewFilterSelection
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

func (f *overviewFixture) SelectFilter(_ context.Context, selection plugin.OverviewFilterSelection) (plugin.OverviewFilterResult, error) {
	f.selections = append(f.selections, selection)
	return plugin.OverviewFilterResult{Status: "applied"}, nil
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
	bindings := NewOverviewSelection(native, t.Context(), "workspace-alpha").Bindings()
	tools := map[string]plugin.ToolBinding{}
	for _, binding := range bindings {
		tools[binding.Name] = binding
	}
	return tools
}

type overviewObservation struct {
	plugin.OverviewClientContext
	ObservationID string `json:"observationId"`
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

func selectOverview(t *testing.T, tools map[string]plugin.ToolBinding, id string, target any, wantStatus string) {
	t.Helper()
	raw := executeOverview(t, tools, "select_tag_filter", map[string]any{"observationId": id, "tag": target})
	var result struct{ Status string }
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	if result.Status != wantStatus {
		t.Fatalf("select %v: status = %q; want %q", target, result.Status, wantStatus)
	}
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

func assertOverviewSelections(t *testing.T, native *overviewFixture, want []plugin.OverviewFilterSelection) {
	t.Helper()
	if !reflect.DeepEqual(native.selections, want) {
		t.Fatalf("native selections = %+v; want %+v", native.selections, want)
	}
}

func stringPointer(value string) *string { return &value }

func TestOverviewRetiredToolsCannotReadOrWrite(t *testing.T) {
	lifetime, cancel := context.WithCancel(t.Context())
	native := &overviewFixture{clients: []plugin.OverviewClientSnapshot{overviewClient()}}
	tools := NewOverviewSelection(native, lifetime, "workspace-alpha").Bindings()
	cancel()
	for _, tool := range tools {
		if _, err := tool.Execute(t.Context(), plugin.ToolCall{Arguments: json.RawMessage(`{}`)}); err == nil {
			t.Fatalf("retired %s retained authority", tool.Name)
		}
	}
	if len(native.selections) != 0 {
		t.Fatal("retired authority selected a filter")
	}
}
func TestOverviewRejectsUnobservedSelection(t *testing.T) {
	native := &overviewFixture{clients: []plugin.OverviewClientSnapshot{overviewClient()}}
	tools := overviewTools(t, native)
	selectOverview(t, tools, "invented-observation", "Shared", "stale")
	if len(native.selections) != 0 {
		t.Fatal("unobserved selection reached client")
	}
}
