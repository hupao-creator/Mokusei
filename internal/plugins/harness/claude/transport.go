package claude

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type Settings struct {
	ExecutablePath  string                `json:"executablePath"`
	Model           string                `json:"model,omitempty"`
	Effort          string                `json:"effort,omitempty"`
	Thinking        *model.ThinkingChoice `json:"thinking,omitempty"`
	GoalMode        bool                  `json:"goalMode,omitempty"`
	PermissionMode  string                `json:"permissionMode,omitempty"`
	AllowedTools    []string              `json:"allowedTools,omitempty"`
	DisallowedTools []string              `json:"disallowedTools,omitempty"`
}
type TransportOptions struct {
	Executable, Cwd, SessionID                                                                            string
	Environment                                                                                           map[string]string
	Settings                                                                                              Settings
	Resume, Interactive, PersistSession, ApplicationToolsOnly, FixedExecutionSettings, ReadOnlyDiscussion bool
	SystemPrompt                                                                                          string
	StructuredOutputSchema                                                                                map[string]any
	ForkFromSessionID, ForkAtMessageID                                                                    string
	NativeWorktreeName                                                                                    *string
	ToolBridge                                                                                            *ToolBridge
	OnEvent                                                                                               func(NativeEvent)
}
type NativeEvent struct {
	ExecutionID    string
	Frame          map[string]any
	Outcome, Error string
	NativeStart    bool
	Prompt         string
}
type controlResult struct {
	value any
	err   error
}
type nativeBoundary struct {
	id              string
	admitted, ended bool
}
type nativeExecution struct {
	id                             string
	boundaries                     []*nativeBoundary
	cancelled, synthetic           bool
	deferredOutcome, deferredError string
}

// Transport owns one retained Claude CLI. Its read loop always drains control
// replies independently of serialized event delivery, so state callbacks may
// issue native controls without deadlocking the stream.
type Transport struct {
	options            TransportOptions
	mu                 sync.Mutex
	writeGate          chan struct{}
	startMu            sync.Mutex
	cmd                *exec.Cmd
	groups             []int
	stdin              io.WriteCloser
	done               chan struct{}
	controls           map[string]chan controlResult
	interactions       map[string]map[string]any
	active             *nativeExecution
	lastExecution      string
	directories        map[string]bool
	initialization     any
	initialized        bool
	disposed, stopping bool
	stderr             string
	eventMu            sync.RWMutex
	eventsClosed       bool
	events             chan NativeEvent
	eventsDone         chan struct{}
	closeOnce          sync.Once
	closeError         error
}

