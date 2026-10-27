package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
)

func (r *Runtime) HasChannel(channel string) bool { return model.IsCommandChannel(channel) }
func (r *Runtime) Invoke(ctx context.Context, channel string, args []json.RawMessage) (result any, err error) {
	if !r.HasChannel(channel) {
		return nil, fmt.Errorf("unknown command channel: %s", channel)
	}
	if err := r.operational(); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if channel != "history:clear" {
		if err := r.begin(); err != nil {
			return nil, err
		}
		defer r.operations.Done()
	}
	arity := 1
	switch channel {
	case "search:status", "state:load", "history:clear", "moku:clear", "moku:deliveries", "harness:detect-installations", "workspace:list-known-directories":
		arity = 0
	case "attachment:preview", "thread:set-archived", "application:archive":
		arity = 2
	}
	if len(args) != arity {
		return nil, fmt.Errorf("%s expects %d arguments", channel, arity)
	}
	if channel == "app:update-settings" || channel == "harness:settings-presentation" || channel == "harness:detect-installations" {
		finish := r.traceCommand(ctx, channel)
		defer func() { finish(err) }()
	}
	if err := model.ValidateCommandArguments(channel, args); err != nil {
		return nil, err
	}
	switch channel {
	case "moku:record-note-exposure":
		var receipt NoteExposureReceipt
		if err := model.Unmarshal(args[0], &receipt); err != nil {
			return nil, err
		}
		return r.RecordNoteExposure(ctx, receipt)
	case "search:status", "search:configure", "search:index", "search:query", "search:model":
		return r.searchCommand(ctx, channel, args)
	case "moku:deliveries":
		return r.PendingMokuDeliveries()
	case "moku:resolve-delivery":
		var request struct {
			ID       string `json:"id"`
			Decision string `json:"decision"`
		}
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		return nil, r.ResolveMokuDelivery(ctx, request.ID, request.Decision)
	case "state:load":
		return r.Snapshot()
	case "settings:diagnostics":
		return nil, r.recordClientDiagnostics(ctx, args[0])
	case "attachment:preview":
		if r.config.Attachments == nil {
			return nil, errors.New("attachment repository unavailable")
		}
		var id, attachment string
		if err := decodeArguments(args, &id, &attachment); err != nil {
			return nil, err
		}
		return r.config.Attachments.Preview(ctx, id, attachment)
	case "attachment:discard":
		if r.config.Attachments == nil {
			return nil, errors.New("attachment repository unavailable")
		}
		var ids []string
		if err := model.Unmarshal(args[0], &ids); err != nil {
			return nil, err
		}
		return nil, r.config.Attachments.Discard(ctx, ids)
	case "moku:stage-attachments":
		if r.config.Attachments == nil {
			return nil, errors.New("attachment repository unavailable")
		}
		var imports []attachments.Import
		if err := model.Unmarshal(args[0], &imports); err != nil {
			return nil, err
		}
		return r.config.Attachments.Stage(ctx, imports)
	case "moku:submit", "moku:clear", "moku:cancel", "moku:voice", "moku:voice-events":
		if channel == "moku:voice" {
			// Peek only at routing. Moku owns the closed, action-specific
			// envelope, including request/session IDs, ownership and SDP.
			var envelope map[string]json.RawMessage
			if err := model.Unmarshal(args[0], &envelope); err != nil {
				return nil, err
			}
			var action string
			if err := model.Unmarshal(envelope["action"], &action); err != nil {
				return nil, err
			}
			if action == "prepare" || action == "start" {
				release, err := r.beginServiceAdmission(false)
				if err != nil {
					return nil, err
				}
				defer release()
			}
		}
		r.mu.Lock()
		moku := r.config.Moku
		r.mu.Unlock()
		if moku == nil {
			return nil, errors.New("Moku participant unavailable")
		}
		return moku.Invoke(ctx, channel, args)
	case "thread:voice", "thread:voice-events":
		return r.threadVoiceChannel(ctx, channel, args[0])
	case "history:clear":
		return nil, r.ClearHistory(ctx)
	case "thread:follow-up":
		var request struct {
			ThreadID string          `json:"threadId"`
			Input    json.RawMessage `json:"input"`
		}
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		input, err := model.ParsePublicAgentInput(request.Input)
		if err != nil {
			return nil, err
		}
		return r.sendThread(ctx, request.ThreadID, input, true)
	case "thread:interrupt":
		var request model.CancellationRequest
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		return r.InterruptThreadTarget(ctx, request.ThreadID, request.ExpectedCancellationID)
	case "thread:interaction-respond":
		var request struct {
			ThreadID      string                     `json:"threadId"`
			ExecutionID   string                     `json:"executionId"`
			InteractionID string                     `json:"interactionId"`
			ActionID      string                     `json:"actionId"`
			Answers       map[string]json.RawMessage `json:"answers,omitempty"`
			Message       string                     `json:"message,omitempty"`
		}
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		response := model.RespondRequest{ExecutionID: request.ExecutionID, InteractionID: request.InteractionID, ActionID: request.ActionID, Answers: request.Answers, Message: request.Message}
		thread, err := r.Thread(request.ThreadID)
		if err != nil {
			return nil, err
		}
		if thread.Moku {
			r.mu.Lock()
			moku := r.config.Moku
			r.mu.Unlock()
			responder, ok := moku.(interface {
				Respond(context.Context, model.RespondRequest) error
			})
			if !ok {
				return nil, errors.New("Moku interaction participant unavailable")
			}
			return nil, responder.Respond(ctx, response)
		}
		return nil, r.RespondThread(ctx, request.ThreadID, response)
	case "thread:read":
		var request struct {
			ThreadID string `json:"threadId"`
			Question string `json:"question"`
		}
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		return r.ReadThread(ctx, request.ThreadID, strings.TrimFunc(request.Question, settingsSpace))
	case "thread:fork":
		var request struct {
			ThreadID string          `json:"threadId"`
			Request  json.RawMessage `json:"request"`
		}
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		id, err := r.ForkThread(ctx, request.ThreadID, request.Request)
		if err != nil {
			return nil, err
		}
		return map[string]string{"threadId": id}, nil
	case "thread:update-settings":
		var request struct {
			ThreadID                 string          `json:"threadId"`
			HarnessID                string          `json:"harnessId"`
			Change                   json.RawMessage `json:"change"`
			ExpectedSettingsRevision int64           `json:"expectedSettingsRevision"`
		}
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		return r.UpdateThreadSettings(ctx, request.ThreadID, request.HarnessID, request.ExpectedSettingsRevision, request.Change)
	case "app:update-settings":
		expected, settings, parseErr := parseSettingsRequest(args[0])
		if parseErr != nil {
			return nil, parseErr
		}
		return r.UpdateSettings(ctx, expected, settings)
	case "harness:detect-installation":
		var id string
		if err := model.Unmarshal(args[0], &id); err != nil {
			return nil, err
		}
		return r.DetectInstallation(ctx, id)
	case "harness:detect-installations":
		return r.DetectInstallations(ctx)
	case "workspace:list-known-directories":
		return r.KnownDirectories(ctx)
	case "harness:install":
		var id string
		if err := model.Unmarshal(args[0], &id); err != nil {
			return nil, err
		}
		h := r.config.Harnesses[id]
		if h == nil {
			return nil, fmt.Errorf("unknown harness: %s", id)
		}
		installer, ok := h.(plugin.Installer)
		if !ok {
			return nil, errors.New("harness does not support installation")
		}
		return nil, installer.Install(ctx)
	case "harness:settings-presentation":
		return r.SettingsPresentation(ctx, args[0])
	case "harness:extension":
		var request struct {
			HarnessID string          `json:"harnessId"`
			Method    string          `json:"method"`
			Payload   json.RawMessage `json:"payload"`
		}
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		if strings.TrimSpace(request.Method) != request.Method || request.Method == "" {
			return nil, errors.New("invalid harness method")
		}
		h := r.config.Harnesses[request.HarnessID]
		if h == nil {
			return nil, fmt.Errorf("unknown harness: %s", request.HarnessID)
		}
		extension, ok := h.(plugin.Extension)
		if !ok {
			return nil, errors.New("harness does not support extension commands")
		}
		return extension.Invoke(ctx, request.Method, request.Payload)
	case "thread:set-archived":
		var id string
		var archived bool
		if err := decodeArguments(args, &id, &archived); err != nil {
			return nil, err
		}
		return nil, r.SetArchived(ctx, id, archived)
	case "application:archive":
		var ref model.ThreadRef
		var archived bool
		if err := decodeArguments(args, &ref, &archived); err != nil {
			return nil, err
		}
		apps, err := r.applications()
		if err != nil {
			return nil, err
		}
		return nil, apps.Archive(ctx, ref, archived)
	case "application:initialize-conversation":
		var ref model.ThreadRef
		if err := model.Unmarshal(args[0], &ref); err != nil {
			return nil, err
		}
		apps, err := r.applications()
		if err != nil {
			return nil, err
		}
		return nil, apps.InitializeConversation(ctx, ref)
	case "application:command", "application:query":
		var request plugin.OperationRequest
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		if request.PluginID == "" || request.OperationID == "" || !json.Valid(request.Input) {
			return nil, errors.New("invalid application operation")
		}
		if channel == "application:command" && (request.RequestID == "" || len(request.RequestID) > 256) {
			return nil, errors.New("application command requestId is required")
		}
		apps, err := r.applications()
		if err != nil {
			return nil, err
		}
		if channel == "application:query" {
			if request.RequestID != "" {
				return nil, errors.New("application query has no requestId")
			}
			return apps.Query(ctx, request)
		}
		return apps.Command(ctx, request)
	}
	return nil, fmt.Errorf("unimplemented command: %s", channel)
}
func (r *Runtime) applications() (Applications, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.config.Applications == nil {
		return nil, errors.New("application participants unavailable")
	}
	return r.config.Applications, nil
}
func decodeArguments(args []json.RawMessage, values ...any) error {
	for i, value := range values {
		if err := model.Unmarshal(args[i], value); err != nil {
			return err
		}
	}
	return nil
}
