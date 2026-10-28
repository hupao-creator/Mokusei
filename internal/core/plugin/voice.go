package plugin

import "context"

type VoiceEvent struct {
	Sequence      int64   `json:"sequence"`
	Type          string  `json:"type"`
	Text          *string `json:"text,omitempty"`
	Generation    *int64  `json:"generation,omitempty"`
	DeliveryID    string  `json:"deliveryId,omitempty"`
	InputID       string  `json:"inputId,omitempty"`
	SessionID     string  `json:"sessionId,omitempty"`
	ItemID        string  `json:"itemId,omitempty"`
	ReplyToItemID string  `json:"replyToItemId,omitempty"`
	Role          string  `json:"role,omitempty"`
	Complete      *bool   `json:"complete,omitempty"`
	CreatedAt     *int64  `json:"createdAt,omitempty"`
}
type VoiceTranscriptMessage struct {
	ID        string `json:"id"`
	SessionID string `json:"sessionId"`
	Role      string `json:"role"`
	Text      string `json:"text"`
	Complete  bool   `json:"complete"`
	CreatedAt int64  `json:"createdAt"`
}

func VoiceTranscript(event VoiceEvent) *VoiceTranscriptMessage {
	if event.Type != "transcript" || event.SessionID == "" || event.ItemID == "" || event.Role == "" || event.CreatedAt == nil || event.Complete == nil {
		return nil
	}
	text := ""
	if event.Text != nil {
		text = *event.Text
	}
	return &VoiceTranscriptMessage{ID: event.SessionID + ":" + event.ItemID, SessionID: event.SessionID, Role: event.Role, Text: text, Complete: *event.Complete, CreatedAt: *event.CreatedAt}
}

type VoiceDelegation struct {
	ID         string
	Text       string
	Context    string
	Generation int64
}
type VoiceSpeech struct {
	DeliveryID   string
	Generation   int64
	Text         string
	DelegationID string
	// A native Moku peer acknowledges this delivery before audio is appended,
	// allowing safe media reconfiguration across separate event transports.
	RequireReceipt bool
}
type VoiceSession interface {
	ID() string
	Closed() bool
	InputGeneration() int64
	OnClose(func()) func()
	OnEvent(func(VoiceEvent)) func()
	OnDelegation(func(VoiceDelegation)) func()
	Start(context.Context, string) (string, error)
	Poll(after int64) ([]VoiceEvent, error)
	Heartbeat()
	FenceInput(inputID string)
	RejectInput(inputID string)
	Speak(context.Context, VoiceSpeech) error
	Stop(context.Context) error
}
type VoiceRequestSource interface {
	OnRequest(func(context.Context, VoiceDelegation, string) error) func()
}
type VoiceContextSync interface {
	SyncContext(context.Context, []ContextEntry) error
}

// VoiceConfigurationRecoverySource reports an exact native handoff rejected
// before Core execution/tool admission. The callback runs only after the old
// native process has been drained; a cleanup error forbids resubmission.
type VoiceConfigurationRecoverySource interface {
	OnConfigurationRecovery(func(VoiceDelegation, error)) func()
}

// VoiceConfigurationCloser retires an idle native owner and drains pending
// handoffs before the caller consumes configuration-recovery callbacks.
type VoiceConfigurationCloser interface {
	CloseForConfiguration(context.Context) error
}

type VoiceSpeechReceipt interface {
	ConfirmSpeech(context.Context, string, int64) error
}

// VoiceCapability prepares an ephemeral fixed-model relay without inference.
type VoiceCapability interface {
	PrepareVoice(context.Context, string) (VoiceSession, error)
}

// NativeVoiceCapability belongs to a task handle or private discussion. A native
// prepare failure must never silently substitute a relay.
type NativeVoiceCapability interface {
	PrepareNativeVoice(context.Context, []ContextEntry) (VoiceSession, error)
}
