package opencode

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const rendererPreview = 1200
const rendererDirectoryPreview = 600

// Native Foundation grouping treats NEL and zero-width space as empty in
// deferred content. Ordinary preview trimming deliberately follows JS trim.
func rendererNativeNonempty(text string) bool {
	return strings.TrimFunc(text, func(r rune) bool { return unicode.IsSpace(r) || r == '\ufeff' || r == '\u200b' }) != ""
}
func rendererTrim(text string) string {
	return strings.TrimFunc(text, func(r rune) bool { return (unicode.IsSpace(r) && r != '\u0085') || r == '\ufeff' })
}
func rendererObject(value any) Object {
	encoded, _ := json.Marshal(value)
	var result Object
	_ = json.Unmarshal(encoded, &result)
	return result
}
func rendererMessage(message *Message, source rendererSource) Object {
	if record, exists := source.records["messages"][message.ID]; exists {
		return clone(record.value)
	}
	result := rendererObject(message)
	if message.Parts != nil {
		parts := make([]Object, 0, len(message.Parts))
		for _, part := range message.Parts {
			parts = append(parts, rendererPart(part))
		}
		result["parts"] = parts
	}
	return result
}
func rendererPart(part Part) Object {
	if part.Type == "tool" {
		return Object{"type": "tool", "toolCallId": part.ToolCallID}
	}
	return Object{"type": part.Type, "ordinal": part.Ordinal, "text": part.Text}
}
func rendererProjectedMessage(message *Message, source rendererSource) Object {
	result := rendererMessage(message, source)
	if message.Role == "tool" {
		if value, exists := result["arguments"]; exists {
			result["argumentsDisplay"] = rendererToolDisplay(source.field("messages", message.ID, "arguments"), value)
		}
		if value, exists := result["result"]; exists {
			result["resultDisplay"] = rendererToolDisplay(source.field("messages", message.ID, "result"), value)
		}
	}
	return result
}

func (StateAdapter) ProjectRenderer(raw json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	state, err := DecodeState(raw)
	if err != nil {
		return nil, err
	}
	source := newRendererSource(raw)
	base := Object{"version": 1}
	if scope.Kind == "overview" {
		initial := len(state.Executions) <= 1 && state.ForkSource == nil
		for _, message := range state.Messages {
			if message.Inherited {
				initial = false
				break
			}
		}
		base["initialResponseScope"] = initial
	}
	if state.NativeSessionID != "" {
		base["nativeSessionId"] = state.NativeSessionID
	}
	if source.has("backgroundSessions") {
		base["backgroundSessions"] = state.BackgroundSessions[max(0, len(state.BackgroundSessions)-32):]
	}
	if source.has("backgroundShells") {
		base["backgroundShells"] = state.BackgroundShells[max(0, len(state.BackgroundShells)-32):]
	}
	if scope.Kind == "turn" || scope.Kind == "execution" {
		return rendererExecution(state, base, scope, source)
	}
	return rendererDirectory(state, base, scope, source)
}

