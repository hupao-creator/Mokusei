// Package plugin defines the statically composed extension boundaries. Adapters
// own native state; the host owns persistence, execution admission and identity.
package plugin

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type HarnessDescriptor struct {
	ID                 string             `json:"id"`
	DisplayName        string             `json:"displayName"`
	ThreadCapabilities ThreadCapabilities `json:"threadCapabilities"`
}
type ThreadCapabilities struct {
	Instructions  bool     `json:"instructions"`
	ThreadContext bool     `json:"threadContext"`
	SendContext   bool     `json:"sendContext"`
	ToolModes     []string `json:"toolModes"`
}

func (c ThreadCapabilities) CanHostMoku() bool {
	if !c.Instructions || !c.ThreadContext || !c.SendContext {
		return false
	}
	for _, mode := range c.ToolModes {
		if mode == "exclusive" {
			return true
		}
	}
	return false
}

type Installation struct {
	Status         string `json:"status"`
	ExecutablePath string `json:"executablePath,omitempty"`
	Message        string `json:"message,omitempty"`
}
type Availability struct {
	Available                 bool   `json:"available"`
	Reason                    string `json:"reason,omitempty"`
	RequiresExplicitSelection bool   `json:"requiresExplicitSelection,omitempty"`
}

// Harness is the minimum complete adapter. Optional behavior is supplied through
// the smaller capability interfaces below, never a successful no-op method.
type Harness interface {
	Descriptor() HarnessDescriptor
	DefaultSettings() json.RawMessage
	Detect(context.Context, string) (Installation, error)
	Settings() HarnessSettings
	SessionState() SessionStateAdapter
	Metadata() ThreadMetadataAdapter
	Open(context.Context, OpenContext) (Handle, error)
}
type HostContext struct {
	ResolveExecutable      func(ctx context.Context, command, cwd, configuredPath string) (string, error)
	Environment            func(context.Context) (map[string]string, error)
	HarnessDataRoot        string
	TemporaryWorkspaceRoot string
}

type SessionStore interface {
	// Read returns a detached snapshot. A caller must not mutate shared authority.
	Read() json.RawMessage
	// Commit snapshots its argument, then projects and durably publishes that exact
	// version through the host's single state-commit path.
	Commit(context.Context, json.RawMessage) error
}
type MetadataSnapshot struct {
	Revision int64
	State    json.RawMessage
}
type MetadataStore interface {
	Read() MetadataSnapshot
	Commit(ctx context.Context, expectedRevision int64, state json.RawMessage) (bool, error)
}
type ExecutionAdmission interface {
	// Accept reserves an identity and durably admits workspace/state before native
	// I/O resumes. The supplied pure projector must expose that identity as running.
	Accept(ctx context.Context, project func(executionID string) (json.RawMessage, error)) (string, error)
}
type TelemetryLedger interface {
	Read(context.Context) (json.RawMessage, error)
	Record(context.Context, json.RawMessage) error
}
type ManagedWorkspaceGrant struct {
	Kind          string   `json:"kind"`
	Cwd           string   `json:"cwd"`
	HeadOID       string   `json:"headOid"`
	WritableRoots []string `json:"writableRoots"`
}
type ManagedWorkspaceWrite interface {
	Grant(context.Context) (ManagedWorkspaceGrant, error)
}
type OpenContext struct {
	ThreadID                string
	ReadThread              func() model.SessionRecord
	RequireExplicitSettings bool
	PublishActivity         func(model.HarnessActivity)
	SessionState            SessionStore
	Metadata                MetadataStore
	ExecutionAdmission      ExecutionAdmission
	TelemetryLedger         TelemetryLedger
	ManagedWorkspaceWrite   ManagedWorkspaceWrite
	Injection               *Injection
}
type Handle interface {
	Send(context.Context, SendRequest) error
	Interrupt(context.Context) error
	Respond(context.Context, model.RespondRequest) error
	Read(context.Context, string) (string, error)
	// Close waits for in-flight work, closes native resources, and releases every
	// child process owned by this handle. Repeated calls are safe.
	Close() error
}

// InteractionResponseNotSentError certifies that no native I/O for this
// response began. Core may release its durable claim only for this error.
// Transport failures and uncertain native acknowledgements must not use it.
type InteractionResponseNotSentError struct{ Cause error }

