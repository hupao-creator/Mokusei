package model

import "encoding/json"

type MokuSettings struct {
	HostHarnessPreference string                     `json:"hostHarnessPreference"`
	ExecutionHarnesses    map[string]json.RawMessage `json:"executionHarnesses"`
	TargetHarnessIDs      []string                   `json:"targetHarnessIds"`
	RoutingGuidance       *string                    `json:"routingGuidance"`
}
type PluginSettings struct {
	ID            string          `json:"id"`
	SchemaVersion int             `json:"schemaVersion"`
	Value         json.RawMessage `json:"value"`
}
type Settings struct {
	Moku           MokuSettings               `json:"moku"`
	Harnesses      map[string]json.RawMessage `json:"harnesses"`
	PluginSettings []PluginSettings           `json:"pluginSettings"`
	PluginEnabled  map[string]bool            `json:"pluginEnabled,omitempty"`
}

func DefaultSettings(harnessIDs []string) Settings {
	harnesses := make(map[string]json.RawMessage, len(harnessIDs))
	for _, id := range harnessIDs {
		harnesses[id] = json.RawMessage(`{}`)
	}
	return Settings{Moku: MokuSettings{HostHarnessPreference: "auto", ExecutionHarnesses: map[string]json.RawMessage{}, TargetHarnessIDs: append([]string{}, harnessIDs...)}, Harnesses: harnesses, PluginSettings: []PluginSettings{}}
}

type RuntimePlugin struct {
	Key               string `json:"key"`
	Enabled           bool   `json:"enabled"`
	UnavailableReason string `json:"unavailableReason,omitempty"`
}
type MokuExecution struct {
	ThreadID    string `json:"threadId"`
	ExecutionID string `json:"executionId"`
	Status      string `json:"status"`
	StartedAt   int64  `json:"startedAt"`
}
type AgentRun struct {
	AgentID     string `json:"agentId"`
	Scope       string `json:"scope,omitempty"`
	ScopeLabel  string `json:"scopeLabel,omitempty"`
	ExecutionID string `json:"executionId"`
	StartedAt   int64  `json:"startedAt"`
}
type AppState struct {
	SearchRevision     int64               `json:"searchRevision"`
	Revision           int64               `json:"revision"`
	DefaultCwd         string              `json:"defaultCwd"`
	Threads            []ThreadRecord      `json:"threads"`
	Executions         []MokuExecution     `json:"executions"`
	AgentRuns          []AgentRun          `json:"agentRuns,omitempty"`
	ApplicationThreads []ApplicationThread `json:"applicationThreads"`
	TagRedirects       map[string]*string  `json:"tagRedirects,omitempty"`
	Settings           Settings            `json:"settings"`
	SettingsRevision   int64               `json:"settingsRevision"`
	Plugins            []RuntimePlugin     `json:"plugins,omitempty"`
}
type CollectionPatch[T any] struct {
	Upserts    []T       `json:"upserts"`
	RemovedIDs []string  `json:"removedIds"`
	Order      *[]string `json:"order,omitempty"`
}
type RuntimeActivity struct {
	ThreadID  string          `json:"threadId"`
	HarnessID string          `json:"harnessId"`
	Activity  HarnessActivity `json:"activity"`
}

// Pointer replacement fields distinguish an omitted field from an empty array
// or map, which clears that part of the client's previous state.
type StateMutation struct {
	SearchRevision     *int64                              `json:"searchRevision,omitempty"`
	Type               string                              `json:"type"`
	BaseRevision       int64                               `json:"baseRevision"`
	Revision           int64                               `json:"revision"`
	Threads            *CollectionPatch[ThreadRecord]      `json:"threads,omitempty"`
	ApplicationThreads *CollectionPatch[ApplicationThread] `json:"applicationThreads,omitempty"`
	DefaultCwd         *string                             `json:"defaultCwd,omitempty"`
	Executions         *[]MokuExecution                    `json:"executions,omitempty"`
	AgentRuns          *[]AgentRun                         `json:"agentRuns,omitempty"`
	TagRedirects       *map[string]*string                 `json:"tagRedirects,omitempty"`
	Settings           *Settings                           `json:"settings,omitempty"`
	SettingsRevision   *int64                              `json:"settingsRevision,omitempty"`
	Plugins            *[]RuntimePlugin                    `json:"plugins,omitempty"`
	Activities         []RuntimeActivity                   `json:"activities,omitempty"`
}
type RendererScope struct {
	Kind string `json:"kind"`
	Key  string `json:"key,omitempty"`
}
type ContentTarget struct {
	ThreadID string        `json:"threadId"`
	Scope    RendererScope `json:"scope"`
}
type ContentSubscription struct {
	SubscriptionID string         `json:"subscriptionId"`
	Target         *ContentTarget `json:"target"`
}