func rendererExecution(state *State, base Object, scope model.RendererScope, source rendererSource) (json.RawMessage, error) {
	history := scope.Key == "opencode-fork-history"
	executions := make([]*model.PublicExecution, 0)
	if !history {
		for _, execution := range state.Executions {
			if execution.ExecutionID == scope.Key {
				executions = append(executions, execution)
			}
		}
	}
	messages := make([]*Message, 0)
	for _, message := range state.Messages {
		if (history && message.Inherited) || (!history && !message.Inherited && message.ExecutionID == scope.Key) {
			messages = append(messages, message)
		}
	}
	settled := len(executions) > 0
	for _, execution := range executions {
		if rendererLive(execution.Status) {
			settled = false
		}
	}
	deferred := scope.Kind == "turn" && (history || settled)
	primary := state.NativeSessionID
	if history && state.ForkSource != nil && state.ForkSource.SessionID != "" {
		primary = state.ForkSource.SessionID
	}
	finalIDs := make(map[string]bool)
	final := ""
	for _, message := range messages {
		if message.NativeSessionID != "" && primary != "" && message.NativeSessionID != primary {
			continue
		}
		if history && message.Role == "user" {
			if final != "" {
				finalIDs[final] = true
			}
			final = ""
		} else if message.Role == "assistant" && rendererNativeNonempty(message.Text) {
			final = message.ID
		}
	}
	if final != "" {
		finalIDs[final] = true
	}
	nonempty := make([]Object, 0)
	hide := func(id, field, text string) string {
		if rendererNativeNonempty(text) {
			nonempty = append(nonempty, Object{"id": id, "field": field})
		}
		return ""
	}
	projected := make([]Object, 0, len(messages))
	for _, message := range messages {
		if !deferred {
			projected = append(projected, rendererProjectedMessage(message, source))
			continue
		}
		child := message.NativeSessionID != "" && primary != "" && message.NativeSessionID != primary
		body := rendererMessage(message, source)
		if message.Role == "user" && !child {
			projected = append(projected, body)
			continue
		}
		for _, key := range []string{"arguments", "result", "metadata", "todos", "annotations", "attachments"} {
			delete(body, key)
		}
		reading := message.Role == "assistant" && !child && finalIDs[message.ID]
		if !reading {
			body["text"] = hide(message.ID, "text", message.Text)
		}
		if _, exists := body["thinking"]; exists {
			body["thinking"] = hide(message.ID, "thinking", message.Thinking)
		}
		if message.Parts != nil {
			parts := make([]Object, 0, len(message.Parts))
			for _, part := range message.Parts {
				item := rendererPart(part)
				if part.Type != "tool" && !(part.Type == "text" && reading) {
					item["text"] = hide(message.ID, fmt.Sprintf("parts:%s:%d", part.Type, part.Ordinal), part.Text)
				}
				parts = append(parts, item)
			}
			body["parts"] = parts
		}
		projected = append(projected, body)
	}
	executionBodies := make([]Object, 0, len(executions))
	for _, execution := range executions {
		executionBodies = append(executionBodies, source.object("executions", execution.ExecutionID, execution))
	}
	base["executions"], base["messages"], base["latestExecutionId"] = executionBodies, projected, nil
	for _, execution := range executions {
		if state.LatestExecutionID != nil && execution.ExecutionID == *state.LatestExecutionID {
			base["latestExecutionId"] = *state.LatestExecutionID
		}
	}
	if author, exists := state.ExecutionAuthors[scope.Key]; exists {
		base["executionAuthors"] = Object{scope.Key: author}
	}
	interactions := make([]Object, 0)
	if !history {
		for _, interaction := range state.Interactions {
			if interaction.ExecutionID == scope.Key {
				interactions = append(interactions, source.object("interactions", interaction.ExecutionID+"\x00"+interaction.ID, interaction))
			}
		}
	}
	base["interactions"] = interactions
	if !deferred && source.has("foregrounds") {
		foregrounds := make([]Object, 0)
		for _, entry := range state.Foregrounds {
			if entry["executionId"] == scope.Key {
				foregrounds = append(foregrounds, entry)
			}
		}
		base["foregrounds"] = foregrounds
	}
	if source.has("auxiliaryUsage") {
		samples := make([]Object, 0)
		for _, sample := range state.AuxiliaryUsage {
			if sample.ExecutionID == scope.Key {
				samples = append(samples, source.object("auxiliaryUsage", sample.ExecutionID+"\x00"+sample.ID, sample))
			}
		}
		base["auxiliaryUsage"] = samples
	}
	if history && state.ForkSource != nil {
		base["forkSource"] = Object{"sessionId": state.ForkSource.SessionID, "transcript": Object{}}
	}
	if deferred {
		return json.Marshal(Object{"kind": "deferred-execution", "state": base, "nonempty": nonempty})
	}
	return json.Marshal(base)
}