func newID() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}
func NewTransport(options TransportOptions) *Transport {
	t := &Transport{options: options, writeGate: make(chan struct{}, 1), controls: map[string]chan controlResult{}, interactions: map[string]map[string]any{}, directories: map[string]bool{}, events: make(chan NativeEvent, 256), eventsDone: make(chan struct{})}
	go func() {
		defer close(t.eventsDone)
		for event := range t.events {
			if t.options.OnEvent != nil {
				t.options.OnEvent(event)
			}
		}
	}()
	return t
}
func (t *Transport) emit(e NativeEvent) {
	t.eventMu.RLock()
	defer t.eventMu.RUnlock()
	if !t.eventsClosed {
		t.events <- e
	}
}
func (t *Transport) Initialize(ctx context.Context) (any, error) {
	t.startMu.Lock()
	defer t.startMu.Unlock()
	t.mu.Lock()
	if t.disposed {
		t.mu.Unlock()
		return nil, errors.New("Claude transport closed")
	}
	if t.initialized {
		r := t.initialization
		t.mu.Unlock()
		return r, nil
	}
	t.mu.Unlock()
	if err := t.spawn(); err != nil {
		return nil, err
	}
	request := map[string]any{"subtype": "initialize", "agentProgressSummaries": true, "forwardSubagentText": true, "supportedDialogKinds": []string{}}
	if t.options.Interactive {
		request["supportedDialogKinds"] = []string{"refusal_fallback_prompt"}
	}
	if t.options.SystemPrompt != "" {
		request["systemPrompt"] = t.options.SystemPrompt
	}
	if t.options.StructuredOutputSchema != nil {
		request["jsonSchema"] = t.options.StructuredOutputSchema
	}
	initCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	value, err := t.controlTimeout(initCtx, request, 45*time.Second)
	if err != nil {
		t.stopProcess()
		return nil, err
	}
	t.mu.Lock()
	t.initialized = true
	t.initialization = value
	t.options.Resume = true
	t.mu.Unlock()
	return value, nil
}
func (t *Transport) spawn() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.disposed {
		return errors.New("Claude transport closed")
	}
	if t.cmd != nil {
		return nil
	}
	env := map[string]string{}
	for k, v := range t.options.Environment {
		env[k] = v
	}
	overlay := map[string]string{}
	if t.options.Settings.Effort != "" || t.options.Settings.Thinking != nil && t.options.Settings.Thinking.Mode == "effort" {
		// Explicit effort is authoritative for this native session, including
		// effort-only execution snapshots that have no thinking object.
		overlay["CLAUDE_CODE_EFFORT_LEVEL"] = ""
	}
	for k, v := range overlay {
		env[k] = v
	}
	env = systemProxy(env)
	env["CLAUDE_CODE_ENTRYPOINT"] = "mokusei-desktop"
	args, err := buildArguments(t.options, t.directories, env, overlay)
	if err != nil {
		return err
	}
	cmd := exec.Command(t.options.Executable, args...)
	cmd.Dir = t.options.Cwd
	cmd.Env = environmentList(env)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, outWriter, err := os.Pipe()
	if err != nil {
		in.Close()
		return err
	}
	stderr, stderrWriter, err := os.Pipe()
	if err != nil {
		in.Close()
		out.Close()
		outWriter.Close()
		return err
	}
	cmd.Stdout = outWriter
	cmd.Stderr = stderrWriter
	if err = cmd.Start(); err != nil {
		in.Close()
		out.Close()
		outWriter.Close()
		stderr.Close()
		stderrWriter.Close()
		return err
	}
	outWriter.Close()
	stderrWriter.Close()
	t.groups = append(t.groups, cmd.Process.Pid)
	t.cmd = cmd
	t.stdin = in
	t.done = make(chan struct{})
	t.stopping = false
	stdoutDone := make(chan struct{})
	stderrDone := make(chan struct{})
	go func() {
		defer close(stdoutDone)
		defer out.Close()
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 64*1024), 32*1024*1024)
		for scanner.Scan() {
			var frame map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &frame); err != nil {
				t.appendStderr(scanner.Text())
				continue
			}
			t.handleFrame(frame)
		}
		if err := scanner.Err(); err != nil {
			t.appendStderr(err.Error())
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
	}()
	go func() {
		defer close(stderrDone)
		defer stderr.Close()
		buffer := make([]byte, 8192)
		for {
			n, err := stderr.Read(buffer)
			if n > 0 {
				t.appendStderr(string(buffer[:n]))
			}
			if err != nil {
				return
			}
		}
	}()
	done := t.done
	go func() {
		err := cmd.Wait()
		// Root exit terminates all owned descendants, including background
		// tools retaining stdout/stderr. Parent-owned pipes drain before the
		// terminal event; cmd.Wait never truncates them.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		drained := make(chan struct{})
		go func() { <-stdoutDone; <-stderrDone; close(drained) }()
		select {
		case <-drained:
		case <-time.After(2 * time.Second):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			select {
			case <-drained:
			case <-time.After(2 * time.Second):
				out.Close()
				stderr.Close()
				<-drained
			}
		}
		t.mu.Lock()
		if t.cmd == cmd {
			t.cmd = nil
			t.stdin = nil
			t.initialized = false
		}
		stopping := t.stopping || t.disposed
		message := strings.TrimSpace(t.stderr)
		if message == "" {
			message = fmt.Sprintf("Claude process exited: %v", err)
		}
		active := t.active
		if !stopping {
			t.active = nil
		}
		for id, ch := range t.controls {
			delete(t.controls, id)
			ch <- controlResult{err: errors.New(message)}
		}
		t.mu.Unlock()
		if !stopping {
			if active != nil {
				t.emit(NativeEvent{ExecutionID: active.id, Outcome: "failed", Error: message})
			}
			t.emit(NativeEvent{Frame: map[string]any{"type": "process-exit"}})
		}
		close(done)
	}()
	return nil
}
func (t *Transport) appendStderr(s string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.stderr += s
	if len(t.stderr) > 16000 {
		t.stderr = t.stderr[len(t.stderr)-16000:]
	}
}
func environmentList(env map[string]string) []string {
	out := make([]string, 0, len(env))
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}
func buildArguments(o TransportOptions, directories map[string]bool, env, overlay map[string]string) ([]string, error) {
	s := o.Settings
	args := []string{"--print", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose", "--include-partial-messages", "--include-hook-events", "--forward-subagent-text", "--replay-user-messages", "--permission-prompt-tool", "stdio"}
	if o.ForkFromSessionID != "" {
		args = append(args, "--resume="+o.ForkFromSessionID, "--fork-session", "--session-id="+o.SessionID)
		if o.ForkAtMessageID != "" {
			args = append(args, "--resume-session-at="+o.ForkAtMessageID)
		}
	} else if o.Resume {
		args = append(args, "--resume="+o.SessionID)
	} else {
		args = append(args, "--session-id="+o.SessionID)
	}
	if !o.PersistSession {
		args = append(args, "--no-session-persistence")
	}
	if o.SystemPrompt != "" {
		args = append(args, "--system-prompt-snapshot", "off")
	}
	if s.Model != "" {
		args = append(args, "--model", s.Model)
	}
	if s.Effort != "" {
		args = append(args, "--effort", s.Effort)
	}
	if s.Thinking != nil {
		if s.Thinking.Mode == "effort" {
			if disabled(env["CLAUDE_CODE_DISABLE_THINKING"]) {
				return nil, errors.New("CLAUDE_CODE_DISABLE_THINKING conflicts with explicit thinking")
			}
			args = append(args, "--thinking", "adaptive")
		} else if s.Thinking.Mode != "fixed" {
			return nil, errors.New("Claude cannot encode requested thinking mode")
		}
	}
	mode := s.PermissionMode
	if mode == "" {
		mode = "auto"
	}
	args = append(args, "--permission-mode", mode)
	if mode == "bypassPermissions" {
		args = append(args, "--allow-dangerously-skip-permissions")
	}
	if o.ApplicationToolsOnly {
		args = append(args, "--tools", "", "--disable-slash-commands", "--strict-mcp-config")
		if bareAuthentication(env) {
			args = append(args, "--bare")
		}
	}
	if o.ReadOnlyDiscussion {
		if !o.ApplicationToolsOnly || o.PersistSession || o.ForkFromSessionID == "" || mode != "dontAsk" {
			return nil, errors.New("read-only discussion requires temporary restricted fork")
		}
		args = append(args, "--restricted")
	}
	if len(s.AllowedTools) > 0 {
		args = append(args, "--allowedTools", strings.Join(s.AllowedTools, ","))
	}
	if len(s.DisallowedTools) > 0 {
		args = append(args, "--disallowedTools", strings.Join(s.DisallowedTools, ","))
	}
	if o.ToolBridge != nil {
		b, _ := json.Marshal(o.ToolBridge.Configuration())
		args = append(args, "--mcp-config", string(b))
	}
	native := map[string]any{}
	sessionEnv := proxySettings(env)
	for k, v := range overlay {
		sessionEnv[k] = v
	}
	if len(sessionEnv) > 0 {
		native["env"] = sessionEnv
	}
	if o.ReadOnlyDiscussion {
		native["disableAllHooks"] = true
		native["autoMemoryEnabled"] = false
	}
	if o.NativeWorktreeName != nil && !o.Resume {
		native["worktree"] = map[string]any{"baseRef": "head"}
	}
	if len(native) > 0 {
		b, _ := json.Marshal(native)
		args = append(args, "--settings", string(b))
	}
	if o.NativeWorktreeName != nil && !o.Resume {
		args = append(args, "--worktree")
		if *o.NativeWorktreeName != "" {
			args = append(args, *o.NativeWorktreeName)
		}
	}
	scopes := make([]string, 0, len(directories))
	for d := range directories {
		scopes = append(scopes, d)
	}
	sort.Strings(scopes)
	for _, d := range scopes {
		args = append(args, "--add-dir", d)
	}
	return args, nil
}
func disabled(s string) bool { return s != "" && strings.ToLower(s) != "false" && s != "0" }
func (t *Transport) Control(ctx context.Context, request map[string]any) (any, error) {
	return t.controlTimeout(ctx, request, 20*time.Second)
}
func (t *Transport) controlTimeout(ctx context.Context, request map[string]any, timeout time.Duration) (any, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	id := newID()
	ch := make(chan controlResult, 1)
	t.mu.Lock()
	if t.disposed {
		t.mu.Unlock()
		return nil, errors.New("Claude transport closed")
	}
	t.controls[id] = ch
	t.mu.Unlock()
	defer func() { t.mu.Lock(); delete(t.controls, id); t.mu.Unlock() }()
	if err := t.writeContext(ctx, map[string]any{"type": "control_request", "request_id": id, "request": request}); err != nil {
		return nil, err
	}
	select {
	case <-ctx.Done():
		return nil, fmt.Errorf("Claude control %s: %w", str(request["subtype"]), ctx.Err())
	case result := <-ch:
		return result.value, result.err
	}
}
func (t *Transport) write(frame any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return t.writeContext(ctx, frame)
}
func (t *Transport) writeContext(ctx context.Context, frame any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	data, err := json.Marshal(frame)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	select {
	case t.writeGate <- struct{}{}:
		defer func() { <-t.writeGate }()
	case <-ctx.Done():
		return ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	t.mu.Lock()
	stdin := t.stdin
	cmd := t.cmd
	t.mu.Unlock()
	if stdin == nil {
		return errors.New("Claude process is not running")
	}
	// Native stdin is an os.Pipe. A write deadline interrupts backpressure
	// without closing a pipe whose full frame completed alongside cancellation.
	deadline, supportsDeadline := stdin.(interface{ SetWriteDeadline(time.Time) error })
	cancelled := make(chan struct{})
	closedOnCancel := false
	stop := context.AfterFunc(ctx, func() {
		if !supportsDeadline || deadline.SetWriteDeadline(time.Now()) != nil {
			closedOnCancel = true
			_ = stdin.Close()
		}
		close(cancelled)
	})
	written, err := stdin.Write(data)
	if !stop() {
		<-cancelled
		if closedOnCancel || written != len(data) || err != nil {
			err = ctx.Err()
		} else {
			err = deadline.SetWriteDeadline(time.Time{})
		}
	}
	if err == nil && written != len(data) {
		err = io.ErrShortWrite
	}
	if err != nil {
		t.mu.Lock()
		if t.stdin == stdin {
			t.stdin = nil
		}
		t.mu.Unlock()
		_ = stdin.Close()
		if cmd != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
	}
	return err
}
func (t *Transport) Send(ctx context.Context, executionID string, input model.AgentInput, priority string) (string, error) {
	return t.SendWithAdmission(ctx, executionID, input, priority, nil)
}

// SendWithAdmission reserves the native result boundary before durable admission.
// A preceding result cannot complete a queued follow-up while its host commit runs.
func (t *Transport) SendWithAdmission(ctx context.Context, executionID string, input model.AgentInput, priority string, beforeWrite func(string) error) (string, error) {
	if executionID == "" {
		return "", errors.New("empty Claude execution ID")
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	t.mu.Lock()
	if t.active != nil && (t.active.id != executionID || t.active.cancelled || t.active.synthetic) {
		t.mu.Unlock()
		return "", errors.New("Claude execution cannot accept input")
	}
	if t.active == nil && priority == "next" {
		t.mu.Unlock()
		return "", errors.New("Claude execution ended before follow-up admission")
	}
	if t.active == nil {
		t.active = &nativeExecution{id: executionID}
	}
	started := t.cmd != nil
	scopes := inputDirectories(input, t.options.Cwd)
	for d := range t.directories {
		scopes[d] = true
	}
	if !started {
		t.directories = scopes
	}
	t.mu.Unlock()
	if _, err := t.Initialize(ctx); err != nil {
		return "", err
	}
	if started {
		t.mu.Lock()
		changed := len(scopes) != len(t.directories)
		t.mu.Unlock()
		if changed {
			dirs := make([]string, 0, len(scopes))
			for d := range scopes {
				dirs = append(dirs, d)
			}
			sort.Strings(dirs)
			if _, err := t.Control(ctx, map[string]any{"subtype": "apply_flag_settings", "settings": map[string]any{"permissions": map[string]any{"additionalDirectories": dirs}}}); err != nil {
				return "", err
			}
			t.mu.Lock()
			t.directories = scopes
			t.mu.Unlock()
		}
	}
	if t.options.FixedExecutionSettings || t.options.Settings.Effort != "" || t.options.Settings.Thinking != nil && t.options.Settings.Thinking.Mode == "effort" {
		current, err := t.Control(ctx, map[string]any{"subtype": "get_settings"})
		if err != nil {
			return "", err
		}
		if err = assertApplied(current, t.options.Settings, t.options.Environment, t.options.FixedExecutionSettings); err != nil {
			return "", err
		}
	}
	content, err := inputContent(ctx, input)
	if err != nil {
		return "", err
	}
	id := newID()
	boundary := &nativeBoundary{id: id}
	t.mu.Lock()
	if t.active == nil || t.active.id != executionID || t.active.cancelled {
		t.mu.Unlock()
		return "", errors.New("Claude execution ended before admission")
	}
	active := t.active
	active.boundaries = append(active.boundaries, boundary)
	t.mu.Unlock()
	if priority == "" {
		priority = "now"
	}
	if beforeWrite != nil {
		err = beforeWrite(id)
	}
	if err == nil {
		err = t.writeContext(ctx, map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": content}, "parent_tool_use_id": nil, "session_id": t.options.SessionID, "uuid": id, "priority": priority, "origin": map[string]any{"kind": "human"}})
	}
	if err != nil {
		t.mu.Lock()
		for i, b := range active.boundaries {
			if b == boundary {
				active.boundaries = append(active.boundaries[:i], active.boundaries[i+1:]...)
				break
			}
		}
		t.mu.Unlock()
		return "", err
	}
	return id, nil
}
func assertApplied(value any, s Settings, env map[string]string, fixed bool) error {
	current := obj(value)
	applied := obj(current["applied"])
	if applied == nil {
		return errors.New("Claude did not report applied execution settings; upgrade the native client")
	}
	effective := map[string]string{}
	for k, v := range env {
		effective[k] = v
	}
	for k, v := range obj(obj(current["effective"])["env"]) {
		if x, ok := v.(string); ok {
			effective[k] = x
		}
	}
	if s.Effort != "" {
		if disabled(effective["CLAUDE_CODE_DISABLE_THINKING"]) {
			return errors.New("Claude effective environment disables explicitly selected thinking")
		}
		if raw := effective["CLAUDE_CODE_EXTRA_BODY"]; raw != "" {
			var body map[string]any
			if err := json.Unmarshal([]byte(raw), &body); err != nil {
				return errors.New("invalid CLAUDE_CODE_EXTRA_BODY")
			}
			if _, ok := body["thinking"]; ok {
				return errors.New("Claude EXTRA_BODY overrides thinking")
			}
			if effort, ok := obj(body["output_config"])["effort"]; ok && effort != s.Effort {
				return errors.New("Claude EXTRA_BODY overrides effort")
			}
		}
		if str(applied["effort"]) != s.Effort {
			return errors.New("Claude did not apply selected effort")
		}
	} else if fixed && applied["effort"] != nil {
		return errors.New("Claude applied unexpected effort to fixed model")
	}
	if fixed && str(applied["model"]) != s.Model {
		return errors.New("Claude did not apply selected fixed model")
	}
	return nil
}
func inputDirectories(in model.AgentInput, cwd string) map[string]bool {
	out := map[string]bool{}
	for _, p := range in.Parts {
		path := ""
		if p.File != nil {
			path = filepath.Dir(p.File.Path)
		} else if p.Kind == "mention" || p.Kind == "skill" {
			path = p.Path
			if p.PathType != "directory" || p.Kind == "skill" {
				path = filepath.Dir(path)
			}
		}
		if path != "" && path != "." && path != cwd {
			out[path] = true
		}
	}
	return out
}
func inputContent(ctx context.Context, in model.AgentInput) (any, error) {
	blocks := []any{}
	for _, p := range in.Parts {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		switch p.Kind {
		case "text":
			if p.Text != "" {
				blocks = append(blocks, map[string]any{"type": "text", "text": p.Text})
			}
		case "image", "local-file", "audio":
			if p.File == nil {
				return nil, errors.New("Claude attachment missing resolved file")
			}
			f := p.File
			if p.Kind == "image" && contains([]string{"image/jpeg", "image/png", "image/gif", "image/webp"}, f.MimeType) || p.Kind == "local-file" && f.MimeType == "application/pdf" {
				stat, err := os.Stat(f.Path)
				if err != nil {
					return nil, err
				}
				if stat.Size() > 64*1024*1024 {
					return nil, errors.New("Claude attachment exceeds 64 MiB")
				}
				data, err := os.ReadFile(f.Path)
				if err != nil {
					return nil, err
				}
				kind := "image"
				if f.MimeType == "application/pdf" {
					kind = "document"
				}
				block := map[string]any{"type": kind, "source": map[string]any{"type": "base64", "media_type": f.MimeType, "data": base64.StdEncoding.EncodeToString(data)}}
				if kind == "document" {
					block["title"] = f.Name
				}
				blocks = append(blocks, block)
			} else {
				blocks = append(blocks, map[string]any{"type": "text", "text": fmt.Sprintf("[Attached %s: %s\nPath: %s]", p.Kind, f.Name, f.Path)})
			}
		case "image-url", "audio-url":
			blocks = append(blocks, map[string]any{"type": "text", "text": fmt.Sprintf("[%s: %s]", p.Kind, p.URL)})
		case "mention", "skill":
			blocks = append(blocks, map[string]any{"type": "text", "text": fmt.Sprintf("[%s: %s\nPath: %s]", p.Kind, p.Name, p.Path)})
		default:
			return nil, fmt.Errorf("unsupported Claude input part %q", p.Kind)
		}
	}
	if len(blocks) == 0 {
		return "", nil
	}
	if len(blocks) == 1 && str(obj(blocks[0])["type"]) == "text" {
		return obj(blocks[0])["text"], nil
	}
	return blocks, nil
}
func (t *Transport) handleFrame(frame map[string]any) {
	typ := str(frame["type"])
	if (typ == "result" || typ == "system" && str(frame["subtype"]) == "init") && str(frame["session_id"]) != "" && str(frame["session_id"]) != t.options.SessionID {
		err := errors.New("Claude returned a different primary native session ID; binding replacement was rejected")
		t.mu.Lock()
		active := t.active
		t.active = nil
		for id, ch := range t.controls {
			delete(t.controls, id)
			ch <- controlResult{err: err}
		}
		t.mu.Unlock()
		if active != nil {
			t.emit(NativeEvent{ExecutionID: active.id, Outcome: "failed", Error: err.Error()})
		}
		t.emit(NativeEvent{Frame: map[string]any{"type": "process-exit"}})
		go t.stopProcess()
		return
	}
	if typ == "control_response" {
		response := obj(frame["response"])
		id := str(response["request_id"])
		t.mu.Lock()
		ch := t.controls[id]
		delete(t.controls, id)
		t.mu.Unlock()
		if ch != nil {
			result := controlResult{value: response["response"]}
			if str(response["subtype"]) != "success" {
				result.err = errors.New(nonempty(str(response["error"]), "Claude control failed"))
			}
			ch <- result
		}
		for _, key := range []string{"pending_permission_requests", "pending_user_dialog_requests"} {
			for _, r := range arr(response[key]) {
				t.handleFrame(obj(r))
			}
		}
		return
	}
	if typ == "control_request" {
		t.handleInteraction(frame)
		return
	}
	t.mu.Lock()
	active := t.active
	executionID := t.lastExecution
	if active != nil {
		executionID = active.id
	}
	t.mu.Unlock()
	if typ == "control_cancel_request" {
		id := str(frame["request_id"])
		t.mu.Lock()
		delete(t.interactions, id)
		t.mu.Unlock()
		t.emit(NativeEvent{ExecutionID: executionID, Frame: frame})
		t.completeSynthetic()
		return
	}
	if typ == "transcript_mirror" {
		return
	}
	if typ == "user" && frame["parent_tool_use_id"] == nil && !hasToolResult(frame) {
		id := str(frame["uuid"])
		t.mu.Lock()
		active = t.active
		if active != nil {
			for _, b := range active.boundaries {
				if b.id == id {
					b.admitted = true
					t.mu.Unlock()
					return
				}
			}
		}
		if str(obj(frame["origin"])["kind"]) == "task-notification" && active == nil && id != "" {
			t.active = &nativeExecution{id: id, boundaries: []*nativeBoundary{{id: id, admitted: true}}}
			t.lastExecution = id
			t.mu.Unlock()
			t.emit(NativeEvent{ExecutionID: id, NativeStart: true, Prompt: frameText(frame)})
			return
		}
		t.mu.Unlock()
		return
	}
	if typ == "result" {
		t.handleResult(frame)
		return
	}
	if typ == "command_lifecycle" {
		t.mu.Lock()
		active = t.active
		if active != nil && contains([]string{"completed", "cancelled", "discarded"}, str(frame["state"])) {
			for _, b := range active.boundaries {
				if b.id == str(frame["command_uuid"]) {
					b.ended = true
				}
			}
			all := true
			for _, b := range active.boundaries {
				if !b.ended {
					all = false
				}
			}
			if all && active.deferredOutcome != "" {
				t.active = nil
				t.lastExecution = active.id
				t.mu.Unlock()
				outcome := active.deferredOutcome
				if active.cancelled {
					outcome = "interrupted"
				}
				t.emit(NativeEvent{ExecutionID: active.id, Outcome: outcome, Error: active.deferredError})
				return
			}
		}
		t.mu.Unlock()
		return
	}
	if typ == "system" {
		t.emit(NativeEvent{ExecutionID: executionID, Frame: frame})
		return
	}
	t.mu.Lock()
	active = t.active
	accepted := false
	boundaryID := ""
	if active != nil {
		executionID = active.id
		for _, b := range active.boundaries {
			if b.admitted && (str(frame["user_message_uuid"]) == "" || str(frame["user_message_uuid"]) == b.id) {
				accepted = true
				boundaryID = b.id
			}
		}
	}
	t.mu.Unlock()
	if accepted {
		if str(frame["user_message_uuid"]) == "" {
			frame["user_message_uuid"] = boundaryID
		}
		t.emit(NativeEvent{ExecutionID: executionID, Frame: frame})
	}
}
func (t *Transport) handleResult(frame map[string]any) {
	id := str(frame["user_message_uuid"])
	t.mu.Lock()
	active := t.active
	if active == nil || id == "" {
		t.mu.Unlock()
		return
	}
	index := -1
	for i, b := range active.boundaries {
		if b.id == id && b.admitted && !b.ended {
			index = i
			break
		}
	}
	if index < 0 {
		t.mu.Unlock()
		return
	}
	active.boundaries = append(active.boundaries[:index], active.boundaries[index+1:]...)
	live := active.boundaries[:0]
	for _, b := range active.boundaries {
		if !b.ended {
			live = append(live, b)
		}
	}
	active.boundaries = live
	outcome := "completed"
	message := ""
	if frame["is_error"] == true || str(frame["subtype"]) != "" && str(frame["subtype"]) != "success" {
		outcome = "failed"
		parts := []string{}
		for _, v := range arr(frame["errors"]) {
			if s := str(v); s != "" {
				parts = append(parts, s)
			}
		}
		message = strings.Join(parts, "\n")
		if message == "" {
			message = nonempty(str(frame["result"]), "Claude execution failed")
		}
	}
	pending := len(active.boundaries) > 0
	if pending {
		active.deferredOutcome = outcome
		active.deferredError = message
	} else {
		t.active = nil
		t.lastExecution = active.id
	}
	t.mu.Unlock()
	t.emit(NativeEvent{ExecutionID: active.id, Frame: frame})
	if !pending {
		if active.cancelled {
			outcome = "interrupted"
		}
		t.emit(NativeEvent{ExecutionID: active.id, Outcome: outcome, Error: message})
		t.promotePending()
	}
}
func (t *Transport) handleInteraction(frame map[string]any) {
	id := str(frame["request_id"])
	request := obj(frame["request"])
	kind := str(request["subtype"])
	if id == "" || len(id) > 512 || strings.ContainsRune(id, 0) {
		t.failProtocol("Claude control request has no valid request_id")
		return
	}
	if !contains([]string{"can_use_tool", "elicitation", "request_user_dialog"}, kind) {
		_ = t.write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "error", "request_id": id, "error": "Unsupported Claude control: " + kind}})
		t.failProtocol("Unsupported Claude control: " + kind)
		return
	}
	if !t.options.Interactive {
		payload := map[string]any{"behavior": "deny", "message": "Mokusei non-interactive task does not allow interactive approval", "toolUseID": request["tool_use_id"]}
		if kind == "elicitation" {
			payload = map[string]any{"action": "decline"}
		}
		if kind == "request_user_dialog" {
			payload = map[string]any{"behavior": "cancelled"}
		}
		_ = t.controlReply(id, payload)
		return
	}
	t.mu.Lock()
	t.interactions[id] = request
	active := t.active
	wake := active == nil
	if wake {
		active = &nativeExecution{id: newID(), synthetic: true}
		t.active = active
		t.lastExecution = active.id
	}
	t.mu.Unlock()
	if wake {
		t.emit(NativeEvent{ExecutionID: active.id, NativeStart: true, Prompt: "Claude 后台任务需要你的响应"})
	}
	t.emit(NativeEvent{ExecutionID: active.id, Frame: frame})
}
func (t *Transport) promotePending() {
	t.mu.Lock()
	if t.active != nil || len(t.interactions) == 0 {
		t.mu.Unlock()
		return
	}
	active := &nativeExecution{id: newID(), synthetic: true}
	t.active = active
	t.lastExecution = active.id
	requests := map[string]map[string]any{}
	for id, r := range t.interactions {
		requests[id] = r
	}
	t.mu.Unlock()
	t.emit(NativeEvent{ExecutionID: active.id, NativeStart: true, Prompt: "Claude 后台任务需要你的响应"})
	for id, r := range requests {
		t.emit(NativeEvent{ExecutionID: active.id, Frame: map[string]any{"type": "control_request", "request_id": id, "request": r}})
	}
}
func (t *Transport) completeSynthetic() {
	t.mu.Lock()
	active := t.active
	if active == nil || !active.synthetic || len(t.interactions) > 0 {
		t.mu.Unlock()
		return
	}
	t.active = nil
	t.lastExecution = active.id
	t.mu.Unlock()
	t.emit(NativeEvent{ExecutionID: active.id, Outcome: "completed"})
}
func (t *Transport) controlReply(id string, payload map[string]any) error {
	return t.write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": id, "response": payload}})
}
func (t *Transport) Respond(id string, payload map[string]any) error {
	t.mu.Lock()
	_, ok := t.interactions[id]
	t.mu.Unlock()
	if !ok {
		return errors.New("Claude interaction no longer pending")
	}
	if err := t.controlReply(id, payload); err != nil {
		return err
	}
	t.mu.Lock()
	delete(t.interactions, id)
	t.mu.Unlock()
	t.completeSynthetic()
	return nil
}
func (t *Transport) ApplySettings(ctx context.Context, next Settings) error {
	t.mu.Lock()
	previous := t.options.Settings
	started := t.initialized
	t.mu.Unlock()
	if started {
		requests := []map[string]any{}
		if previous.Model != next.Model {
			requests = append(requests, map[string]any{"subtype": "set_model", "model": nullable(next.Model)})
		}
		if previous.PermissionMode != next.PermissionMode {
			requests = append(requests, map[string]any{"subtype": "set_permission_mode", "mode": nonempty(next.PermissionMode, "auto")})
		}
		if previous.Effort != next.Effort {
			requests = append(requests, map[string]any{"subtype": "apply_flag_settings", "settings": map[string]any{"effortLevel": nullable(next.Effort)}})
		}
		for _, r := range requests {
			if _, err := t.Control(ctx, r); err != nil {
				return err
			}
		}
	}
	t.mu.Lock()
	t.options.Settings = next
	t.mu.Unlock()
	return nil
}
func (t *Transport) Interrupt(ctx context.Context) error {
	t.mu.Lock()
	active := t.active
	if active == nil {
		t.mu.Unlock()
		return nil
	}
	active.cancelled = true
	t.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_, err := t.Control(ctx, map[string]any{"subtype": "interrupt", "cancel_queued": true})
	if err != nil {
		t.stopProcess()
	}
	t.mu.Lock()
	if t.active == active {
		t.active = nil
		t.lastExecution = active.id
	}
	t.interactions = map[string]map[string]any{}
	t.mu.Unlock()
	t.emit(NativeEvent{ExecutionID: active.id, Outcome: "interrupted"})
	return err
}
func (t *Transport) stopProcess() error {
	t.mu.Lock()
	done := t.done
	groups := append([]int{}, t.groups...)
	t.stopping = true
	t.mu.Unlock()
	if len(groups) == 0 {
		return nil
	}
	for _, pid := range groups {
		_ = syscall.Kill(-pid, syscall.SIGTERM)
	}
	rootDone := done == nil
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if !rootDone {
			select {
			case <-done:
				rootDone = true
			default:
			}
		}
		alive := false
		for _, pid := range groups {
			if processGroupAlive(pid) {
				alive = true
			}
		}
		if rootDone && !alive {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	for _, pid := range groups {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
	}
	deadline = time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if !rootDone {
			select {
			case <-done:
				rootDone = true
			default:
			}
		}
		alive := false
		for _, pid := range groups {
			if processGroupAlive(pid) {
				alive = true
			}
		}
		if rootDone && !alive {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("Claude process group did not terminate after SIGKILL")
}
func processGroupAlive(pid int) bool {
	err := syscall.Kill(-pid, 0)
	return err == nil || err == syscall.EPERM
}
func (t *Transport) Close() error {
	t.closeOnce.Do(func() {
		var err error
		t.mu.Lock()
		t.disposed = true
		stdin := t.stdin
		t.stdin = nil
		t.mu.Unlock()
		if stdin != nil {
			_ = stdin.Close()
		}
		err = t.stopProcess()
		t.eventMu.Lock()
		t.eventsClosed = true
		close(t.events)
		t.eventMu.Unlock()
		<-t.eventsDone
		t.closeError = err
	})
	return t.closeError
}
func str(v any) string         { s, _ := v.(string); return s }
func obj(v any) map[string]any { m, _ := v.(map[string]any); return m }
func arr(v any) []any          { a, _ := v.([]any); return a }
func nonempty(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}
func contains(v []string, s string) bool {
	for _, x := range v {
		if x == s {
			return true
		}
	}
	return false
}
func number(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case int64:
		return float64(n)
	case json.Number:
		f, _ := n.Float64()
		return f
	}
	return 0
}
func hasToolResult(f map[string]any) bool {
	for _, v := range arr(obj(f["message"])["content"]) {
		if str(obj(v)["type"]) == "tool_result" {
			return true
		}
	}
	return false
}
func frameText(f map[string]any) string {
	value := obj(f["message"])["content"]
	if s, ok := value.(string); ok {
		return s
	}
	parts := []string{}
	for _, v := range arr(value) {
		if str(obj(v)["type"]) == "text" {
			parts = append(parts, str(obj(v)["text"]))
		}
	}
	return strings.Join(parts, "\n")
}

func (t *Transport) failProtocol(message string) {
	t.mu.Lock()
	active := t.active
	t.active = nil
	t.mu.Unlock()
	if active != nil {
		t.emit(NativeEvent{ExecutionID: active.id, Outcome: "failed", Error: message})
	}
	go t.stopProcess()
}
