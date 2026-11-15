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
func rendererPart(part Part) Object {
	if part.Type == "tool" {
		return Object{"type": "tool", "toolCallId": part.ToolCallID}
	}
	return Object{"type": part.Type, "ordinal": part.Ordinal, "text": part.Text}
}
func rendererParts(parts []Part) []Object {
	result := make([]Object, 0, len(parts))
	for _, part := range parts {
		result = append(result, rendererPart(part))
	}
	return result
}

// Every display body has exactly one projected field. Assistant text and
// reasoning are their ordered parts; user input is text; tool input/output are
// the renderer-owned display strings. Raw tool payloads stay in canonical state
// only so object insertion order and JSON spelling remain available here.
func rendererMessage(message *Message, source rendererSource) Object {
	result := Object{"id": message.ID, "executionId": message.ExecutionID, "role": message.Role}
	for key, value := range map[string]string{
		"nativeSessionId": message.NativeSessionID, "nativeMessageId": message.NativeMessageID,
		"status": message.Status, "model": message.Model, "provider": message.Provider, "variant": message.Variant,
		"presentation": message.Presentation,
	} {
		if value != "" {
			result[key] = value
		}
	}
	if message.CreatedAt != 0 {
		result["createdAt"] = message.CreatedAt
	}
	if message.FollowUp {
		result["followUp"] = true
	}
	if message.Inherited {
		result["inherited"] = true
	}
	if message.IsError {
		result["isError"] = true
	}
	if message.Usage != nil {
		result["usage"] = message.Usage
	}
	switch message.Role {
	case "user":
		result["text"] = message.Text
		if source.messageHasField(message.ID, "annotations") || message.Annotations != nil {
			result["annotations"] = message.Annotations
		}
		if source.messageHasField(message.ID, "attachments") || message.Attachments != nil {
			result["attachments"] = message.Attachments
		}
	case "assistant":
		result["parts"] = rendererParts(message.Parts)
	case "tool":
		result["toolCallId"] = message.ToolCallID
		if message.ToolName != "" {
			result["toolName"] = message.ToolName
		}
		if value, exists := rendererToolArguments(message, source); exists {
			result["argumentsDisplay"] = value
		}
		if value, exists := rendererToolResult(message, source); exists {
			result["resultDisplay"] = value
		}
		if source.messageHasField(message.ID, "todos") || message.Todos != nil {
			result["todos"] = message.Todos
		}
	}
	return result
}
func rendererToolArguments(message *Message, source rendererSource) (string, bool) {
	raw := source.field("messages", message.ID, "arguments")
	if raw == nil && message.Arguments == nil {
		return "", false
	}
	return rendererToolDisplay(raw, message.Arguments), true
}
func rendererToolResult(message *Message, source rendererSource) (string, bool) {
	if message.ToolError != nil {
		return strings.TrimSpace(contentText(message.Result) + "\n" + nativeFailure(message.ToolError)), true
	}
	raw := source.field("messages", message.ID, "result")
	if raw == nil && message.Result == nil {
		return "", false
	}
	if text := contentText(message.Result); text != "" {
		return text, true
	}
	return rendererToolDisplay(raw, message.Result), true
}
func rendererProjectedMessage(message *Message, source rendererSource) Object {
	return rendererMessage(message, source)
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
		return rendererMarshalProjection(rendererExecution(state, base, scope, source))
	}
	return rendererMarshalProjection(rendererDirectory(state, base, scope, source))
}