func (e *InteractionResponseNotSentError) Error() string { return e.Cause.Error() }
func (e *InteractionResponseNotSentError) Unwrap() error { return e.Cause }

type SendRequest struct {
	// Admitted is called exactly once after this input is durably retained.
	// New executions admit before native dispatch; follow-ups may wait for native
	// acceptance so a rejected steer does not acknowledge delivery. Stream updates
	// for older input do not admit a send.
	Admitted       func() error
	ExecutionID    string
	Input          model.AgentInput
	ContextEntries []ContextEntry
}

// ErrExecutionEnded rejects a stale execution reservation before retaining or
// dispatching any input or calling Admitted. The original execution must already
// have its durable terminal outcome. Core may reserve a new execution and retry
// once; ordinary errors (including uncertain dispatch) never authorize replay.
var ErrExecutionEnded = errors.New("execution ended before input admission")

type ContextEntry struct {
	ID      string `json:"id"`
	Content string `json:"content"`
}
type SeedItem struct {
	Type      string          `json:"type"`
	Role      string          `json:"role,omitempty"`
	Content   string          `json:"content,omitempty"`
	CallID    string          `json:"callId,omitempty"`
	Name      string          `json:"name,omitempty"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
	Result    json.RawMessage `json:"result,omitempty"`
	IsError   bool            `json:"isError,omitempty"`
}
type ToolCall struct {
	CallID    string
	Arguments json.RawMessage
}
type ToolBinding struct {
	Name         string
	Description  string
	InputSchema  json.RawMessage
	OutputSchema json.RawMessage
	Execute      func(context.Context, ToolCall) (json.RawMessage, error)
}

// ToolCallError marks a tool failure caused by the caller's arguments, requested
// settings or current Thread state rather than by a harness fault. Bridges may
// report it to the calling model verbatim as a client error instead of hiding
// it behind an internal failure status.
type ToolCallError struct{ Cause error }

func (e *ToolCallError) Error() string {
	if e.Cause == nil {
		return "invalid tool call"
	}
	return e.Cause.Error()
}
func (e *ToolCallError) Unwrap() error { return e.Cause }

// CallerError marks err as caller-correctable and preserves an existing mark so
// every boundary can wrap without stacking types.
func CallerError(err error) error {
	if err == nil {
		return nil
	}
	var marked *ToolCallError
	if errors.As(err, &marked) {
		return err
	}
	return &ToolCallError{Cause: err}
}

type ToolInjection struct {
	Mode     string
	Bindings []ToolBinding
}
type Injection struct {
	Instructions   []string
	ContextEntries []ContextEntry
	Seed           []SeedItem
	Tools          *ToolInjection
}

// SessionStateAdapter read projections may run concurrently across independent
// threads. Implementations must keep shared state immutable or synchronized;
// each projection receives caller-owned native-state bytes.
type SessionStateAdapter interface {
	Project(state json.RawMessage) (model.PublicObservation, error)
	ProjectRenderer(state json.RawMessage, scope model.RendererScope) (json.RawMessage, error)
	ReadContext(state json.RawMessage) (json.RawMessage, error)
	ResolveExecution(state json.RawMessage, executionID string) (*model.PublicExecution, error)
	Settle(SettleRequest) (json.RawMessage, error)
}
type SettleRequest struct {
	SessionState json.RawMessage
	ExecutionID  string
	Outcome      string // failed or interrupted
	FinishedAt   int64
}
type ThreadMetadataAdapter interface {
	Initialize(threadID string, input model.AgentInput, settings json.RawMessage) (json.RawMessage, error)
	Project(state json.RawMessage) (string, error)
	Fork(state json.RawMessage, title string) (json.RawMessage, error)
}
type HarnessSettings interface {
	Normalize(json.RawMessage) (json.RawMessage, error)
	SnapshotExecution(context.Context, SettingsRequest, bool) (json.RawMessage, error)
	Describe(context.Context, SettingsRequest) (json.RawMessage, error)
	DefaultThread(json.RawMessage) (json.RawMessage, error)
	ResolveThread(context.Context, ResolveSettingsRequest) (json.RawMessage, error)
	HasThreadContent(json.RawMessage) bool
	ApplyThreadUpdate(context.Context, UpdateSettingsRequest) (json.RawMessage, error)
	PromptSettings(harnessSettings, sourceThreadSettings json.RawMessage) (json.RawMessage, error)
	Presentation(context.Context, SettingsPresentationRequest) (json.RawMessage, error)
}
type SettingsRequest struct {
	Settings json.RawMessage
	Cwd      string
}
type ResolveSettingsRequest struct {
	// Merged contains projected thread defaults from DefaultThread, never the
	// enclosing harness settings (useDefaultThreadSettings/threadSettings).
	Merged       json.RawMessage
	Existing     json.RawMessage
	Requested    json.RawMessage
	SessionState json.RawMessage
	Cwd          string
}
type UpdateSettingsRequest struct {
	Current    json.RawMessage
	Defaults   json.RawMessage
	Update     json.RawMessage
	HasContent bool
	Cwd        string
}
type SettingsPresentationRequest struct {
	Settings       json.RawMessage
	Cwd            string
	ThreadSettings json.RawMessage
	Refresh        bool
}

type Installer interface{ Install(context.Context) error }
type AvailabilityProbe interface {
	Probe(context.Context, SettingsRequest, string) (Availability, error)
}
type Forker interface {
	Fork(context.Context, ForkRequest) (ForkResult, error)
}
type ForkRequest struct {
	Source  model.ThreadRecord
	Request json.RawMessage
}
type ForkResult struct {
	SessionState  json.RawMessage
	Settings      json.RawMessage
	MetadataState json.RawMessage
}
type Extension interface {
	Invoke(context.Context, string, json.RawMessage) (json.RawMessage, error)
}
type Closer interface{ Close() error }
type CompletedReply interface {
	CompletedReply(executionID string) (string, bool)
}
type PromptCompleter interface {
	Complete(context.Context, PromptRequest) (PromptResult, error)
}
type PromptMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}
type PromptRequest struct {
	// Steering optionally accepts follow-up context within this isolated run.
	Steering     *PromptSteering
	Messages     []PromptMessage
	OutputFormat PromptOutputFormat
	Settings     json.RawMessage
}
type PromptOutputFormat struct {
	Type   string          `json:"type"`
	Schema json.RawMessage `json:"schema,omitempty"`
}
type PromptResult struct {
	Output       PromptOutput `json:"output"`
	FinishReason string       `json:"finishReason"`
}
type PromptOutput struct {
	Type  string          `json:"type"`
	Text  string          `json:"text,omitempty"`
	Value json.RawMessage `json:"value,omitempty"`
}
type WorkspaceDiscoverer interface {
	DiscoverWorkspaceDirectories(context.Context) ([]string, error)
}
type WorkspacePolicy interface {
	WorkspaceDirectoryPolicy(context.Context) (DirectoryPolicy, error)
}
type DirectoryPolicy struct {
	ExcludedRoots []string
	Excludes      func(string) bool
}
type ModelCatalogSource interface {
	ModelCatalog(context.Context, SettingsRequest) (json.RawMessage, error)
}

// CachedModelCatalogSource is an advisory snapshot: cold reads must not wait
// for native catalog or account I/O. Full ModelCatalog remains authoritative.
type CachedModelCatalogSource interface {
	CachedModelCatalog(context.Context, SettingsRequest) (json.RawMessage, error)
}

// MokuTargetDiscoverer advertises an installed native target without waiting for
// its model/account catalog. A nil schema defers exact options to the on-demand
// describe_native_harness tool. Execution always performs full native admission.
type MokuTargetDiscoverer interface {
	DiscoverMokuTarget(context.Context, SettingsRequest) (json.RawMessage, Availability, error)
}
type MokuContextContributor interface {
	MokuContext(context.Context, string, SettingsRequest, TelemetryLedger) (string, error)
}

// Voice and discussion data remain protocol JSON: codecs belong to the owning
// Harness and voice provider rather than to the runtime's persistence layer.
type Voice interface {
	Voice(context.Context, json.RawMessage) (json.RawMessage, error)
}
type DiscussionPreparer interface {
	PrepareDiscussion(context.Context, DiscussionRequest) (Discussion, error)
}
type DiscussionRequest struct {
	Source       model.ThreadRecord
	Tools        []ToolBinding
	Instructions string
}
type Discussion interface {
	Ask(context.Context, string) (string, error)
	Close() error
}
