// Package transport implements the authenticated local HTTP/NDJSON protocol.
// Business state remains owned by Host; transport owns only client presentation
// leases, bounded delivery queues and durable command receipts.
package transport

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const (
	ProtocolVersion      = 11
	MaxRequestBytes      = 144 * 1024 * 1024
	MaxOverviewBytes     = 2 * 1024 * 1024
	MaxResponseBytes     = 32 * 1024 * 1024
	MaxEventBytes        = MaxResponseBytes
	maxClients           = 32
	maxActiveRequests    = 16
	maxSessionRequests   = 16
	maxInFlightBodyBytes = 192 * 1024 * 1024
	contentWriteLimit    = MaxEventBytes - 256*1024
)

type Failure struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type Result struct {
	OK    bool            `json:"ok"`
	Value json.RawMessage `json:"value,omitempty"`
	Error *Failure        `json:"error,omitempty"`
}
type ContentScope struct {
	Kind string `json:"kind"`
	Key  string `json:"key,omitempty"`
}
type ContentSnapshot struct {
	Revision int64
	Value    json.RawMessage
}

// Callbacks must supply immutable, complete JSON values. The transport copies
// them before delivery. SubscribeMutations returns an idempotent unsubscribe.
// ReadThreadContent may return nil when knownRevision is already current.
type Host interface {
	Invoke(context.Context, string, []json.RawMessage) (any, error)
	HasChannel(string) bool
	SubscribeMutations(func(json.RawMessage)) func()
	ReadThreadContent(context.Context, string, ContentScope, *int64) (*ContentSnapshot, error)
}

func resultSuccess(value any) Result {
	raw, err := json.Marshal(value)
	if err != nil {
		return resultFailure(model.NewError("INVALID_RESPONSE", "Runtime result could not be serialized"))
	}
	return Result{OK: true, Value: raw}
}
func resultFailure(err error) Result {
	code := "COMMAND_FAILED"
	message := "Runtime command failed"
	var failure *model.Error
	if errors.As(err, &failure) {
		code = failure.Code
	}
	if err != nil {
		message = err.Error()
	}
	if len(code) > 128 {
		code = code[:128]
	}
	if len(message) > 8192 {
		message = message[:8192]
	}
	return Result{Error: &Failure{Code: code, Message: message}}
}
func randomToken() (string, error) {
	data := make([]byte, 32)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}
func CreateCommandID() (string, error) {
	token, err := randomToken()
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%d_%s", time.Now().UnixMilli(), token), nil
}

// CommandID carries the durable HTTP request identity into host diagnostics.
// The unexported key prevents unrelated context values from forging a trace.
type commandIdentityKey struct{}

func CommandID(ctx context.Context) string {
	value, _ := ctx.Value(commandIdentityKey{}).(string)
	return value
}
