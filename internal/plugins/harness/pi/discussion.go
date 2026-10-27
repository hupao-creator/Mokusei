package pi

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type discussion struct {
	rpc       *Session
	directory string
	ctx       context.Context
	cancel    context.CancelFunc
	active    atomic.Bool
	gate      chan struct{}
	once      sync.Once
	closeErr  error
}

func (a *Adapter) PrepareDiscussion(ctx context.Context, request plugin.DiscussionRequest) (_ plugin.Discussion, err error) {
	state, err := decodeState(request.Source.SessionState)
	if err != nil {
		return nil, err
	}
	history := state.NativeSessionJSONL
	if state.ForkSource != nil {
		history = state.ForkSource.JSONL
	}
	if history == "" && state.SessionFile != "" {
		// During an active run the Thread clears its committed snapshot. Freeze the
		// persisted native tree read-only instead of opening/resuming the live RPC
		// session. Streaming text not yet persisted is intentionally not included.
		data, readErr := os.ReadFile(state.SessionFile)
		if readErr != nil {
			return nil, readErr
		}
		history = string(data)
	}
	if history == "" {
		return nil, errors.New("Pi has no saved native history for discussion; complete a conversation first")
	}
	// Pi's loader can skip malformed lines. Refuse a damaged snapshot rather than
	// silently discussing a partial history or starting an empty conversation.
	lines := strings.Split(strings.TrimSpace(history), "\n")
	var header struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	}
	if len(lines) < 2 || json.Unmarshal([]byte(lines[0]), &header) != nil || header.Type != "session" || header.ID == "" {
		return nil, errors.New("Pi discussion requires a complete native JSONL history")
	}
	for _, line := range lines {
		var entry map[string]json.RawMessage
		if json.Unmarshal([]byte(line), &entry) != nil || entry == nil || entry["type"] == nil {
			return nil, errors.New("Pi discussion native history is incomplete or invalid JSONL; retry after the current native write")
		}
	}
	settings, err := normalizeThread(request.Source.Settings)
	if err != nil {
		return nil, err
	}
	cwd := request.Source.Cwd
	if request.Source.Worktree != nil {
		cwd = request.Source.Worktree.Cwd
	}
	executable, err := resolveExecutable(ctx, a.host, cwd, settings.ExecutablePath)
	if err != nil {
		return nil, err
	}
	env, err := inheritedEnvironment(ctx, a.host)
	if err != nil {
		return nil, err
	}
	effective := settings
	directory, err := temporaryWorkspace(a.host, "pi-discussion-")
	if err != nil {
		return nil, err
	}
	life, cancel := context.WithCancel(ctx)
	d := &discussion{directory: directory, ctx: life, cancel: cancel, gate: make(chan struct{}, 1)}
	defer func() {
		if err != nil {
			err = errors.Join(err, d.Close())
		}
	}()
	injection := plugin.Injection{Instructions: []string{request.Instructions}, Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: request.Tools}}
	config, err := bridgeConfig(injection)
	if err != nil {
		return nil, err
	}
	snapshot := filepath.Join(directory, "source.jsonl")
	extension := filepath.Join(directory, "host-extension.mjs")
	configFile := filepath.Join(directory, "config.json")
	for path, data := range map[string][]byte{snapshot: []byte(history), extension: hostExtension, configFile: config} {
		if err = os.WriteFile(path, data, 0600); err != nil {
			return nil, err
		}
	}
	env["MOKUSEI_PI_BRIDGE_CONFIG"] = configFile
	names := []string{}
	for _, tool := range request.Tools {
		names = append(names, tool.Name)
	}
	args := []string{"--session-dir", directory, "--fork", snapshot, "--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "-e", extension}
	if len(names) > 0 {
		args = append(args, "--tools", strings.Join(names, ","))
	}
	d.rpc, err = StartSession(life, ProcessOptions{ExecutablePath: executable, Cwd: cwd, Env: env, Args: append(args, modelArguments(effective)...), Bridge: &BridgeOptions{Injection: injection, CanExecute: d.active.Load}})
	if err != nil {
		return nil, err
	}
	native, err := d.rpc.State(ctx)
	if err != nil {
		return nil, err
	}
	sessionFile, err := filepath.Abs(native.SessionFile)
	if err != nil {
		return nil, err
	}
	if native.SessionFile == "" || sessionFile == snapshot || filepath.Dir(sessionFile) != directory || native.SessionID == "" || native.SessionID == header.ID {
		return nil, errors.New("Pi did not create an independent discussion fork")
	}
	if err = assertRuntimeSettings(ctx, d.rpc, settings, true); err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	go func() { <-life.Done(); _ = d.Close() }()
	return d, nil
}

func (d *discussion) Ask(ctx context.Context, question string) (answer string, err error) {
	if strings.TrimSpace(question) == "" {
		return "", errors.New("Pi discussion question is empty")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(d.ctx, cancel)
	defer stop()
	select {
	case d.gate <- struct{}{}:
		defer func() { <-d.gate }()
	case <-ctx.Done():
		return "", ctx.Err()
	}
	if err = ctx.Err(); err != nil {
		return "", err
	}
	d.active.Store(true)
	defer d.active.Store(false)
	defer func() {
		if err != nil {
			err = errors.Join(err, d.Close())
		}
	}()
	completion, err := d.rpc.Complete(ctx, PromptInput{Message: "Current discussion question (do not continue the source task):\n\n" + question}, CompletionPolicy{DisallowNotifications: true})
	if err != nil {
		return "", err
	}
	answer = strings.TrimSpace(completion.Text)
	if answer == "" {
		return "", errors.New("Pi discussion returned no answer")
	}
	return answer, nil
}
func (d *discussion) Close() error {
	d.once.Do(func() {
		d.cancel()
		d.active.Store(false)
		if d.rpc != nil {
			d.closeErr = d.rpc.Close()
		}
		d.closeErr = errors.Join(d.closeErr, os.RemoveAll(d.directory))
	})
	return d.closeErr
}

var _ plugin.DiscussionPreparer = (*Adapter)(nil)
var _ plugin.Discussion = (*discussion)(nil)
