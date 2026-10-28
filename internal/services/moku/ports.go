// Package moku owns the task-board coordinator. The runtime supplies durable
// session and ordinary-thread capabilities; Moku never imports concrete storage
// or the runtime package and never interprets a Harness's opaque native state.
package moku

import (
	"context"
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type SendResult = plugin.SessionSendResult
type CreateThreadRequest struct {
	ResolveSettings func(context.Context, string) (json.RawMessage, error)
	HarnessID       string
	Input           model.AgentInput
	Cwd             string
	Settings        json.RawMessage
	Worktree        *model.WorktreeOptions
}
type CreatedThread struct {
	Record          model.ThreadRecord
	Execution       SendResult
	Acknowledgement json.RawMessage
	WorktreeName    string
	// WorktreeNameAdjusted/Notice report that the effective managed-worktree
	// directory differs from the requested worktreeName.
	WorktreeNameAdjusted bool
	WorktreeNameNotice   string
}
type SessionConfiguration struct {
	// Unapplied creates a readable empty shell without claiming an applied native configuration.
	Unapplied        bool
	HarnessID        string
	Settings         json.RawMessage
	AppliedSettings  model.Settings
	SettingsRevision int64
	Cwd              string
	// PreserveNote carries the persistent milestone note into a replacement
	// Thread. A history reset leaves it false so the new Thread starts clean.
	PreserveNote bool
	// PreserveHistory retains the retired native session as read-only history.
	PreserveHistory bool
}
type Configuration struct {
	HarnessEnabled           func(string) bool
	IsDeleting               func(string) bool
	WithSettingsAdmission    func(context.Context, func(context.Context) error) error
	PrepareSettings          func(context.Context, string) (model.Settings, int64, error)
	Workspace                string
	DataDir                  string
	Harnesses                map[string]plugin.Harness
	ReadSessionConfiguration func() (SessionConfiguration, error)
	Settings                 func() (model.Settings, int64, error)
	Threads                  func() ([]model.ThreadRecord, error)
	Thread                   func(string) (model.ThreadRecord, error)
	UpdateThread             func(context.Context, string, func(*model.ThreadRecord) error) error
	UpdateNote               func(context.Context, string, string, *model.NoteBasis) (model.NoteUpdateResult, error)
	EnsureSession            func(context.Context, SessionConfiguration) (model.ThreadRecord, error)
	ReplaceSession           func(context.Context, string, SessionConfiguration) (model.ThreadRecord, error)
	ConfigureSession         func(context.Context, string, int64, SessionConfiguration) error
	OpenSession              func(context.Context, string, *plugin.Injection) error
	SetNativeAdmission       func(string, func(context.Context) error) error
	CloseSession             func(context.Context, string) error
	// onAdmitted runs after durable running observation and before native execution
	// resumes. It must run once for each successful user admission, also follow-ups.
	SendSession               func(context.Context, string, model.AgentInput, *plugin.Injection, []plugin.ContextEntry, func(SendResult) error) (SendResult, error)
	PendingDeliveries         func() ([]plugin.MokuDelivery, error)
	SendDelivery              func(context.Context, string, string, model.AgentInput, *plugin.Injection, []plugin.ContextEntry) (SendResult, error)
	SubscribeCommitted        func(func(model.ThreadRecord)) func()
	SubscribeUserThreadInputs func(context.Context, func(plugin.LifecycleEvent)) (func(), error)
	SubscribeDiagnostics      func(func(string)) func()
	CreateThread              func(context.Context, CreateThreadRequest) (CreatedThread, error)
	SendThread                func(context.Context, string, model.AgentInput) (SendResult, error)
	ReadThread                func(context.Context, string, string) (string, error)
	InterruptThread           func(context.Context, string) error
	InterruptThreadTarget     func(context.Context, string, string) (model.CancellationResult, error)
	ClaimThreadInput          func(context.Context, string) (context.Context, context.CancelFunc, error)
	RespondThread             func(context.Context, string, model.RespondRequest) error
	CanonicalizeInput         func(context.Context, model.AgentInput) (model.AgentInput, error)
	StageAttachments          func(context.Context, json.RawMessage) (any, error)
	CollectContext            func(context.Context, string, model.Settings) ([]plugin.ContextEntry, error)
	Ledger                    func(string) plugin.TelemetryLedger
	PrepareNativeVoice        func(context.Context, string, []plugin.ContextEntry) (plugin.VoiceSession, error)
	Voice                     plugin.VoiceCapability
	CompletedReply            func(string, string) (string, bool)
	ReportFailure             func(string, error)
}
type SubmitRequest struct {
	Input            model.AgentInput `json:"input"`
	DirectoryTag     *string          `json:"directoryTag,omitempty"`
	DirectoryScopeID *string          `json:"directoryScopeId,omitempty"`
	VoiceInput       *struct {
		SessionID   string `json:"sessionId"`
		OwnershipID string `json:"ownershipId"`
		InputID     string `json:"inputId"`
	} `json:"voiceInput,omitempty"`
}