func rendererDirectory(state *State, base Object, scope model.RendererScope, source rendererSource) (json.RawMessage, error) {
	latest := ""
	if state.LatestExecutionID != nil {
		latest = *state.LatestExecutionID
	}
	groups := make(map[string][]*Message)
	order := make([]string, 0)
	for _, message := range state.Messages {
		if message.Inherited {
			continue
		}
		if _, exists := groups[message.ExecutionID]; !exists {
			order = append(order, message.ExecutionID)
		}
		groups[message.ExecutionID] = append(groups[message.ExecutionID], message)
	}
	selected, previews := make(map[*Message]bool), make(map[*Message]bool)
	cardStatus := ""
	for _, execution := range state.Executions {
		if execution.ExecutionID == latest {
			cardStatus = execution.Status
			break
		}
	}
	card, reply := rendererCardMessage(state, latest, cardStatus), rendererReplyMessage(state)
	for _, message := range []*Message{card, reply} {
		if message != nil {
			selected[message], previews[message] = true, true
		}
	}
	usages := make(map[*Message]Object)
	for _, id := range order {
		messages := groups[id]
		samples := make([]Usage, 0)
		var carrier *Message
		for _, message := range messages {
			if message.Role == "assistant" && message.Usage != nil {
				samples = append(samples, *message.Usage)
				carrier = message
			}
		}
		if carrier != nil {
			selected[carrier] = true
			usages[carrier] = rendererSumUsage(samples)
		}
		if scope.Kind == "thread" || id == latest {
			var first, last, answer *Message
			for _, message := range messages {
				if message.NativeSessionID != "" && message.NativeSessionID != state.NativeSessionID {
					continue
				}
				if message.Role == "user" {
					if first == nil {
						first = message
					}
					last = message
				}
				if message.Role == "assistant" && rendererTrim(message.Text) != "" {
					answer = message
				}
			}
			candidates := []*Message{first, last}
			if scope.Kind == "thread" {
				candidates = append(candidates, answer)
			}
			for _, message := range candidates {
				if message != nil {
					selected[message], previews[message] = true, true
				}
			}
		}
	}
	var todo *Message
	for _, message := range state.Messages {
		if message.ExecutionID == latest && !message.Inherited && message.Role == "tool" && source.messageHas(message, "todos") {
			todo = message
		}
	}
	if scope.Kind == "overview" && todo != nil {
		selected[todo] = true
	}
	if scope.Kind == "thread" {
		for _, message := range state.Messages {
			if message.Inherited {
				selected[message] = true
				break
			}
		}
	}
	base["latestExecutionId"] = state.LatestExecutionID
	if source.has("executionAuthors") {
		base["executionAuthors"] = state.ExecutionAuthors
	}
	executions := make([]Object, 0, len(state.Executions))
	for _, execution := range state.Executions {
		executions = append(executions, rendererCompactExecution(execution, scope.Kind == "thread" || execution.ExecutionID == latest, source))
	}
	base["executions"] = executions
	messages := make([]Object, 0)
	for _, message := range state.Messages {
		if selected[message] {
			messages = append(messages, rendererCompactMessage(message, previews[message], scope.Kind == "overview" && message == card, scope.Kind == "overview" && message == todo, usages[message], cardStatus, source))
		}
	}
	base["messages"] = messages
	interactions := make([]Object, 0)
	for _, interaction := range state.Interactions {
		if interaction.ExecutionID == latest && interaction.Status == "pending" {
			value := source.object("interactions", interaction.ExecutionID+"\x00"+interaction.ID, interaction)
			delete(value, "metadata")
			interactions = append(interactions, value)
		}
	}
	base["interactions"] = interactions
	if source.has("auxiliaryUsage") {
		base["auxiliaryUsage"] = rendererCompactAuxiliary(state.AuxiliaryUsage, source)
	}
	if scope.Kind == "overview" && source.has("foregrounds") {
		foregrounds := make([]Object, 0)
		for _, entry := range state.Foregrounds {
			if entry["executionId"] == latest {
				value := clone(entry)
				value["foreground"] = rendererCompactForeground(object(entry["foreground"]))
				foregrounds = append(foregrounds, value)
			}
		}
		base["foregrounds"] = foregrounds
	}
	return json.Marshal(base)
}

