package plugin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"strings"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type ApplicationManifest struct {
	// BuiltIn services are always available and have no user plugin switch.
	BuiltIn     bool          `json:"builtIn,omitempty"`
	ID          string        `json:"id"`
	DisplayName string        `json:"displayName"`
	APIVersion  int           `json:"apiVersion"`
	Contributes Contributions `json:"contributes"`
}
type Contributions struct {
	BackgroundAgents []string `json:"backgroundAgents"`
	ThreadTypes      []string `json:"threadTypes"`
	Settings         []string `json:"settings"`
	Collections      []string `json:"collections"`
	Queries          []string `json:"queries"`
	Commands         []string `json:"commands"`
}
type Application interface {
	Manifest() ApplicationManifest
	// Register declares functions only; no processes, network, or background work.
	// The host freezes and verifies all contributions before creating participants.
	Register(Registry) error
}
type Registry interface {
	Collection(CollectionDefinition) error
	Settings(SettingsDefinition) error
	Query(QueryDefinition) error
	ExternalQuery(ExternalQueryDefinition) error
	Command(CommandDefinition) error
	ThreadType(ThreadTypeDefinition) error
	BackgroundAgent(BackgroundAgentDefinition) error
}

// ValueContract validates both entering and leaving a plugin boundary. Parse
// returns detached, normalized JSON; schema versions are independently checked.
type ValueContract struct {
	ID            string
	SchemaVersion int
	JSONSchema    json.RawMessage
	Parse         func(json.RawMessage) (json.RawMessage, error)
}

func (c ValueContract) Validate(value json.RawMessage) (json.RawMessage, error) {
	if c.ID == "" || c.SchemaVersion < 1 || c.Parse == nil {
		return nil, fmt.Errorf("invalid value contract %q", c.ID)
	}
	if !json.Valid(value) {
		return nil, fmt.Errorf("expected JSON: %s", c.ID)
	}
	result, err := c.Parse(model.CloneRaw(value))
	if err != nil {
		return nil, err
	}
	if !json.Valid(result) {
		return nil, fmt.Errorf("contract %s returned invalid JSON", c.ID)
	}
	return model.CloneRaw(result), nil
}

type CollectionDefinition struct {
	ID            string
	OwnerPluginID string
	Retention     string // history or settings
	Contract      ValueContract
}
type CapabilityKey struct {
	ID         string
	APIVersion int
	Phase      string
}
type CapabilityAccess interface {
	// Require rejects unknown, undeclared, incompatible and out-of-scope keys.
	Require(CapabilityKey) (any, error)
}

func Require[T any](access CapabilityAccess, key CapabilityKey) (T, error) {
	var zero T
	if access == nil {
		return zero, fmt.Errorf("capability unavailable: %s", key.ID)
	}
	raw, err := access.Require(key)
	if err != nil {
		return zero, err
	}
	value, ok := raw.(T)
	if !ok {
		return zero, fmt.Errorf("incompatible capability implementation: %s", key.ID)
	}
	return value, nil
}

type SettingsDefinition struct {
	ID            string
	OwnerPluginID string
	Contract      ValueContract
	Defaults      json.RawMessage
	Requires      []CapabilityKey
	Validate      func(context.Context, json.RawMessage, CapabilityAccess) (json.RawMessage, error)
}
type QueryAudience struct {
	User       bool
	Background bool
}
type CommandAudience struct {
	User       bool
	Background string
} // deny, batch-required, allow-unbatched

type Operation struct {
	ID            string
	OwnerPluginID string
	Input         ValueContract
	Output        ValueContract
}
type QueryDefinition struct {
	Operation
	Audience QueryAudience
	Requires []CapabilityKey
	Read     func(json.RawMessage, ReadContext) (json.RawMessage, error)
}
type ExternalQueryDefinition struct {
	Operation
	Audience         QueryAudience
	Requires         []CapabilityKey
	SnapshotRequires []CapabilityKey
	Read             func(context.Context, json.RawMessage, ExternalReadContext) (json.RawMessage, error)
}
type CommandDefinition struct {
	Operation
	Audience CommandAudience
	Requires []CapabilityKey
	Plan     func(json.RawMessage, ReadContext) ([]MutationScope, error)
	Reduce   func(json.RawMessage, TransactionContext) (json.RawMessage, error)
}

