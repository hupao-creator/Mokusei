package transport

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

var commandIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{16,128}$`)

type commandRequest struct {
	CommandID string            `json:"commandId"`
	Args      []json.RawMessage `json:"args"`
}
type commandExecutor struct {
	mu        sync.Mutex
	accepting bool
	pending   int
	drained   chan struct{}
	host      Host
	receipts  *ReceiptStore
	context   context.Context
}

func newCommandExecutor(host Host, path string, ctx context.Context) (*commandExecutor, error) {
	receipts, err := OpenReceiptStore(path)
	if err != nil {
		return nil, err
	}
	done := make(chan struct{})
	close(done)
	return &commandExecutor{accepting: true, drained: done, host: host, receipts: receipts, context: ctx}, nil
}
func (e *commandExecutor) execute(ctx context.Context, channel string, raw []byte) (Result, error) {
	if channel == "moku:submit" {
	}
	var request commandRequest
	if err := json.Unmarshal(raw, &request); err != nil || request.Args == nil || len(request.Args) > 32 || !commandIDPattern.MatchString(request.CommandID) {
		return Result{}, model.NewError("INVALID_REQUEST", "A valid commandId and args array are required")
	}
	e.mu.Lock()
	if !e.accepting {
		e.mu.Unlock()
		return Result{}, model.NewError("SERVICE_STOPPING", "Runtime is stopping")
	}
	if !e.host.HasChannel(channel) {
		e.mu.Unlock()
		return Result{}, model.NewError("UNKNOWN_COMMAND", "Unknown runtime command")
	}
	if e.pending == 0 {
		e.drained = make(chan struct{})
	}
	e.pending++
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		e.pending--
		if e.pending == 0 {
			close(e.drained)
		}
		e.mu.Unlock()
	}()
	run := func() (any, error) {
		e.mu.Lock()
		accepting := e.accepting
		e.mu.Unlock()
		if !accepting {
			return nil, model.NewError("SERVICE_STOPPING", "Runtime is stopping")
		}
		// Every call ends with the service. Reads also end with their client;
		// admitted writes retain their receipt when only the client disconnects.
		callContext := model.WithClientDevice(e.context, model.ClientDeviceID(ctx))
		if model.IsReadOnlyChannel(channel) {
			var cancel context.CancelFunc
			callContext, cancel = context.WithCancel(ctx)
			stop := context.AfterFunc(e.context, cancel)
			defer stop()
			defer cancel()
		}
		return e.host.Invoke(context.WithValue(callContext, commandIdentityKey{}, request.CommandID), channel, request.Args)
	}
	if model.IsReadOnlyChannel(channel) {
		value, err := run()
		if err != nil {
			return resultFailure(err), nil
		}
		return resultSuccess(value), nil
	}
	args, err := json.Marshal(request.Args)
	if err != nil {
		return Result{}, err
	}
	normalized, err := model.Decode(args)
	if err != nil {
		return Result{}, model.NewError("INVALID_REQUEST", "Arguments are not valid JSON")
	}
	args, err = json.Marshal(normalized)
	if err != nil {
		return Result{}, err
	}
	hash := sha256.New()
	hash.Write([]byte(model.ClientDeviceID(ctx)))
	hash.Write([]byte{0})
	hash.Write([]byte(channel))
	hash.Write([]byte{0})
	hash.Write(args)
	return e.receipts.Execute(ctx, request.CommandID, hex.EncodeToString(hash.Sum(nil)), run)
}
func (e *commandExecutor) revoke() { e.mu.Lock(); e.accepting = false; e.mu.Unlock() }
func (e *commandExecutor) drain(ctx context.Context) error {
	e.mu.Lock()
	done := e.drained
	e.mu.Unlock()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
