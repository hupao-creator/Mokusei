package claude

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (h *Harness) Fork(ctx context.Context, r plugin.ForkRequest) (plugin.ForkResult, error) {
	if e := ctx.Err(); e != nil {
		return plugin.ForkResult{}, e
	}
	source, e := ParseState(r.Source.SessionState)
	if e != nil {
		return plugin.ForkResult{}, e
	}
	if source.PrimarySessionID == "" {
		return plugin.ForkResult{}, errors.New("Claude source has no primary native session")
	}
	var request struct {
		CheckpointID string `json:"checkpointId,omitempty"`
	}
	if !model.IsNull(r.Request) {
		if e = model.Unmarshal(r.Request, &request); e != nil {
			return plugin.ForkResult{}, e
		}
	}
	items := []any{}
	found := request.CheckpointID == ""
	stop := false
	for _, turn := range source.Turns {
		if stop {
			break
		}
		selected := turn.Timeline
		checkpointIndex := -1
		if request.CheckpointID != "" {
			for index, item := range selected {
				if str(item["kind"]) == "user-message" && str(item["checkpointId"]) == request.CheckpointID && !intContains(turn.InternalPromptIndexes, int(number(item["promptIndex"]))) {
					checkpointIndex = index
					break
				}
			}
			if checkpointIndex >= 0 {
				found = true
				end := checkpointIndex + 1
				for index := checkpointIndex + 1; index < len(selected); index++ {
					if str(selected[index]["kind"]) == "assistant" {
						end = index + 1
						break
					}
				}
				selected = selected[:end]
				stop = true
			}
		}
		latestActivities, latestInteractions := map[string]map[string]any{}, map[string]map[string]any{}
		replace := map[string]int{}
		for index, item := range selected {
			kind := str(item["kind"])
			if kind == "activity" {
				v := obj(item["activity"])
				latestActivities[str(v["id"])] = v
			}
			if kind == "interaction" {
				v := obj(item["interaction"])
				latestInteractions[str(v["id"])] = v
			}
			if contains([]string{"plan", "usage", "diff", "review"}, kind) {
				replace[kind] = index
			}
		}
		emitted := map[string]bool{}
		for index, item := range selected {
			kind := str(item["kind"])
			if last, ok := replace[kind]; ok && last != index {
				continue
			}
			out := cloneObject(item)
			out["id"] = fmt.Sprintf("fork-history:%d", len(items))
			switch kind {
			case "user-message":
				promptIndex := int(number(item["promptIndex"]))
				if intContains(turn.InternalPromptIndexes, promptIndex) {
					continue
				}
				if promptIndex < 0 || promptIndex >= len(turn.Prompts) {
					return plugin.ForkResult{}, errors.New("invalid Claude prompt timeline reference")
				}
				delete(out, "promptIndex")
				out["content"] = turn.Prompts[promptIndex]
				if len(turn.PromptAttachments[promptIndex]) > 0 {
					out["attachments"] = turn.PromptAttachments[promptIndex]
				}
			case "assistant":
				delete(out, "messageId")
				if str(out["status"]) == "streaming" {
					out["status"] = "cancelled"
				}
			case "activity", "interaction":
				raw := obj(item[kind])
				id := str(raw["id"])
				key := kind + ":" + id
				if emitted[key] {
					continue
				}
				emitted[key] = true
				if kind == "activity" {
					raw = latestActivities[id]
				} else {
					raw = latestInteractions[id]
				}
				value := map[string]any{}
				keys := []string{"kind", "label", "status", "detail", "toolName"}
				if kind == "interaction" {
					keys = []string{"kind", "title", "description", "toolName", "questions", "status"}
				}
				for _, key := range keys {
					if v, ok := raw[key]; ok {
						value[key] = v
					}
				}
				if str(value["status"]) == "running" || str(value["status"]) == "pending" {
					value["status"] = "cancelled"
				}
				out[kind] = value
			case "notice":
				notice := cloneObject(obj(item["notice"]))
				delete(notice, "id")
				out["notice"] = notice
			}
			items = append(items, out)
			if len(items) > 4000 {
				return plugin.ForkResult{}, errors.New("Claude fork history exceeds item limit")
			}
		}
	}
	if !found {
		return plugin.ForkResult{}, errors.New("Claude checkpoint does not belong to source thread")
	}
	history := map[string]any{"sourceSessionId": source.PrimarySessionID, "items": items}
	pending := map[string]any{"sourceSessionId": source.PrimarySessionID}
	if request.CheckpointID != "" {
		history["checkpointId"] = request.CheckpointID
		pending["checkpointId"] = request.CheckpointID
	}
	state := NewState()
	state.PendingFork = pending
	state.ForkHistory = history
	raw, e := state.Encode()
	if e != nil {
		return plugin.ForkResult{}, e
	}
	if len(raw) > 4*1024*1024 {
		return plugin.ForkResult{}, errors.New("Claude fork history exceeds size limit")
	}
	return plugin.ForkResult{SessionState: raw}, nil
}
func intContains(a []int, v int) bool {
	for _, x := range a {
		if x == v {
			return true
		}
	}
	return false
}

type discussion struct {
	mu        sync.Mutex
	ctx       context.Context
	cancel    context.CancelFunc
	transport *Transport
	bridge    *ToolBridge
	turn      *Turn
	parser    *frameParser
	state     *State
	activeID  string
	result    *discussionPending
	closeOnce sync.Once
	closeErr  error
}
type discussionPending struct {
	done     chan struct{}
	value    discussionResult
	finished bool
}
type discussionResult struct {
	text string
	err  error
}