func rendererLive(status string) bool { return status == "running" || status == "waiting-for-user" }
func rendererCardMessage(state *State, latest, status string) *Message {
	live := rendererLive(status)
	for i := len(state.Messages) - 1; i >= 0; i-- {
		message := state.Messages[i]
		if message.ExecutionID != latest || message.Inherited || message.Role != "assistant" || message.Status != "complete" && !live || message.NativeSessionID != "" && message.NativeSessionID != state.NativeSessionID {
			continue
		}
		if message.Status == "complete" && rendererTrim(message.Text) != "" || (live || status == "completed") && rendererTrim(message.Thinking) != "" || rendererCardPart(message, status) != nil {
			return message
		}
	}
	return nil
}
func rendererCardPart(message *Message, status string) *Part {
	live := rendererLive(status)
	eligible := func(part Part) bool {
		return (part.Type == "text" && message.Status == "complete" || part.Type == "reasoning" && (live || status == "completed")) && rendererTrim(part.Text) != ""
	}
	if live {
		for i := len(message.Parts) - 1; i >= 0; i-- {
			if message.Parts[i].Type == "text" && eligible(message.Parts[i]) {
				return &message.Parts[i]
			}
		}
	}
	for i := len(message.Parts) - 1; i >= 0; i-- {
		if eligible(message.Parts[i]) {
			return &message.Parts[i]
		}
	}
	return nil
}
func rendererReplyMessage(state *State) *Message {
	for i := len(state.Executions) - 1; i >= 0; i-- {
		execution := state.Executions[i]
		if execution.Status != "completed" {
			continue
		}
		for j := len(state.Messages) - 1; j >= 0; j-- {
			message := state.Messages[j]
			if message.ExecutionID == execution.ExecutionID && !message.Inherited && message.Role == "assistant" && message.Status == "complete" && rendererTrim(message.Text) != "" && (message.NativeSessionID == "" || message.NativeSessionID == state.NativeSessionID) {
				return message
			}
		}
	}
	return nil
}
func rendererCompactMessage(message *Message, preview, card, todo bool, usage Object, cardStatus string, source rendererSource) Object {
	var text any = ""
	if preview {
		limit := rendererPreview
		if message.Role == "user" {
			limit = rendererDirectoryPreview
		}
		text = rendererClip(rendererTrim(message.Text), limit)
	}
	result := Object{"id": message.ID, "executionId": message.ExecutionID, "role": message.Role, "text": text}
	for key, value := range map[string]string{"nativeSessionId": message.NativeSessionID, "status": message.Status, "model": message.Model, "provider": message.Provider, "variant": message.Variant} {
		if value != "" {
			result[key] = value
		}
	}
	if message.Inherited {
		result["inherited"] = true
	}
	if usage != nil {
		result["usage"] = usage
	}
	if card && (rendererLive(cardStatus) || cardStatus == "completed") && message.Thinking != "" {
		result["thinking"] = rendererClip(rendererTrim(message.Thinking), rendererPreview)
	}
	if card {
		if part := rendererCardPart(message, cardStatus); part != nil && part.Type != "tool" {
			value := rendererPart(*part)
			value["text"] = rendererClip(rendererTrim(part.Text), rendererPreview)
			result["parts"] = []Object{value}
		}
	}
	if todo {
		if source.messageHas(message, "toolName") {
			result["toolName"] = message.ToolName
		}
		todos := make([]Object, 0, min(32, len(message.Todos)))
		for _, item := range message.Todos[:min(32, len(message.Todos))] {
			value := clone(item)
			value["text"] = rendererClip(str(item["text"]), rendererDirectoryPreview)
			todos = append(todos, value)
		}
		result["todos"] = todos
	}
	return result
}
func rendererSumUsage(samples []Usage) Object {
	total := Object{"input": float64(0), "output": float64(0), "cacheRead": float64(0), "cacheWrite": float64(0), "reasoning": float64(0), "cost": float64(0)}
	for _, usage := range samples {
		for key, value := range map[string]float64{"input": usage.Input, "output": usage.Output, "cacheRead": usage.CacheRead, "cacheWrite": usage.CacheWrite, "reasoning": usage.Reasoning} {
			total[key] = number(total[key]) + value
		}
		if usage.Cost != nil {
			total["cost"] = number(total["cost"]) + *usage.Cost
		}
	}
	return total
}
func rendererCompactAuxiliary(samples []AuxiliaryUsage, source rendererSource) []Object {
	groups := make(map[string][]AuxiliaryUsage)
	order := make([]string, 0)
	for _, sample := range samples {
		if _, exists := groups[sample.ExecutionID]; !exists {
			order = append(order, sample.ExecutionID)
		}
		groups[sample.ExecutionID] = append(groups[sample.ExecutionID], sample)
	}
	result := make([]Object, 0, len(order))
	for _, id := range order {
		group := groups[id]
		last := group[len(group)-1]
		value := source.object("auxiliaryUsage", last.ExecutionID+"\x00"+last.ID, last)
		usages := make([]Usage, 0, len(group))
		for _, sample := range group {
			usages = append(usages, sample.Usage)
		}
		value["usage"] = rendererSumUsage(usages)
		result = append(result, value)
	}
	return result
}
func rendererCompactExecution(execution *model.PublicExecution, preview bool, source rendererSource) Object {
	result := source.object("executions", execution.ExecutionID, execution)
	delete(result, "summary")
	if execution.Summary != nil && *execution.Summary != "" && preview {
		result["summary"] = rendererClip(*execution.Summary, rendererDirectoryPreview)
	}
	if execution.Status == "failed" && execution.Error != nil && *execution.Error != "" {
		result["error"] = rendererClip(*execution.Error, rendererPreview)
	}
	return result
}
func rendererCompactForeground(foreground Object) Object {
	if foreground["kind"] != "reasoning" {
		return foreground
	}
	text := str(foreground["text"])
	points := []rune(text)
	if len(points) <= rendererPreview {
		return foreground
	}
	value := clone(foreground)
	offset := int64(number(foreground["textOffset"]))
	for _, point := range points[:len(points)-rendererPreview] {
		offset++
		if point > 0xffff {
			offset++
		}
	}
	value["text"], value["textOffset"] = string(points[len(points)-rendererPreview:]), offset
	return value
}
