package claude

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Chief/internal/core/model"
	"github.com/hupao-creator/Chief/internal/core/plugin"
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
		ExecutionID  string `json:"executionId,omitempty"`
	}
	if !model.IsNull(r.Request) {
		if e = model.Unmarshal(r.Request, &request); e != nil {
			return plugin.ForkResult{}, e
		}
	}
	executionCheckpoint := ""
	if request.ExecutionID != "" {
		if request.CheckpointID != "" {
			return plugin.ForkResult{}, errors.New("choose either a Claude execution or checkpoint")
		}
		index := -1
		for i, turn := range source.Turns {
			if turn.ExecutionID == request.ExecutionID {
				index = i
				break
			}
		}
		if index < 0 {
			return plugin.ForkResult{}, errors.New("Claude execution does not belong to source thread")
		}
		turn := source.Turns[index]
		messageID := ""
		for _, item := range turn.Timeline {
			if item["kind"] == "assistant" && str(item["messageId"]) != "" {
				messageID = str(item["messageId"])
			}
		}
		executionCheckpoint, e = h.forkCheckpoint(ctx, source.PrimarySessionID, messageID)
		if e != nil {
			return plugin.ForkResult{}, e
		}
		source.Turns = source.Turns[:index+1]
	}
	items := []any{}
	if request.ExecutionID != "" {
		if inherited, ok := source.ForkHistory["items"].([]any); ok {
			items = append(items, inherited...)
		}
	}
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
		// Fork history resolves timeline references against the turn's current
		// entity tables at fork time. An entity that began before the selected
		// checkpoint but finished later therefore carries its final state here;
		// running/pending entities still become cancelled. review and error are
		// canonical latest-only markers, so a marker replaced after the selected
		// prefix is not inherited from an earlier revision.
		activities, interactions, notices := map[string]map[string]any{}, map[string]map[string]any{}, map[string]map[string]any{}
		for _, value := range turn.Activities {
			activities[str(value["id"])] = value
		}
		for _, value := range turn.Interactions {
			interactions[str(value["id"])] = value
		}
		for _, value := range turn.Notices {
			notices[str(value["id"])] = value
		}
		emitted := map[string]bool{}
		for _, item := range selected {
			kind := str(item["kind"])
			if contains([]string{"plan", "usage", "diff"}, kind) {
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
				field := map[string]string{"activity": "activityId", "interaction": "interactionId"}[kind]
				id := str(item[field])
				key := kind + ":" + id
				if emitted[key] {
					continue
				}
				emitted[key] = true
				delete(out, field)
				raw := activities[id]
				if kind == "interaction" {
					raw = interactions[id]
				}
				if raw == nil {
					return plugin.ForkResult{}, errors.New("invalid Claude " + kind + " timeline reference")
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
				delete(out, "noticeId")
				notice := cloneObject(notices[str(item["noticeId"])])
				if notice == nil {
					return plugin.ForkResult{}, errors.New("invalid Claude notice timeline reference")
				}
				delete(notice, "id")
				out["notice"] = notice
			case "error":
				out["message"] = turn.Error
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
	if executionCheckpoint != "" {
		history["checkpointId"] = executionCheckpoint
		pending["checkpointId"] = executionCheckpoint
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

// Claude's API message.id is not the transcript UUID accepted by
// --resume-session-at. Resolve that UUID only in the selected native session.
func (h *Harness) forkCheckpoint(ctx context.Context, sessionID, messageID string) (string, error) {
	failure := errors.New("Claude native checkpoint for this execution is unavailable")
	if messageID == "" || sessionID == "" || filepath.Base(sessionID) != sessionID || sessionID == "." || sessionID == ".." {
		return "", failure
	}
	_, env, err := h.resolveEnvironment(ctx)
	if err != nil {
		return "", err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	root := filepath.Join(nonempty(env["CLAUDE_CONFIG_DIR"], filepath.Join(nonempty(env["HOME"], home), ".claude")), "projects")
	projects, err := os.ReadDir(root)
	if err != nil {
		return "", err
	}
	for _, project := range projects {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if !project.IsDir() {
			continue
		}
		file, err := os.Open(filepath.Join(root, project.Name(), sessionID+".jsonl"))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		checkpoint := ""
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 8192), 4*1024*1024)
		for scanner.Scan() {
			if err = ctx.Err(); err != nil {
				break
			}
			var entry struct {
				Type      string `json:"type"`
				UUID      string `json:"uuid"`
				SessionID string `json:"sessionId"`
				Message   struct {
					ID string `json:"id"`
				} `json:"message"`
			}
			if err = json.Unmarshal(scanner.Bytes(), &entry); err != nil {
				break
			}
			if entry.Type == "assistant" && entry.Message.ID == messageID && entry.SessionID == sessionID {
				checkpoint = entry.UUID
			}
		}
		readErr := errors.Join(err, scanner.Err(), file.Close())
		if readErr != nil {
			return "", readErr
		}
		if checkpoint == "" {
			return "", failure
		}
		return checkpoint, nil
	}
	return "", failure
}
func intContains(a []int, v int) bool {
	for _, x := range a {
		if x == v {
			return true
		}
	}
	return false
}
