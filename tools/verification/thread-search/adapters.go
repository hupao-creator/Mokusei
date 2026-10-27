package main

import (
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

func verifyTextAdapters() {
	type sample struct {
		adapter plugin.SearchTextAdapter
		state   json.RawMessage
	}
	cs := claude.NewState()
	codexState := codex.EmptyState(1)
	messages := []any{}
	executions := []any{}
	for index, outcome := range []string{"completed", "failed", "interrupted", "running"} {
		text := "NEVER_UPLOAD_" + outcome
		if outcome == "completed" {
			text = "中文用户消息"
		}
		id := "execution-" + outcome
		at := int64(10 + index*10)
		next, err := codex.StageExecutionChecked(codexState, id, codex.Map{"parts": []any{codex.Map{"kind": "text", "text": text}, codex.Map{"kind": "image-url", "url": "NEVER_UPLOAD_ATTACHMENT"}}}, at, codex.Map{})
		must(err)
		codexState = next
		if outcome != "running" {
			codexState = codex.SettleExecution(codexState, id, outcome, at+1, "")
		}
		turn := cs.NewTurn(id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}, claude.Settings{})
		turn.Text = text + " assistant reply"
		turn.Reasoning = "NEVER_UPLOAD_REASONING"
		turn.PromptAttachments[0] = []map[string]any{{"url": "NEVER_UPLOAD_ATTACHMENT"}}
		turn.Status = outcome
		if outcome != "running" {
			finished := turn.UpdatedAt + 1
			turn.FinishedAt = &finished
		}
		execution := map[string]any{"executionId": id, "status": outcome, "startedAt": at}
		if outcome != "running" {
			execution["finishedAt"] = at + 1
		}
		executions = append(executions, execution)
		messages = append(messages,
			map[string]any{"id": id + "-u", "executionId": id, "role": "user", "text": text},
			map[string]any{"id": id + "-a", "executionId": id, "role": "assistant", "text": text + " assistant reply", "thinking": "NEVER_UPLOAD_REASONING"},
			map[string]any{"id": id + "-t", "executionId": id, "role": "tool", "text": "NEVER_UPLOAD_TOOL"})
	}
	messages = append(messages, map[string]any{"id": "unknown", "executionId": "unknown", "role": "assistant", "text": "NEVER_UPLOAD_UNKNOWN"})
	claudeRaw, err := cs.Encode()
	must(err)
	messageState := raw(map[string]any{"version": 1, "messages": messages, "executions": executions, "latestExecutionId": "execution-running"})
	samples := []sample{{codex.NewSessionStateAdapter().(plugin.SearchTextAdapter), raw(codexState)}, {claude.StateAdapter{}, claudeRaw}, {pi.New(plugin.HostContext{}).SessionState().(plugin.SearchTextAdapter), messageState}, {opencode.StateAdapter{}, messageState}}
	for _, s := range samples {
		text, err := s.adapter.SearchText(s.state)
		must(err)
		assert(strings.Contains(text, "中文用户消息") && !strings.Contains(text, "NEVER_UPLOAD"), "only completed-turn public text is extracted; other outcomes, unknown executions and private fields are excluded")
	}
}