func (h *Harness) PrepareDiscussion(ctx context.Context, r plugin.DiscussionRequest) (plugin.Discussion, error) {
	state, e := ParseState(r.Source.SessionState)
	if e != nil {
		return nil, e
	}
	if state.PrimarySessionID == "" {
		return nil, errors.New("complete one conversation in this thread before starting a discussion")
	}
	settings, e := parseSettings(r.Source.Settings)
	if e != nil {
		return nil, e
	}
	cwd := r.Source.Cwd
	if r.Source.Worktree != nil {
		cwd = r.Source.Worktree.Cwd
	}
	path, env, e := h.resolve(ctx, cwd, settings.ExecutablePath)
	if e != nil {
		return nil, e
	}
	exe, e := os.Executable()
	if e != nil {
		return nil, e
	}
	bridge, e := NewToolBridge(exe, r.Tools)
	if e != nil {
		return nil, e
	}
	ctx, cancel := context.WithCancel(ctx)
	d := &discussion{ctx: ctx, cancel: cancel, bridge: bridge, state: NewState()}
	settings.PermissionMode = "dontAsk"
	settings.AllowedTools = []string{}
	settings.DisallowedTools = nil
	for _, tool := range r.Tools {
		settings.AllowedTools = append(settings.AllowedTools, "mcp__mokusei__"+tool.Name)
	}
	d.transport = NewTransport(TransportOptions{Executable: path, Cwd: cwd, Environment: env, SessionID: newID(), ForkFromSessionID: state.PrimarySessionID, Settings: settings, ApplicationToolsOnly: true, ReadOnlyDiscussion: true, SystemPrompt: r.Instructions, ToolBridge: bridge, OnEvent: d.event})
	if _, e = d.transport.Initialize(ctx); e != nil {
		d.Close()
		return nil, e
	}
	go func() { <-ctx.Done(); d.Close() }()
	return d, nil
}
func (d *discussion) event(e NativeEvent) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.activeID == "" || e.ExecutionID != "" && e.ExecutionID != d.activeID {
		return
	}
	if e.Frame != nil {
		d.parser.apply(d.state, d.turn, e.Frame, d.bridge.CanonicalToolName)
	}
	if len(d.turn.Text) > 256000 {
		d.finish("", errors.New("discussion answer exceeds size limit"))
		go d.Close()
		return
	}
	if e.Outcome != "" {
		if e.Outcome != "completed" {
			d.finish("", errors.New(nonempty(e.Error, "Claude discussion "+e.Outcome)))
		} else {
			d.finish(strings.TrimSpace(fullAssistantReply(d.turn)), nil)
		}
		d.activeID = ""
		d.bridge.Deactivate()
	}
}
func (d *discussion) finish(text string, err error) {
	if d.result == nil || d.result.finished {
		return
	}
	d.result.value = discussionResult{text, err}
	d.result.finished = true
	close(d.result.done)
}
func (d *discussion) Ask(ctx context.Context, question string) (string, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(d.ctx, cancel)
	defer stop()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	d.mu.Lock()
	id := d.activeID
	fresh := id == ""
	if fresh {
		id = newID()
		d.activeID = id
		d.parser = newParser()
		d.turn = d.state.NewTurn(id, model.AgentInput{Parts: []model.AgentInputPart{}}, d.transport.options.Settings)
		d.result = &discussionPending{done: make(chan struct{})}
		if e := d.bridge.Activate(ctx); e != nil {
			d.activeID = ""
			d.result = nil
			d.mu.Unlock()
			return "", e
		}
	}
	result := d.result
	d.mu.Unlock()
	if _, e := d.transport.Send(ctx, id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: question}}}, "now"); e != nil {
		d.mu.Lock()
		d.finish("", e)
		d.activeID = ""
		d.bridge.Deactivate()
		d.mu.Unlock()
		return "", e
	}
	defer func() {
		if !fresh {
			return
		}
		d.mu.Lock()
		if d.result == result {
			d.activeID = ""
			d.result = nil
			d.bridge.Deactivate()
		}
		d.mu.Unlock()
	}()
	select {
	case <-ctx.Done():
		_ = d.Close()
		return "", ctx.Err()
	case <-result.done:
		d.mu.Lock()
		value := result.value
		d.mu.Unlock()
		return value.text, value.err
	}
}
func (d *discussion) Close() error {
	d.closeOnce.Do(func() {
		d.cancel()
		d.mu.Lock()
		d.finish("", context.Canceled)
		d.mu.Unlock()
		d.closeErr = errors.Join(d.transport.Close(), d.bridge.Close())
	})
	return d.closeErr
}

var _ plugin.Forker = (*Harness)(nil)
var _ plugin.DiscussionPreparer = (*Harness)(nil)
var _ plugin.MokuContextContributor = (*Harness)(nil)

func fullAssistantReply(turn *Turn) string {
	id := str(turn.LastAssistantMessage["id"])
	if id == "" {
		return str(turn.LastAssistantMessage["text"])
	}
	var text strings.Builder
	for _, item := range turn.Timeline {
		if str(item["kind"]) == "assistant" && str(item["messageId"]) == id {
			text.WriteString(str(item["content"]))
		}
	}
	return text.String()
}
