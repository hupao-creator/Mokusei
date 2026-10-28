package pi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type pendingInteraction struct {
	NativeID, Method string
	Options          []string
	NativeOptions    map[string]string
	Timer            *time.Timer
}
type userEcho struct {
	ID, ExecutionID, Text string
	Echoed                bool
}
type threadHandle struct {
	host                      plugin.HostContext
	open                      plugin.OpenContext
	ctx                       context.Context
	cancel                    context.CancelFunc
	mu                        sync.Mutex
	sendMu                    sync.Mutex
	connMu                    sync.Mutex
	state                     State
	rpc                       *Session
	connectionConfig          string
	connectionCancel          context.CancelFunc
	closed, closing           bool
	assistantID, readSnapshot string
	interactions              map[string]pendingInteraction
	echoes                    []*userEcho
	streamTimer               *time.Timer
	reads                     sync.WaitGroup
	closeDone                 chan struct{}
	closeErr                  error
}

func newID(prefix string) string {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		panic(err)
	}
	return prefix + hex.EncodeToString(bytes[:])
}
func openThread(ctx context.Context, host plugin.HostContext, open plugin.OpenContext) (*threadHandle, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if open.ReadThread == nil || open.SessionState == nil {
		return nil, errors.New("Pi requires Thread and state stores")
	}
	if err := validateInjection(open.Injection); err != nil {
		return nil, err
	}
	state, err := decodeState(open.SessionState.Read())
	if err != nil {
		return nil, err
	}
	life, cancel := context.WithCancel(ctx)
	h := &threadHandle{host: host, open: open, ctx: life, cancel: cancel, state: state, interactions: map[string]pendingInteraction{}, closeDone: make(chan struct{})}
	h.mu.Lock()
	if activeExecution(&h.state) != nil {
		err = h.finishLocked("interrupted", "")
	}
	h.mu.Unlock()
	if err != nil {
		cancel()
		return nil, err
	}
	go func() { <-life.Done(); _ = h.Interrupt(context.Background()) }()
	return h, nil
}
func (h *threadHandle) commitLocked() error {
	if h.streamTimer != nil {
		h.streamTimer.Stop()
		h.streamTimer = nil
	}
	raw, err := json.Marshal(h.state)
	if err != nil {
		return err
	}
	return h.open.SessionState.Commit(context.WithoutCancel(h.ctx), raw)
}
func (h *threadHandle) scheduleCommitLocked() {
	if h.streamTimer != nil {
		return
	}
	h.streamTimer = time.AfterFunc(50*time.Millisecond, func() {
		h.mu.Lock()
		h.streamTimer = nil
		var err error
		if !h.closing && !h.closed {
			err = h.commitLocked()
		}
		h.mu.Unlock()
		if err != nil {
			go h.fail(err)
		}
	})
}
func (h *threadHandle) clearInteractionsLocked() {
	for _, item := range h.interactions {
		if item.Timer != nil {
			item.Timer.Stop()
		}
	}
	h.interactions = map[string]pendingInteraction{}
}
func (h *threadHandle) finishLocked(status, reason string) error {
	current := activeExecution(&h.state)
	if current == nil {
		return nil
	}
	previous := *current
	finish := max(previous.StartedAt, time.Now().UnixMilli())
	*current = model.PublicExecution{ExecutionID: previous.ExecutionID, StartedAt: previous.StartedAt, FinishedAt: &finish, Status: status}
	summary := lastAssistant(h.state, current.ExecutionID)
	if summary != "" {
		current.Summary = &summary
	}
	if status == "failed" && reason != "" {
		reason = clean(reason, 100000)
		current.Error = &reason
	}
	foregrounds := append([]ForegroundState(nil), h.state.Foregrounds...)
	h.state.Foregrounds = slices.DeleteFunc(h.state.Foregrounds, func(f ForegroundState) bool { return f.ExecutionID == current.ExecutionID })
	if err := h.commitLocked(); err != nil {
		*current = previous
		h.state.Foregrounds = foregrounds
		return err
	}
	h.readSnapshot = ""
	h.clearInteractionsLocked()
	h.echoes = nil
	h.assistantID = ""
	return nil
}
func (h *threadHandle) stop(status, reason string) error { return h.stopSession(nil, status, reason) }
func (h *threadHandle) stopSession(expected *Session, status, reason string) error {
	h.connMu.Lock()
	defer h.connMu.Unlock()
	h.mu.Lock()
	if expected != nil && h.rpc != expected {
		h.mu.Unlock()
		return nil
	}
	h.closing = true
	if h.streamTimer != nil {
		h.streamTimer.Stop()
		h.streamTimer = nil
	}
	rpc := h.rpc
	h.rpc = nil
	if h.connectionCancel != nil {
		h.connectionCancel()
		h.connectionCancel = nil
	}
	h.mu.Unlock()
	var closeErr error
	if rpc != nil {
		closeErr = rpc.Close()
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.state.SessionFile != "" {
		data, err := os.ReadFile(h.state.SessionFile)
		if err == nil {
			h.state.NativeSessionJSONL = string(data)
		} else if !errors.Is(err, os.ErrNotExist) {
			h.state.NativeSessionJSONL = ""
		}
	}
	return errors.Join(h.finishLocked(status, reason), closeErr)
}
func (h *threadHandle) fail(err error) {
	h.mu.Lock()
	ignored := h.closing || h.closed
	h.mu.Unlock()
	if !ignored {
		_ = h.stop("failed", err.Error())
	}
}
func (h *threadHandle) canExecute() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return !h.closed && !h.closing && activeExecution(&h.state) != nil
}
func (h *threadHandle) ensureConnection(ctx context.Context, steer bool) (*Session, error) {
	h.connMu.Lock()
	defer h.connMu.Unlock()
	record := h.open.ReadThread()
	cwd := record.Cwd
	if record.Worktree != nil && record.Worktree.Cwd != "" {
		cwd = record.Worktree.Cwd
	}
	settings, err := normalizeThread(record.Settings)
	if err != nil {
		return nil, err
	}
	if h.open.RequireExplicitSettings {
		if err = requireExplicit(settings, true); err != nil {
			return nil, err
		}
	}
	configData, _ := json.Marshal([]any{cwd, settings})
	config := string(configData)
	h.mu.Lock()
	if steer {
		rpc := h.rpc
		valid := rpc != nil && !h.closing && !h.closed
		h.mu.Unlock()
		if !valid {
			return nil, errors.New("Pi active Execution has no native connection")
		}
		return rpc, nil
	}
	if h.closed {
		h.mu.Unlock()
		return nil, errors.New("Pi Thread disposed")
	}
	if h.rpc != nil && !h.closing && h.connectionConfig == config {
		rpc := h.rpc
		h.mu.Unlock()
		return rpc, nil
	}
	old := h.rpc
	h.rpc = nil
	if h.connectionCancel != nil {
		h.connectionCancel()
	}
	h.closing = false
	sourceFile := h.state.SessionFile
	sourceFork := h.state.ForkSource
	life, cancel := context.WithCancel(h.ctx)
	h.connectionCancel = cancel
	h.mu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	accepted := false
	defer func() {
		if !accepted {
			cancel()
		}
	}()
	directory := filepath.Join(h.host.HarnessDataRoot, h.open.ThreadID)
	if filepath.Base(h.open.ThreadID) != h.open.ThreadID || h.open.ThreadID == "." {
		return nil, errors.New("invalid Pi Thread ID")
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	executable, err := resolveExecutable(ctx, h.host, cwd, settings.ExecutablePath)
	if err != nil {
		return nil, err
	}
	env, err := inheritedEnvironment(ctx, h.host)
	if err != nil {
		return nil, err
	}
	effective := settings
	modelArgs := modelArguments(effective)
	hostArgs := []string{}
	var bridge *BridgeOptions
	files := []string{}
	defer func() {
		for _, path := range files {
			_ = os.Remove(path)
		}
	}()
	writeTemporary := func(prefix string, data []byte) (string, error) {
		file, err := os.CreateTemp(directory, prefix)
		if err != nil {
			return "", err
		}
		files = append(files, file.Name())
		if err = file.Chmod(0600); err == nil {
			_, err = file.Write(data)
		}
		closeErr := file.Close()
		return file.Name(), errors.Join(err, closeErr)
	}
	if h.open.Injection != nil {
		config, err := bridgeConfig(*h.open.Injection)
		if err != nil {
			return nil, err
		}
		configFile, err := writeTemporary("host-config-*.json", config)
		if err != nil {
			return nil, err
		}
		extension, err := writeTemporary("host-extension-*.mjs", hostExtension)
		if err != nil {
			return nil, err
		}
		env["MOKUSEI_PI_BRIDGE_CONFIG"] = configFile
		hostArgs = append(hostArgs, "-e", extension)
		bridge = &BridgeOptions{Injection: *h.open.Injection, CanExecute: h.canExecute}
		if tools := h.open.Injection.Tools; tools != nil && tools.Mode == "exclusive" {
			hostArgs = append(hostArgs, "--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files")
			names := []string{}
			for _, tool := range tools.Bindings {
				names = append(names, tool.Name)
			}
			if len(names) > 0 {
				hostArgs = append(hostArgs, "--tools", strings.Join(names, ","))
			}
		}
	}
	args := append([]string{"--session-dir", directory}, modelArgs...)
	args = append(args, hostArgs...)
	staging := ""
	if sourceFork != nil {
		staging, err = writeTemporary("fork-source-*.jsonl", []byte(sourceFork.JSONL))
		if err != nil {
			return nil, err
		}
		args = append(args, "--session", staging, "--no-extensions")
	} else if sourceFile != "" {
		args = append(args, "--session", sourceFile)
	}
	rpc, err := StartSession(life, ProcessOptions{ExecutablePath: executable, Cwd: cwd, Env: env, Args: args, Bridge: bridge})
	if err != nil {
		return nil, err
	}
	success := false
	defer func() {
		if !success {
			_ = rpc.Close()
		}
	}()
	if staging != "" {
		if err = rpc.Clone(ctx); err != nil {
			return nil, err
		}
	}
	native, err := rpc.State(ctx)
	if err != nil {
		return nil, err
	}
	if err = assertRuntimeSettings(ctx, rpc, settings, h.open.RequireExplicitSettings); err != nil {
		return nil, err
	}
	if native.SessionFile == "" || native.SessionFile == staging {
		return nil, errors.New("Pi did not allocate independent persistent session")
	}
	h.mu.Lock()
	h.state.SessionFile = native.SessionFile
	h.state.ForkSource = nil
	err = h.commitLocked()
	h.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if staging != "" {
		_ = rpc.Close()
		args = append([]string{"--session-dir", directory, "--session", native.SessionFile}, modelArgs...)
		args = append(args, hostArgs...)
		rpc, err = StartSession(life, ProcessOptions{ExecutablePath: executable, Cwd: cwd, Env: env, Args: args, Bridge: bridge})
		if err != nil {
			return nil, err
		}
		if err = assertRuntimeSettings(ctx, rpc, settings, h.open.RequireExplicitSettings); err != nil {
			return nil, err
		}
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	h.mu.Lock()
	h.rpc = rpc
	h.connectionConfig = config
	h.mu.Unlock()
	rpc.Subscribe(func(event Event) {
		h.mu.Lock()
		if h.rpc != rpc || h.closed || h.closing {
			h.mu.Unlock()
			return
		}
		eventErr := h.reduceLocked(event)
		h.mu.Unlock()
		if eventErr != nil {
			go h.failSession(rpc, eventErr)
		}
	})
	rpc.OnFailure(func(err error) { go h.failSession(rpc, err) })
	success = true
	accepted = true
	return rpc, nil
}
func prepareInput(ctx context.Context, request plugin.SendRequest) (PromptInput, string, error) {
	pieces, visible, references := []string{}, []string{}, []string{}
	images := []Image{}
	var annotations []struct {
		ScreenshotID string `json:"screenshotId"`
	}
	if len(request.Input.Annotations) > 0 {
		if err := json.Unmarshal(request.Input.Annotations, &annotations); err != nil {
			return PromptInput{}, "", err
		}
	}
	for _, part := range request.Input.Parts {
		if err := ctx.Err(); err != nil {
			return PromptInput{}, "", err
		}
		switch part.Kind {
		case "text":
			pieces = append(pieces, part.Text)
			if part.AnnotationID == "" {
				visible = append(visible, part.Text)
			}
		case "local-file":
			if part.File == nil {
				return PromptInput{}, "", errors.New("Pi file input missing metadata")
			}
			pieces = append(pieces, "Attached file: "+part.File.Path)
		case "mention", "skill":
			pieces = append(pieces, part.Kind+": "+part.Name+"\n"+part.Path)
		case "image":
			if part.File == nil {
				return PromptInput{}, "", errors.New("Pi image input missing metadata")
			}
			data, err := os.ReadFile(part.File.Path)
			if err != nil {
				return PromptInput{}, "", err
			}
			images = append(images, Image{Type: "image", MimeType: part.File.MimeType, Data: base64.StdEncoding.EncodeToString(data)})
			screenshot := false
			for _, annotation := range annotations {
				if annotation.ScreenshotID == part.File.ID {
					screenshot = true
				}
			}
			if !screenshot {
				references = append(references, "Attached image: "+part.File.Path)
			}
		default:
			return PromptInput{}, "", fmt.Errorf("Pi does not support %s inputs; attach a local image or file", part.Kind)
		}
	}
	contextPieces := []string{}
	for _, entry := range request.ContextEntries {
		contextPieces = append(contextPieces, entry.Content)
	}
	message := strings.Join(append(contextPieces, pieces...), "\n\n")
	if strings.HasPrefix(strings.TrimSpace(message), "/") {
		return PromptInput{}, "", errors.New("Pi slash commands unsupported in Threads; send a natural-language task")
	}
	if len(request.Input.Annotations) == 0 {
		visible = pieces
	}
	return PromptInput{Message: message, Images: images}, strings.Join(append(visible, references...), "\n\n"), ctx.Err()
}
func (h *threadHandle) Send(ctx context.Context, request plugin.SendRequest) error {
	h.sendMu.Lock()
	defer h.sendMu.Unlock()
	if request.ExecutionID == "" {
		return errors.New("Pi send requires execution identity")
	}
	input, visible, err := prepareInput(ctx, request)
	if err != nil {
		return err
	}
	if err = h.ctx.Err(); err != nil {
		return err
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return errors.New("Pi Thread disposed")
	}
	current := activeExecution(&h.state)
	if current != nil && current.ExecutionID != request.ExecutionID {
		h.mu.Unlock()
		return errors.New("Pi already has active Execution")
	}
	steering := current != nil
	backup, _ := json.Marshal(h.state)
	echo := &userEcho{ID: newID("pi-"), ExecutionID: request.ExecutionID, Text: input.Message}
	if !steering {
		h.assistantID = ""
		h.readSnapshot = h.state.NativeSessionJSONL
		if h.state.ForkSource != nil {
			h.readSnapshot = h.state.ForkSource.JSONL
		}
		h.state.NativeSessionJSONL = ""
		id := request.ExecutionID
		h.state.LatestExecutionID = &id
		h.state.Executions = append(h.state.Executions, model.PublicExecution{ExecutionID: id, StartedAt: time.Now().UnixMilli(), Status: "running"})
		if h.state.ExecutionAuthors == nil {
			h.state.ExecutionAuthors = map[string]json.RawMessage{}
		}
		settings, _ := normalizeThread(h.open.ReadThread().Settings)
		authorValue := model.Object{}
		if label := strings.Trim(strings.Join([]string{settings.Provider, settings.Model}, "/"), "/"); label != "" {
			authorValue["model"] = label
		}
		if effort := authorEffort(settings); effort != "" {
			authorValue["effort"] = effort
		}
		author, _ := json.Marshal(authorValue)
		h.state.ExecutionAuthors[id] = author
	}
	h.state.Messages = append(h.state.Messages, MessageState{ID: echo.ID, ExecutionID: request.ExecutionID, Role: "user", Text: visible, Annotations: append(json.RawMessage(nil), request.Input.Annotations...)})
	if err = h.commitLocked(); err != nil {
		_ = json.Unmarshal(backup, &h.state)
		h.mu.Unlock()
		return err
	}
	h.echoes = append(h.echoes, echo)
	h.mu.Unlock()
	// Cancellation governs acceptance only; callers often release their scope on ack.
	var acceptanceMu sync.Mutex
	acceptanceDone := false
	stopAcceptance := func() { acceptanceMu.Lock(); acceptanceDone = true; acceptanceMu.Unlock() }
	stopWatch := context.AfterFunc(ctx, func() {
		acceptanceMu.Lock()
		if acceptanceDone || steering {
			acceptanceMu.Unlock()
			return
		}
		acceptanceDone = true
		acceptanceMu.Unlock()
		_ = h.stop("interrupted", "")
	})
	defer stopWatch()
	defer stopAcceptance()
	var rpc *Session
	if err = ctx.Err(); err == nil && request.Admitted != nil {
		err = request.Admitted()
	}
	if err == nil {
		rpc, err = h.ensureConnection(ctx, steering)
	}
	if err == nil && len(input.Images) > 0 {
		native, stateErr := rpc.State(ctx)
		if stateErr != nil {
			err = stateErr
		} else if native.Model == nil || !slices.Contains(native.Model.Input, "image") {
			err = errors.New("当前 Pi 模型不支持图片或未声明图片能力。请更换模型，或选择仅发送文字。")
		}
	}
	if err == nil {
		settings, settingsErr := normalizeThread(h.open.ReadThread().Settings)
		if settingsErr != nil {
			err = settingsErr
		} else {
			err = assertRuntimeSettings(ctx, rpc, settings, h.open.RequireExplicitSettings)
		}
	}
	if err == nil {
		input.Steer = steering
		err = rpc.Prompt(ctx, input)
		if err == nil {
			stopAcceptance()
			stopWatch()
		}
	}
	if err != nil {
		if !steering {
			status := "failed"
			if ctx.Err() != nil {
				status = "interrupted"
			}
			_ = h.stop(status, err.Error())
		} else {
			if rpc != nil {
				fence, cancel := context.WithTimeout(context.WithoutCancel(h.ctx), 30*time.Second)
				fenceErr := rpc.FlushEvents(fence)
				cancel()
				err = errors.Join(err, fenceErr)
			}
			h.mu.Lock()
			if !echo.Echoed {
				h.state.Messages = slices.DeleteFunc(h.state.Messages, func(row MessageState) bool { return row.ID == echo.ID })
				h.echoes = slices.DeleteFunc(h.echoes, func(row *userEcho) bool { return row == echo })
				commitErr := h.commitLocked()
				err = errors.Join(err, commitErr)
			}
			h.mu.Unlock()
		}
	}
	return err
}
func (h *threadHandle) advanceForegroundLocked(executionID string, next model.HarnessActivity, continues ...bool) {
	newSegment := next.Kind == "reasoning" && len(continues) > 0 && !continues[0]
	index := -1
	for i, f := range h.state.Foregrounds {
		if f.ExecutionID == executionID {
			index = i
			break
		}
	}
	previous := model.HarnessActivity{}
	if index >= 0 {
		previous = h.state.Foregrounds[index].Foreground
	}
	next.Sequence = previous.Sequence
	if newSegment || next.Kind != previous.Kind || next.CallID != previous.CallID {
		next.Sequence++
	}
	if next.Sequence == 0 {
		next.Sequence = 1
	}
	if !newSegment && next.Kind == "reasoning" && previous.Kind == "reasoning" {
		next.Text = previous.Text + next.Text
		next.TextOffset = previous.TextOffset
	}
	runes := []rune(next.Text)
	if len(runes) > 32768 {
		next.TextOffset += utf16Length(string(runes[:len(runes)-32768]))
		next.Text = string(runes[len(runes)-32768:])
	}
	entry := ForegroundState{ExecutionID: executionID, Foreground: next}
	if index < 0 {
		h.state.Foregrounds = append(h.state.Foregrounds, entry)
	} else {
		h.state.Foregrounds[index] = entry
	}
	if h.open.PublishActivity != nil {
		next.ExecutionID = executionID
		h.open.PublishActivity(next)
	}
}
func suffix(next, previous string) string {
	if next == previous {
		return ""
	}
	return strings.TrimPrefix(next, previous)
}
func (h *threadHandle) reduceLocked(event Event) error {
	execution := activeExecution(&h.state)
	if execution == nil {
		if event.Type == "started" || event.Type == "interaction" || event.Type == "notification" || event.Type == "user" || event.Type == "assistant" && event.Phase == "start" {
			return errors.New("Pi initiated work outside admitted Execution")
		}
		return nil
	}
	id := execution.ExecutionID
	switch event.Type {
	case "assistant":
		if event.Phase == "start" || h.assistantID == "" {
			h.assistantID = newID("pi-")
		}
		index := -1
		for i, row := range h.state.Messages {
			if row.ID == h.assistantID {
				index = i
				break
			}
		}
		previous := MessageState{}
		if index >= 0 {
			previous = h.state.Messages[index]
		}
		status := "streaming"
		if event.Phase == "end" {
			status = "complete"
			if event.StopReason == "error" {
				status = "failed"
			}
			if event.StopReason == "aborted" {
				status = "cancelled"
			}
		}
		row := MessageState{ID: h.assistantID, ExecutionID: id, Role: "assistant", Text: event.Text, Thinking: event.Thinking, Status: status, Model: event.Model, Provider: event.Provider, Usage: event.Usage}
		if index < 0 {
			h.state.Messages = append(h.state.Messages, row)
		} else {
			h.state.Messages[index] = row
		}
		if delta := strings.ReplaceAll(suffix(row.Thinking, previous.Thinking), "\x00", ""); delta != "" {
			h.advanceForegroundLocked(id, model.HarnessActivity{Kind: "reasoning", Text: delta}, index >= 0)
		}
		if suffix(row.Text, previous.Text) != "" && event.Phase != "end" {
			h.advanceForegroundLocked(id, model.HarnessActivity{Kind: "assistant-text"})
		}
		if strings.TrimSpace(row.Text) != "" {
			summary := clean(row.Text, 100000)
			execution.Summary = &summary
		}
		if event.Phase == "end" {
			h.assistantID = ""
		}
		if event.Phase == "update" {
			h.scheduleCommitLocked()
			return nil
		}
	case "user":
		matched := false
		for i, echo := range h.echoes {
			if echo.ExecutionID == id && echo.Text == event.Text {
				echo.Echoed = true
				h.echoes = append(h.echoes[:i], h.echoes[i+1:]...)
				matched = true
				break
			}
		}
		if !matched {
			h.state.Messages = append(h.state.Messages, MessageState{ID: newID("pi-"), ExecutionID: id, Role: "user", Text: event.Text})
		}
	case "tool":
		rowID := "tool:" + event.CallID
		index := -1
		for i, row := range h.state.Messages {
			if row.ID == rowID {
				index = i
				break
			}
		}
		row := MessageState{ID: rowID, ExecutionID: id, Role: "tool", ToolName: event.Name, ToolCallID: clean(event.CallID, 1024), Text: event.Text, IsError: event.IsError, Todos: event.Todos}
		if index < 0 {
			h.state.Messages = append(h.state.Messages, row)
		} else {
			h.state.Messages[index] = row
		}
		if event.Phase == "start" && index < 0 && row.ToolCallID != "" && strings.TrimSpace(event.Name) != "" {
			h.advanceForegroundLocked(id, model.HarnessActivity{Kind: "tool-call", CallID: row.ToolCallID, ToolName: clean(strings.TrimSpace(event.Name), 64)})
		}
		if event.Phase == "update" {
			h.scheduleCommitLocked()
			return nil
		}
	case "interaction":
		return h.interactionLocked(event, execution)
	case "notification":
		h.state.Messages = append(h.state.Messages, MessageState{ID: newID("pi-"), ExecutionID: id, Role: "tool", ToolName: "Pi " + event.Method, Text: clean(event.Text, 100000)})
	case "extension-error":
		return fmt.Errorf("Pi extension failed: %s", event.Error)
	case "settled":
		if len(h.interactions) > 0 {
			return errors.New("Pi settled with unresolved user interactions")
		}
		if h.state.SessionFile != "" {
			data, err := os.ReadFile(h.state.SessionFile)
			if err == nil {
				h.state.NativeSessionJSONL = string(data)
			} else if !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
		if event.Completion == nil {
			return errors.New("Pi settlement missing completion")
		}
		return h.finishLocked(event.Completion.Status, event.Completion.Error)
	default:
		return nil
	}
	return h.commitLocked()
}
func (h *threadHandle) interactionLocked(event Event, current *model.PublicExecution) error {
	options := []string{}
	seen := map[string]bool{}
	nativeOptions := map[string]string{}
	for index, native := range event.Options {
		if native == "" {
			continue
		}
		public := clean(native, 2000)
		if strings.TrimSpace(public) == "" || seen[public] {
			public = fmt.Sprintf("pi-option-%d", index)
			for seen[public] {
				public += "-"
			}
		}
		seen[public] = true
		options = append(options, public)
		nativeOptions[public] = native
	}
	if event.Method == "select" && len(options) == 0 {
		return errors.New("Pi select has no choices")
	}
	if event.ID == "" {
		return errors.New("Pi interaction missing ID")
	}
	id := newID("pi-ui-")
	interaction := model.PublicInteraction{ID: id, Kind: "question", Title: clean(event.Title, 2000), Actions: []model.PublicInteractionAction{}, Questions: []model.PublicInteractionQuestion{}}
	if interaction.Title == "" {
		interaction.Title = "Pi request"
	}
	if event.Message != "" {
		message := clean(event.Message, 20000)
		interaction.Description = &message
	}
	if event.Method == "confirm" {
		interaction.Kind = "permission"
		interaction.Actions = []model.PublicInteractionAction{{ID: "allow", Intent: "allow", Label: "Confirm"}, {ID: "deny", Intent: "deny", Label: "Decline"}}
	} else {
		interaction.Actions = []model.PublicInteractionAction{{ID: "submit", Intent: "submit", Label: "Submit"}, {ID: "cancel", Intent: "cancel", Label: "Cancel"}}
		question := model.PublicInteractionQuestion{ID: "answer", Prompt: interaction.Title, AllowOther: event.Method != "select", Options: []model.PublicInteractionOption{}}
		if event.Method == "editor" && event.Prefill != nil {
			initial, _ := json.Marshal(*event.Prefill)
			question.Form = &model.PublicQuestionForm{Type: "string", Default: initial}
		}
		for _, value := range options {
			question.Options = append(question.Options, model.PublicInteractionOption{Value: value, Label: clean(value, 2000)})
		}
		interaction.Questions = append(interaction.Questions, question)
	}
	item := pendingInteraction{NativeID: event.ID, Method: event.Method, Options: options, NativeOptions: nativeOptions}
	if event.Timeout != nil {
		item.Timer = time.AfterFunc(time.Duration(min(*event.Timeout, 2147483647))*time.Millisecond, func() { h.fail(errors.New("Pi user request expired; rerun task")) })
	}
	h.interactions[id] = item
	current.Status = "waiting-for-user"
	current.Interactions = append(current.Interactions, interaction)
	return h.commitLocked()
}
func (h *threadHandle) Respond(ctx context.Context, request model.RespondRequest) error {
	h.sendMu.Lock()
	defer h.sendMu.Unlock()
	h.mu.Lock()
	item, ok := h.interactions[request.InteractionID]
	current := activeExecution(&h.state)
	rpc := h.rpc
	if !ok || current == nil || current.Status != "waiting-for-user" || rpc == nil || h.closing || h.closed || request.ExecutionID != "" && current.ExecutionID != request.ExecutionID {
		h.mu.Unlock()
		return errors.New("unknown or expired Pi interaction")
	}
	valid := false
	for _, interaction := range current.Interactions {
		if interaction.ID == request.InteractionID {
			for _, action := range interaction.Actions {
				if action.ID == request.ActionID {
					valid = true
				}
			}
		}
	}
	if !valid {
		h.mu.Unlock()
		return errors.New("invalid Pi response action")
	}
	var answer InteractionAnswer
	if item.Method == "confirm" {
		confirmed := request.ActionID == "allow"
		answer.Confirmed = &confirmed
	} else if request.ActionID == "cancel" {
		answer.Cancelled = true
	} else {
		var value string
		var err error
		if initial, present := request.ValidatedFormValues["answer"]; item.Method == "editor" && present {
			// Core preflight includes an unchanged editor default even when the
			// client omits it from the submitted answer map.
			var ok bool
			value, ok = initial.(string)
			if !ok {
				err = errors.New("missing validated editor value")
			}
		} else {
			err = json.Unmarshal(request.Answers["answer"], &value)
		}
		if err != nil || item.Method == "select" && !slices.Contains(item.Options, value) {
			h.mu.Unlock()
			return errors.New("invalid Pi answer")
		}
		if item.Method == "select" {
			value = item.NativeOptions[value]
		}
		answer.Value = &value
	}
	h.mu.Unlock()
	if err := rpc.Respond(ctx, item.NativeID, answer); err != nil {
		return err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if item.Timer != nil {
		item.Timer.Stop()
	}
	delete(h.interactions, request.InteractionID)
	current = activeExecution(&h.state)
	if current != nil {
		current.Interactions = slices.DeleteFunc(current.Interactions, func(i model.PublicInteraction) bool { return i.ID == request.InteractionID })
		if len(current.Interactions) == 0 {
			current.Status = "running"
		}
		return h.commitLocked()
	}
	return nil
}
func (h *threadHandle) Interrupt(ctx context.Context) error { return h.stop("interrupted", "") }
func (h *threadHandle) Read(ctx context.Context, question string) (string, error) {
	question = strings.TrimSpace(question)
	if question == "" {
		return "", errors.New("Pi read question must not be empty")
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return "", errors.New("Pi Thread disposed")
	}
	if h.open.Injection != nil {
		h.mu.Unlock()
		return "", errors.New("injected Pi Threads cannot be used as conversation read sources")
	}
	snapshot := h.state.NativeSessionJSONL
	if h.state.ForkSource != nil {
		snapshot = h.state.ForkSource.JSONL
	}
	if snapshot == "" {
		snapshot = h.readSnapshot
	}
	h.reads.Add(1)
	h.mu.Unlock()
	defer h.reads.Done()
	if snapshot == "" {
		return "", errors.New("Pi has no saved native history to read")
	}
	life, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(h.ctx, cancel)
	defer stop()
	defer cancel()
	record := h.open.ReadThread()
	cwd := record.Cwd
	if record.Worktree != nil && record.Worktree.Cwd != "" {
		cwd = record.Worktree.Cwd
	}
	settings, err := normalizeThread(record.Settings)
	if err != nil {
		return "", err
	}
	return readThread(life, h.host, cwd, settings, snapshot, question)
}
func (h *threadHandle) CompletedReply(id string) (string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, e := range h.state.Executions {
		if e.ExecutionID == id && e.Status == "completed" {
			text := lastAssistant(h.state, id)
			return text, strings.TrimSpace(text) != ""
		}
	}
	return "", false
}
func (h *threadHandle) Close() error {
	h.mu.Lock()
	if h.closed {
		done := h.closeDone
		h.mu.Unlock()
		<-done
		return h.closeErr
	}
	h.closed = true
	h.mu.Unlock()
	h.cancel()
	h.sendMu.Lock()
	err := h.stop("interrupted", "")
	h.sendMu.Unlock()
	h.reads.Wait()
	h.mu.Lock()
	h.closeErr = err
	close(h.closeDone)
	h.mu.Unlock()
	return err
}

// A retired native connection must not fail the connection that replaced it.
func (h *threadHandle) failSession(session *Session, err error) {
	_ = h.stopSession(session, "failed", err.Error())
}
func authorEffort(settings ThreadSettings) string {
	if settings.Thinking == nil {
		return settings.ThinkingLevel
	}
	if settings.Thinking.Mode == "effort" {
		return settings.Thinking.Effort
	}
	return settings.Thinking.Mode
}