func rendererExecution(state *State, base Object, scope model.RendererScope, source rendererSource) Object {
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
	nonempty := make([]Object, 0)
	hide := func(id, field, text string) string {
		if rendererNativeNonempty(text) {
			nonempty = append(nonempty, Object{"id": id, "field": field})
		}
		return ""
	}
	projected := make([]Object, 0, len(messages))
	for _, message := range messages {
		// Error bodies, including child-session errors, are visible even when
		// execution work is collapsed and no full execution resource is loaded.
		if !deferred || message.IsError || message.Status == "failed" {
			projected = append(projected, rendererProjectedMessage(message, source))
			continue
		}
		child := message.NativeSessionID != "" && primary != "" && message.NativeSessionID != primary
		body := rendererMessage(message, source)
		if message.Role == "user" && !child {
			projected = append(projected, body)
			continue
		}
		// Child prompts reveal the same execution work as tool input/output and
		// stay behind the full resource even though the parent prompt is visible.
		// Tool messages have no aggregate text under the one-body schema.
		if text, exists := body["text"].(string); exists && message.Role != "assistant" {
			body["text"] = hide(message.ID, "text", text)
		}
		if message.Role == "tool" {
			// Tool bodies have no aggregate text under the one-body schema. Mark
			// each hidden producer-rendered display so presence still reflects
			// what the deferred row omitted.
			for _, field := range []string{"argumentsDisplay", "resultDisplay"} {
				if text, ok := body[field].(string); ok && rendererNativeNonempty(text) {
					nonempty = append(nonempty, Object{"id": message.ID, "field": field})
				}
			}
		}
		for _, key := range []string{"argumentsDisplay", "resultDisplay", "todos", "annotations", "attachments"} {
			delete(body, key)
		}
		// Assistant replies, including those accompanying a child-session error,
		// remain readable without a full work lease. Tool/reasoning bodies do not.
		reading := message.Role == "assistant"
		if reading && message.Parts != nil {
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
		return Object{"kind": "deferred-execution", "state": base, "nonempty": nonempty}
	}
	return base
}

func rendererDirectory(state *State, base Object, scope model.RendererScope, source rendererSource) Object {
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
				if message.Role == "assistant" && rendererTrim(messageText(message)) != "" {
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
		executions = append(executions, rendererCompactExecution(execution, source))
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
	return base
}

func rendererLive(status string) bool { return status == "running" || status == "waiting-for-user" }
func rendererCardMessage(state *State, latest, status string) *Message {
	live := rendererLive(status)
	for i := len(state.Messages) - 1; i >= 0; i-- {
		message := state.Messages[i]
		if message.ExecutionID != latest || message.Inherited || message.Role != "assistant" || message.Status != "complete" && !live || message.NativeSessionID != "" && message.NativeSessionID != state.NativeSessionID {
			continue
		}
		text, thinking := messageText(message), messageThinking(message)
		if message.Status == "complete" && rendererTrim(text) != "" || (live || status == "completed") && rendererTrim(thinking) != "" || rendererCardPart(message, status) != nil {
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
			if message.ExecutionID == execution.ExecutionID && !message.Inherited && message.Role == "assistant" && message.Status == "complete" && rendererTrim(messageText(message)) != "" && (message.NativeSessionID == "" || message.NativeSessionID == state.NativeSessionID) {
				return message
			}
		}
	}
	return nil
}
func rendererCompactMessage(message *Message, preview, card, todo bool, usage Object, cardStatus string, source rendererSource) Object {
	var cardPart *Part
	if card {
		// rendererCardPart returns only text or reasoning parts.
		cardPart = rendererCardPart(message, cardStatus)
	}
	// A selected text part replaces the bounded preview because it is the same
	// body. A reasoning part is additional detail on a settled card, so keep the
	// text preview; [text, reasoning] must not hide the answer. Live and
	// reasoning-only cards still carry their exact part.
	partBody := cardPart != nil && (message.Status != "complete" || cardPart.Type == "reasoning")
	var text any = ""
	if preview && !(partBody && cardPart.Type == "text") {
		limit := rendererPreview
		if message.Role == "user" {
			limit = rendererDirectoryPreview
		}
		text = rendererClip(rendererTrim(messageText(message)), limit)
	}
	result := Object{"id": message.ID, "executionId": message.ExecutionID, "role": message.Role}
	if message.Role != "tool" {
		result["text"] = text
	}
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
	if partBody {
		value := rendererPart(*cardPart)
		value["text"] = rendererClip(rendererTrim(cardPart.Text), rendererPreview)
		result["parts"] = []Object{value}
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
func rendererCompactExecution(execution *model.PublicExecution, source rendererSource) Object {
	result := source.object("executions", execution.ExecutionID, execution)
	delete(result, "summary")
	if execution.Summary != nil && *execution.Summary != "" {
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