var scopeSequence atomic.Uint64

// MutationScope is a snapshot reader-issued claim, not storage authority. Hosts
// must accept only exact scope tokens issued by the active plan's own reader.
// Validation covers the collection revision too, preventing phantom inserts.
type MutationScope struct {
	collection string
	recordID   string
	revision   int64
	token      uint64
}

func NewMutationScope(collection, recordID string, revision int64) MutationScope {
	return MutationScope{collection: collection, recordID: recordID, revision: revision, token: scopeSequence.Add(1)}
}
func (s MutationScope) Collection() string { return s.collection }
func (s MutationScope) RecordID() string   { return s.recordID }
func (s MutationScope) Revision() int64    { return s.revision }
func (s MutationScope) Token() uint64      { return s.token }

type RecordsReader interface {
	Get(collectionID, recordID string) (*model.VersionedRecord, error)
	List(collectionID string) ([]model.VersionedRecord, error)
	// An empty recordID claims the whole collection, including membership changes.
	Scope(collectionID, recordID string) (MutationScope, error)
}
type RecordWriteOptions struct {
	ExpectedRevision *int64 // nil means the record must not exist
	TouchUpdatedAt   bool
}
type RecordsWriter interface {
	RecordsReader
	Put(collectionID, recordID string, value json.RawMessage, options RecordWriteOptions) (model.VersionedRecord, error)
	Delete(collectionID, recordID string, expectedRevision int64) error
}
type ReadContext struct {
	// Owner is supplied by the host; its zero value denotes a user query.
	Owner        BackgroundAgentRef
	Records      RecordsReader
	Capabilities CapabilityAccess
}
type ExternalReadContext struct {
	Snapshot     ReadContext
	Capabilities CapabilityAccess
}
type TransactionContext struct {
	Owner        BackgroundAgentRef
	Records      RecordsWriter
	Capabilities CapabilityAccess // snapshot capabilities only
	CommandID    string
	CommittedAt  int64                        // fixed across reducer replay
	AllocateID   func(localKey string) string // stable for commandID + localKey
}
type BatchWriteContext struct {
	ConsumerID   string
	BatchID      string
	InvocationID string
}
type DomainCommandOptions struct {
	RequestID string
	Batch     *BatchWriteContext
}
type DomainClient interface {
	Query(context.Context, string, json.RawMessage) (json.RawMessage, error)
	Execute(context.Context, string, json.RawMessage, DomainCommandOptions) (json.RawMessage, error)
}
type SettingsSnapshot struct {
	SettingsRevision int64
	Value            json.RawMessage
}
type SettingsReader interface {
	Read(settingsID string) (SettingsSnapshot, error)
	Subscribe(ctx context.Context, settingsID string, listener func(SettingsSnapshot)) (func(), error)
}

