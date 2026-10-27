package plugin

import (
	"context"
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

var (
	LifecycleCapabilityKey               = CapabilityKey{"mokusei.lifecycle", 1, "runtime"}
	BackgroundSessionsCapabilityKey      = CapabilityKey{"mokusei.background-sessions", 1, "runtime"}
	BackgroundConfigurationCapabilityKey = CapabilityKey{"mokusei.background-configuration", 1, "runtime"}
	BackgroundEnvironmentCapabilityKey   = CapabilityKey{"mokusei.background-environment", 1, "runtime"}
	OrdinaryTaskReadCapabilityKey        = CapabilityKey{"mokusei.tasks.read", 1, "runtime"}
	ClassificationReadCapabilityKey      = CapabilityKey{"mokusei.classification.read", 1, "runtime"}
	SemanticTagsReadCapabilityKey        = CapabilityKey{"mokusei.tags.read", 1, "runtime"}
	SemanticTagsWriteCapabilityKey       = CapabilityKey{"mokusei.tags.write", 1, "runtime"}
	OrdinaryTaskSnapshotCapabilityKey    = CapabilityKey{"mokusei.tasks.snapshot", 1, "snapshot"}
	SemanticTagsSnapshotCapabilityKey    = CapabilityKey{"mokusei.tags.snapshot", 1, "snapshot"}
	OverviewControlCapabilityKey         = CapabilityKey{"mokusei.overview-control", 1, "runtime"}
	ApplicationProcessCapabilityKey      = CapabilityKey{"mokusei.process", 1, "runtime"}
)

type LifecycleSubject struct {
	Kind   string `json:"kind"`
	ID     string `json:"id"`
	TypeID string `json:"typeId"`
}
type LifecycleEvent struct {
	ID                       string           `json:"id"`
	CreatedAt                int64            `json:"createdAt"`
	Type                     string           `json:"type"`
	Subject                  LifecycleSubject `json:"subject"`
	Scope                    string           `json:"scope,omitempty"`
	Source                   string           `json:"source"`
	Data                     json.RawMessage  `json:"data"`
	IntroducedInteractionIDs []string         `json:"introducedInteractionIds,omitempty"`
}

// A nil inclusion slice is absent; a non-nil empty inclusion matches no events.
type LifecycleFilter struct {
	Sources               []string `json:"sources,omitempty"`
	ExcludeSources        []string `json:"excludeSources,omitempty"`
	Types                 []string `json:"types,omitempty"`
	ExcludeTypes          []string `json:"excludeTypes,omitempty"`
	SubjectKinds          []string `json:"subjectKinds,omitempty"`
	SubjectTypeIDs        []string `json:"subjectTypeIds,omitempty"`
	ExcludeSubjectTypeIDs []string `json:"excludeSubjectTypeIds,omitempty"`
	SubjectIDs            []string `json:"subjectIds,omitempty"`
	// Scope narrows a rule to one directory. Empty adds no plugin restriction;
	// the host still intersects every rule with the instance binding.
	Scope string `json:"scope,omitempty"`
}

// Scope branches are OR; fields in each branch are AND. A zero-length scope
// matches nothing; use one empty LifecycleFilter to match all permitted events.
type LifecycleScope []LifecycleFilter
type LifecycleConsumerDefinition struct {
	ID      string
	Filter  LifecycleScope
	History LifecycleScope
	Replay  string
}
type LifecycleWork struct {
	ID            string                     `json:"id"`
	EventIDs      []string                   `json:"eventIds"`
	Attempts      int                        `json:"attempts"`
	NextAttemptAt int64                      `json:"nextAttemptAt"`
	ExecutionID   string                     `json:"executionId,omitempty"`
	Receipts      map[string]json.RawMessage `json:"receipts"`
}
type LifecycleWorkUpdate struct {
	ID            string
	EventIDs      []string
	Attempts      int
	NextAttemptAt int64
	ExecutionID   string
}
type LifecycleHistoryEntry struct {
	LifecycleEvent
	Outcomes map[string]string `json:"outcomes"`
}
type PageRequest struct {
	Cursor string
	Limit  int
}
type Page[T any] struct {
	Items      []T    `json:"items"`
	NextCursor string `json:"nextCursor,omitempty"`
}
type LifecycleHistoryQuery struct {
	PageRequest
	EventIDs []string
}
type PendingEventsQuery struct {
	ExcludeIDs   []string
	ExcludeTypes []string
	Limit        int
}
type LifecycleNotification struct {
	Pending     []LifecycleEvent
	Work        *LifecycleWork
	Observation *model.PublicObservation
}
type LifecycleConsumer interface {
	ID() string
	Work() *LifecycleWork
	Read(LifecycleHistoryQuery) (Page[LifecycleHistoryEntry], error)
	Pending(PendingEventsQuery) ([]LifecycleEvent, error)
	Begin(context.Context, []string) (LifecycleWork, error)
	Update(context.Context, LifecycleWorkUpdate) error
	Settle(context.Context, string, string) error
	Subscribe(ctx context.Context, listener func(LifecycleNotification), observeOwnSession *PrivateSessionRef) (func(), error)
}
type LifecycleCapability interface {
	Register(LifecycleConsumerDefinition) (LifecycleConsumer, error)
	Subscribe(context.Context, LifecycleScope, func(LifecycleEvent)) (func(), error)
}

type ResolvedBackgroundConfiguration struct {
	SessionKey       string
	SessionRevision  *int64
	SettingsRevision int64
	HarnessID        string
	Cwd              string
	ThreadSettings   json.RawMessage
	ConfigurationKey string
}
type BackgroundConfigurationCapability interface {
	Resolve(context.Context, string) (ResolvedBackgroundConfiguration, error)
}
type PrivateSessionRef struct {
	Owner      BackgroundAgentRef `json:"owner"`
	SessionKey string             `json:"sessionKey"`
	SessionID  string             `json:"sessionId"`
}
type PrivateSessionSnapshot struct {
	Ref              PrivateSessionRef
	ConfigurationKey string
	Record           model.SessionRecord
}
type SessionSendResult struct {
	ExecutionID         string `json:"executionId"`
	StartedNewExecution bool   `json:"startedNewExecution"`
}
type SessionSendAdmitted func(SessionSendResult) error
type PrivateSessionHandle interface {
	Ref() PrivateSessionRef
	Observation() model.PublicObservation
	Send(context.Context, model.AgentInput, []ContextEntry, SessionSendAdmitted) (SessionSendResult, error)
	Interrupt(context.Context, *string) error
	Close() error
}
type ConfigureSessionRequest struct {
	SessionKey       string
	ExpectedRevision *int64
	Configuration    ResolvedBackgroundConfiguration
}
type OpenSessionRequest struct {
	SessionKey string
	Injection  Injection
}
type BackgroundSessionsCapability interface {
	Read(string) (*PrivateSessionSnapshot, error)
	Configure(context.Context, ConfigureSessionRequest) (PrivateSessionSnapshot, error)
	Open(context.Context, OpenSessionRequest) (PrivateSessionHandle, error)
}
type BackgroundEnvironmentCapability interface {
	Owner() BackgroundAgentRef
	Cwd() string
	OutputLocale(context.Context) (string, error)
	Log(level, event string, fields model.Object)
}

type OrdinaryTaskSnapshot struct {
	// Scope is the host-resolved directory identity, independent of its label.
	Scope        string                  `json:"scope"`
	Ref          model.ThreadRef         `json:"ref"`
	Title        string                  `json:"title"`
	HarnessID    string                  `json:"harnessId"`
	Cwd          string                  `json:"cwd"`
	ExecutionCwd string                  `json:"executionCwd"`
	Archived     bool                    `json:"archived"`
	Tags         model.TagProjection     `json:"tags"`
	Observation  model.PublicObservation `json:"observation"`
}
type TaskHistorySnapshot struct {
	Task    OrdinaryTaskSnapshot `json:"task"`
	Content string               `json:"content"`
}
type OrdinaryTaskReadCapability interface {
	CaptureList(ctx context.Context, includeArchived bool) ([]OrdinaryTaskSnapshot, error)
	Get(context.Context, model.ThreadRef) (*OrdinaryTaskSnapshot, error)
	CaptureHistory(context.Context, model.ThreadRef) (TaskHistorySnapshot, error)
	ReadThread(context.Context, model.ThreadRef, string) (string, error)
	ResolveExecution(context.Context, model.ExecutionRef) (*model.PublicExecution, error)
}
type OrdinaryTaskSnapshotCapability interface {
	Scope(model.ThreadRef) (MutationScope, error)
	Get(model.ThreadRef) (*OrdinaryTaskSnapshot, error)
	ResolveExecution(model.ExecutionRef) (*model.PublicExecution, error)
}
type ClassificationThreadSnapshot struct {
	Ref              model.ThreadRef     `json:"ref"`
	Title            string              `json:"title"`
	Archived         bool                `json:"archived"`
	Tags             model.TagProjection `json:"tags"`
	EvidenceRevision string              `json:"evidenceRevision"`
}
type ClassificationEvidenceSnapshot struct {
	Thread  ClassificationThreadSnapshot `json:"thread"`
	Content string                       `json:"content"`
}
type ClassificationReadCapability interface {
	CaptureList(ctx context.Context, includeArchived bool) ([]ClassificationThreadSnapshot, error)
	Get(context.Context, model.ThreadRef) (*ClassificationThreadSnapshot, error)
	CaptureEvidence(context.Context, model.ThreadRef) (ClassificationEvidenceSnapshot, error)
}
type TagTypeUsageCount struct {
	TypeID   string `json:"typeId"`
	Total    int    `json:"total"`
	Archived int    `json:"archived"`
}
type SemanticTagSummary struct {
	Emoji       string              `json:"emoji"`
	Name        string              `json:"name"`
	Description string              `json:"description"`
	Usage       []TagTypeUsageCount `json:"usage"`
}
type SemanticTagThread struct {
	Ref      model.ThreadRef     `json:"ref"`
	Title    string              `json:"title"`
	Tags     model.TagProjection `json:"tags"`
	Archived bool                `json:"archived"`
}
type SemanticTagUsage struct {
	CanonicalName *string             `json:"canonicalName"`
	Threads       []SemanticTagThread `json:"threads"`
}
type SemanticTagsReadCapability interface {
	CaptureList(context.Context) ([]SemanticTagSummary, error)
	CaptureUsage(context.Context, string) (SemanticTagUsage, error)
}
type SemanticTagsSnapshotCapability interface {
	Scope() (MutationScope, error)
	ReadThreadTags(model.ThreadRef) (model.TagProjection, error)
}
type SemanticTagAssignment struct {
	Thread model.ThreadRef `json:"thread"`
	Tags   []string        `json:"tags"`
}
type SemanticTagInput struct {
	Name  string `json:"name"`
	Emoji string `json:"emoji"`
}
type SemanticTagOperation struct {
	Emoji       *string                 `json:"emoji,omitempty"`
	Definitions []SemanticTagInput      `json:"definitions,omitempty"`
	Kind        string                  `json:"kind"`
	Name        string                  `json:"name,omitempty"`
	Description *string                 `json:"description,omitempty"`
	NewName     string                  `json:"newName,omitempty"`
	Names       []string                `json:"names,omitempty"`
	Target      string                  `json:"target,omitempty"`
	Thread      *model.ThreadRef        `json:"thread,omitempty"`
	Tags        []string                `json:"tags,omitempty"`
	Assignments []SemanticTagAssignment `json:"assignments,omitempty"`
}
type BackgroundWriteOptions struct {
	RequestID string
	Batch     BatchWriteContext
}
type SemanticTagsWriteCapability interface {
	EnsureInventory(context.Context) error
	Execute(context.Context, SemanticTagOperation, BackgroundWriteOptions) (json.RawMessage, error)
}

type OverviewFilter struct {
	Tag     string            `json:"tag"`
	Scope   string            `json:"scope,omitempty"`
	Kind    string            `json:"kind"`
	Aliases []string          `json:"aliases"`
	Count   int               `json:"count"`
	Threads []model.ThreadRef `json:"threads"`
}
type OverviewUserAction struct {
	Kind   string           `json:"kind"`
	At     float64          `json:"at"`
	Tag    json.RawMessage  `json:"tag,omitempty"`
	View   string           `json:"view,omitempty"`
	Thread *model.ThreadRef `json:"thread,omitempty"`
	Text   *string          `json:"text,omitempty"`
}
type OverviewClientContext struct {
	ContextID       string               `json:"contextId"`
	Revision        int64                `json:"revision"`
	OverviewVisible bool                 `json:"overviewVisible"`
	Focused         bool                 `json:"focused"`
	DocumentVisible bool                 `json:"documentVisible"`
	MokuOpen        bool                 `json:"mokuOpen"`
	SettingsOpen    bool                 `json:"settingsOpen"`
	SelectedThread  *model.ThreadRef     `json:"selectedThread"`
	FollowUpThread  *model.ThreadRef     `json:"followUpThread"`
	View            string               `json:"view"`
	SelectedTag     *string              `json:"selectedTag"`
	SelectedScope   *string              `json:"selectedScope,omitempty"`
	Filters         []OverviewFilter     `json:"filters"`
	RecentActions   []OverviewUserAction `json:"recentActions"`
}
type OverviewClientSnapshot struct {
	OverviewClientContext
	ClientID string `json:"clientId"`
}
type OverviewFilterSelection struct {
	ClientID  string  `json:"clientId"`
	ContextID string  `json:"contextId"`
	Revision  int64   `json:"revision"`
	Scope     string  `json:"scope,omitempty"`
	Tag       *string `json:"tag"`
}
type OverviewFilterResult struct {
	Status  string                  `json:"status"`
	Context *OverviewClientSnapshot `json:"context"`
}
type OverviewControl interface {
	ReadClients(context.Context) ([]OverviewClientSnapshot, error)
	SelectFilter(context.Context, OverviewFilterSelection) (OverviewFilterResult, error)
}
type ApplicationProcessInput struct {
	Command        string
	Args           []string
	Cwd            string
	TimeoutMS      int64
	MaxOutputBytes int64
	Env            map[string]*string
}
type ApplicationProcessResult struct {
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	ExitCode int    `json:"exitCode"`
}
type ApplicationProcessError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *ApplicationProcessError) Error() string { return e.Message }

type ApplicationProcessCapability interface {
	Run(context.Context, ApplicationProcessInput) (ApplicationProcessResult, error)
}