type ThreadProjection struct {
	Scope string
	Title string
	View  json.RawMessage
}
type ThreadTypeDefinition struct {
	// SearchText is an optional, pure owner projection of user-facing retrieval
	// text. The host calls it only after explicit content-indexing consent.
	SearchText     func(model.ApplicationThreadRecord) (string, error)
	ID             string
	OwnerPluginID  string
	DisplayName    string
	CollectionID   string
	Contract       ValueContract
	Project        func(model.ApplicationThreadRecord) (ThreadProjection, error)
	Tags           ThreadTags
	Classification ThreadClassification
	Archive        ThreadArchive
	Overview       ThreadOverview
	Conversation   ThreadConversation
}
type ThreadStateChange struct {
	Value          json.RawMessage
	TouchUpdatedAt bool
}
type ThreadTagSnapshot struct {
	Thread model.ThreadRef
	Tags   model.TagProjection
}
type SemanticTagEffect struct {
	SourceThreads []ThreadTagSnapshot
}
type ThreadTags interface {
	Project(model.ApplicationThreadRecord) (model.TagProjection, error)
	Sources(model.ApplicationThreadRecord) ([]model.ThreadRef, error)
	Apply(model.ApplicationThreadRecord, SemanticTagEffect) (ThreadStateChange, error)
}
type ClassificationEvidence struct {
	Content  string
	Revision string
}
type ThreadClassification interface {
	Evidence(model.ApplicationThreadRecord) (ClassificationEvidence, error)
}
type ThreadArchive interface {
	Archived(model.ApplicationThreadRecord) bool
	Change(model.ApplicationThreadRecord, bool) (ThreadStateChange, error)
	RelatedLatestExecutions(model.ApplicationThreadRecord, bool) ([]model.ExecutionRef, error)
}
type ThreadOverview interface {
	Presentation(model.ApplicationThreadRecord) (OverviewPresentation, error)
}
type OverviewPresentation struct {
	TagFilter        string               `json:"tagFilter,omitempty"`
	Visible          *bool                `json:"visible,omitempty"`
	CoversExecutions []model.ExecutionRef `json:"coversExecutions"`
}
type ConversationConfiguration struct {
	HarnessPreference string
	Cwd               string
	Harnesses         map[string]json.RawMessage
}
type ThreadConversation interface {
	ReadSession(model.ApplicationThreadRecord) (*model.SessionRecord, error)
	InitialConfiguration(model.ApplicationThreadRecord) (ConversationConfiguration, error)
	WithSession(model.ApplicationThreadRecord, model.SessionRecord) (json.RawMessage, error)
}

// InstancePolicy controls how the host partitions instances, independently of
// the participant's model session initialization and idle-resource policy.
type InstancePolicy string

const (
	GlobalInstance    InstancePolicy = "global"
	PerDirectoryScope InstancePolicy = "per-directory-scope"
)

type ScopeKind string

const (
	GlobalScope        ScopeKind = "global"
	DirectoryScopeKind ScopeKind = "directory"
)

type ScopeBinding struct {
	Kind  ScopeKind `json:"kind"`
	Scope string    `json:"scope,omitempty"`
}

func (b ScopeBinding) Validate() error {
	switch b.Kind {
	case GlobalScope:
		if b.Scope == "" {
			return nil
		}
	case DirectoryScopeKind:
		if validDirectoryScope(b.Scope) {
			return nil
		}
	}
	return errors.New("invalid background scope binding")
}
func (b ScopeBinding) Allows(scope string) bool {
	return b.Validate() == nil && (b.Kind == GlobalScope || b.Scope == scope)
}
func validDirectoryScope(scope string) bool {
	return scope == "inbox" || (path.IsAbs(scope) && path.Clean(scope) == scope && !strings.ContainsRune(scope, 0))
}

// DirectoryScope is an identity and display label, never an agent request.
type DirectoryScope struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

func (s DirectoryScope) Validate() error {
	if !validDirectoryScope(s.ID) || strings.TrimSpace(s.Label) == "" {
		return errors.New("invalid directory scope")
	}
	return nil
}

type BackgroundAgentRef struct {
	PluginID   string       `json:"pluginId"`
	AgentID    string       `json:"agentId"`
	Binding    ScopeBinding `json:"binding"`
	ScopeLabel string       `json:"scopeLabel,omitempty"`
}

type RuntimeStartContext struct{ Reason string }
type RuntimeParticipant interface {
	Start(context.Context, RuntimeStartContext) error
	// Revoke admissions synchronously, then drain sends/openings/cancellation.
	Stop(context.Context) error
}
type BackgroundAgentDefinition struct {
	ID                  string
	Requires            []CapabilityKey
	ExecutionSettingsID string
	InstancePolicy      InstancePolicy
	Create              func(BackgroundAgentContext) (RuntimeParticipant, error)
}
type BackgroundAgentContext struct {
	Owner        BackgroundAgentRef
	Capabilities CapabilityAccess
	Domain       DomainClient
	Settings     SettingsReader
}

// OperationRequest is shared at the runtime/application boundary; implementations
// do not import a concrete runtime host to expose their operation dispatcher.
type OperationRequest struct {
	PluginID    string          `json:"pluginId"`
	OperationID string          `json:"operationId"`
	Input       json.RawMessage `json:"input"`
	RequestID   string          `json:"requestId,omitempty"`
}
