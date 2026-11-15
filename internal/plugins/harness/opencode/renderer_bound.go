package opencode

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"unicode/utf8"
)

// The transport rejects one encoded content event above 32 MiB. Leave room for
// the event envelope and JSON escaping so an oversized conversation can still
// open with a bounded projection. The persisted native state is never changed.
const (
	rendererWireBudget         = 24 << 20
	rendererMaxPublicIdentity  = 128
	rendererMaxMessageIdentity = 256
	rendererMaxNativeIdentity  = 512
	rendererMaxPresenceField   = 256
	rendererDropFieldSize      = 64 << 10
	rendererTruncationNote     = "[Content omitted or truncated for transport; full content remains in the saved conversation.]"
)

const rendererTruncationSuffix = "\n\n[Truncated for transport; full content remains in the saved conversation.]"

type rendererLimits struct {
	text, tool, short        int
	parts                    int
	messages, messageHead    int
	executions, interactions int
	nonemptyBudget           int
	dropOptional             bool
}

var rendererStages = []rendererLimits{
	{
		text: 512 << 10, tool: 256 << 10, short: 16 << 10,
		parts: 256, executions: 1000, interactions: 200,
		nonemptyBudget: 2 << 20,
	},
	{
		text: 8 << 10, tool: 8 << 10, short: 2 << 10,
		parts: 16, messages: 2000, messageHead: 100,
		executions: 200, interactions: 32,
		nonemptyBudget: 512 << 10, dropOptional: true,
	},
	{
		text: 2 << 10, tool: 2 << 10, short: 512,
		parts: 8, messages: 500, messageHead: 20,
		executions: 100, interactions: 8,
		nonemptyBudget: 128 << 10, dropOptional: true,
	},
	{
		text: 512, tool: 512, short: 256,
		parts: 4, messages: 10,
		executions: 1, interactions: 1,
		nonemptyBudget: 16 << 10, dropOptional: true,
	},
}

func rendererMarshalProjection(value Object) (json.RawMessage, error) {
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) <= rendererWireBudget {
		return encoded, err
	}
	state := rendererProjectionState(value)
	originalNonempty := rendererObjects(value["nonempty"])
	rendererMarkTruncated(state)
	for _, limits := range rendererStages {
		rendererApplyLimits(value, state, originalNonempty, limits)
		encoded, err = json.Marshal(value)
		if err != nil {
			return nil, err
		}
		if len(encoded) <= rendererWireBudget {
			return encoded, nil
		}
	}
	if len(rendererPendingInteractionIDs(state)) > 0 {
		return nil, fmt.Errorf("OpenCode pending interaction exceeds the renderer transport budget without changing its response contract")
	}
	// The envelope itself is checked again after every stage. This final shape
	// is deliberately tiny and valid even when every retained field is hostile.
	minimal, err := json.Marshal(rendererMinimalProjection(state))
	if err != nil {
		return nil, err
	}
	if len(minimal) > rendererWireBudget {
		return nil, fmt.Errorf("OpenCode projection fallback exceeds the transport budget")
	}
	return minimal, nil
}

func rendererProjectionState(value Object) Object {
	if value["kind"] == "deferred-execution" {
		if state, ok := value["state"].(Object); ok {
			return state
		}
	}
	return value
}

func rendererMarkTruncated(state Object) {
	state["contentTruncated"] = true
}

func rendererApplyLimits(value, state Object, originalNonempty []Object, limits rendererLimits) {
	rendererLimitMessages(state, limits.messages, limits.messageHead)
	rendererBoundMessages(state, limits)
	rendererBoundTopInteractions(state, limits)
	rendererBoundExecutions(state, limits)
	rendererBoundTopLevel(state, limits)
	// Interaction values are a response contract, not display text. A generic
	// tree clamp would rewrite form keys, options, defaults and conditions after
	// the paired native/public representations have been bounded.
	for key, item := range state {
		if key != "interactions" && key != "executions" {
			state[key] = rendererClampTree(item, limits.text)
		}
	}
	rendererFilterNonempty(value, state, originalNonempty, limits.nonemptyBudget)
}

func rendererLimitMessages(state Object, limit, head int) {
	if limit <= 0 {
		return
	}
	messages := rendererObjects(state["messages"])
	if len(messages) <= limit {
		state["messages"] = messages
		return
	}
	if head <= 0 || head >= limit {
		state["messages"] = append([]Object(nil), messages[len(messages)-limit:]...)
		return
	}
	limited := make([]Object, 0, limit)
	limited = append(limited, messages[:head]...)
	limited = append(limited, messages[len(messages)-(limit-head):]...)
	state["messages"] = limited
}

func rendererBoundMessages(state Object, limits rendererLimits) {
	messages := rendererObjects(state["messages"])
	bound := make([]Object, 0, len(messages))
	for _, message := range messages {
		if rendererBoundMessage(message, limits) {
			bound = append(bound, message)
		}
	}
	state["messages"] = bound
}

func rendererBoundMessage(message Object, limits rendererLimits) bool {
	role := rendererText(message["role"])
	if !rendererOneOf(role, "assistant", "user", "tool") {
		return false
	}
	id, ok := rendererTextIdentity(rendererText(message["id"]), rendererMaxMessageIdentity)
	if !ok {
		return false
	}
	executionID, ok := rendererPublicIdentity(rendererText(message["executionId"]))
	if !ok {
		return false
	}
	message["id"], message["executionId"] = id, executionID
	if value, exists := message["nativeSessionId"]; exists {
		native, ok := rendererTextIdentity(rendererText(value), rendererMaxNativeIdentity)
		if !ok {
			return false
		}
		message["nativeSessionId"] = native
	}
	if value, exists := message["nativeMessageId"]; exists {
		if native, ok := rendererTextIdentity(rendererText(value), rendererMaxNativeIdentity); ok {
			message["nativeMessageId"] = native
		} else {
			delete(message, "nativeMessageId")
		}
	}
	if value, exists := message["toolCallId"]; exists {
		toolCallID, ok := rendererTextIdentity(rendererText(value), rendererMaxMessageIdentity)
		if !ok {
			return false
		}
		message["toolCallId"] = toolCallID
	}
	for _, key := range []string{"toolName", "model", "provider", "variant"} {
		if value, exists := message[key]; exists {
			message[key] = rendererBoundText(value, limits.short)
		}
	}
	if value, exists := message["status"]; exists {
		if status := rendererText(value); rendererOneOf(status, "streaming", "complete", "failed", "cancelled") {
			message["status"] = status
		} else {
			delete(message, "status")
		}
	}
	if value, exists := message["presentation"]; exists {
		if presentation := rendererText(value); rendererOneOf(presentation, "ordinary", "internal") {
			message["presentation"] = presentation
		} else {
			delete(message, "presentation")
		}
	}
	message["text"] = rendererBoundText(message["text"], limits.text)
	if value, exists := message["thinking"]; exists {
		message["thinking"] = rendererBoundText(value, limits.text)
	}
	if value, exists := message["parts"]; exists {
		parts := rendererObjects(value)
		trimmed := make([]Object, 0, len(parts))
		for _, part := range parts {
			if rendererBoundPart(part, limits) {
				trimmed = append(trimmed, part)
			}
		}
		if len(trimmed) > limits.parts {
			trimmed = trimmed[len(trimmed)-limits.parts:]
		}
		message["parts"] = trimmed
	}
	if role == "tool" {
		if rendererText(message["toolCallId"]) == "" {
			return false
		}
		message["text"] = rendererBoundText(message["text"], limits.tool)
		if rendererText(message["text"]) != "" {
			delete(message, "result")
			delete(message, "resultDisplay")
		} else {
			rendererBoundToolField(message, "result", limits.tool)
		}
		rendererBoundToolField(message, "arguments", limits.tool)
	}
	if limits.dropOptional {
		delete(message, "metadata")
		delete(message, "todos")
		delete(message, "annotations")
		delete(message, "attachments")
	} else {
		rendererDropLargeField(message, "metadata")
		rendererDropLargeField(message, "todos")
		rendererDropLargeField(message, "annotations")
		rendererDropLargeField(message, "attachments")
	}
	if value, exists := message["usage"]; exists && rendererEncodedSize(value) > limits.short {
		delete(message, "usage")
	}
	return true
}

func rendererBoundPart(part Object, limits rendererLimits) bool {
	kind := rendererText(part["type"])
	if !rendererOneOf(kind, "text", "reasoning", "tool") {
		kind = "text"
	}
	part["type"] = kind
	if kind == "tool" {
		toolCallID, ok := rendererTextIdentity(rendererText(part["toolCallId"]), rendererMaxMessageIdentity)
		if !ok {
			return false
		}
		part["toolCallId"] = toolCallID
		delete(part, "ordinal")
		delete(part, "text")
		return true
	}
	ordinal, ok := rendererInteger(part["ordinal"])
	if !ok || ordinal < 0 {
		ordinal = 0
	}
	part["ordinal"] = ordinal
	delete(part, "toolCallId")
	part["text"] = rendererBoundText(part["text"], limits.text)
	return true
}

func rendererBoundToolField(message Object, key string, limit int) {
	value, exists := message[key]
	if !exists {
		return
	}
	size := rendererEncodedSize(value)
	if size <= limit {
		if display, ok := message[key+"Display"]; ok && rendererEncodedSize(display) > limit {
			message[key] = rendererTruncationMarker(size)
			delete(message, key+"Display")
		}
		return
	}
	message[key] = rendererTruncationMarker(size)
	delete(message, key+"Display")
}

func rendererDropLargeField(object Object, key string) {
	if value, exists := object[key]; exists && rendererEncodedSize(value) > rendererDropFieldSize {
		delete(object, key)
	}
}

func rendererBoundExecutions(state Object, limits rendererLimits) {
	latest := rendererLatestExecutionID(state)
	executions := rendererObjects(state["executions"])
	executions = rendererTrimExecutions(executions, latest, limits.executions)
	pending := rendererPendingInteractionIDs(state)
	bound := make([]Object, 0, len(executions))
	for _, execution := range executions {
		if next, ok := rendererBoundExecution(execution, limits, pending); ok {
			bound = append(bound, next)
		}
	}
	state["executions"] = bound
	found := false
	for _, execution := range bound {
		if rendererText(execution["executionId"]) == latest {
			found = true
			break
		}
	}
	if latest != "" && found {
		state["latestExecutionId"] = latest
	} else {
		state["latestExecutionId"] = nil
	}
}

func rendererTrimExecutions(executions []Object, latest string, limit int) []Object {
	if limit <= 0 {
		return nil
	}
	if len(executions) <= limit {
		return executions
	}
	tail := len(executions) - limit
	if latest == "" {
		return append([]Object(nil), executions[tail:]...)
	}
	latestIndex := -1
	for index, execution := range executions {
		if rendererText(execution["executionId"]) == latest {
			latestIndex = index
			break
		}
	}
	if latestIndex < 0 {
		return append([]Object(nil), executions[tail:]...)
	}
	if latestIndex >= tail {
		return append([]Object(nil), executions[tail:]...)
	}
	trimmed := make([]Object, 0, limit)
	for index, execution := range executions {
		if index == latestIndex || index > tail {
			trimmed = append(trimmed, execution)
		}
	}
	return trimmed
}

func rendererPendingInteractionIDs(state Object) map[string]bool {
	pending := map[string]bool{}
	for _, interaction := range rendererObjects(state["interactions"]) {
		if rendererText(interaction["status"]) != "pending" {
			continue
		}
		executionID, executionOK := rendererPublicIdentity(rendererText(interaction["executionId"]))
		id, idOK := rendererTextIdentity(rendererText(interaction["id"]), rendererMaxMessageIdentity)
		if executionOK && idOK {
			pending[opaque("interaction", executionID, id)] = true
		}
	}
	return pending
}

func rendererBoundExecution(execution Object, limits rendererLimits, pending map[string]bool) (Object, bool) {
	executionID, ok := rendererPublicIdentity(rendererText(execution["executionId"]))
	if !ok {
		return nil, false
	}
	status := rendererText(execution["status"])
	if !rendererOneOf(status, "running", "waiting-for-user", "completed", "failed", "interrupted") {
		status = "failed"
	}
	started, ok := rendererNumber(execution["startedAt"])
	if !ok || started < 0 {
		started = 0
	}
	next := Object{"executionId": executionID, "status": status, "startedAt": started}
	if value, exists := execution["summary"]; exists {
		next["summary"] = rendererBoundText(value, limits.short)
	}
	switch status {
	case "running":
	case "waiting-for-user":
		interactions := rendererObjects(execution["interactions"])
		bound := make([]Object, 0, len(interactions))
		for _, interaction := range interactions {
			if value, ok := rendererBoundPublicInteraction(interaction, limits); ok {
				bound = append(bound, value)
			}
		}
		if len(pending) > 0 {
			matched := make([]Object, 0, len(bound))
			for _, interaction := range bound {
				if pending[rendererText(interaction["id"])] {
					matched = append(matched, interaction)
				}
			}
			bound = matched
		}
		if len(bound) > limits.interactions {
			bound = bound[:limits.interactions]
		}
		if len(bound) == 0 {
			// An omitted interaction cannot turn the authoritative execution
			// into a synthetic failure. Omit this row with the surface notice.
			return nil, false
		}
		next["interactions"] = bound
	case "failed":
		finished, ok := rendererNumber(execution["finishedAt"])
		if !ok || finished < started {
			finished = started
		}
		next["finishedAt"] = finished
		text := rendererBoundText(execution["error"], limits.short)
		if text == "" {
			text = rendererTruncationNote
		}
		next["error"] = text
	default:
		finished, ok := rendererNumber(execution["finishedAt"])
		if !ok || finished < started {
			finished = started
		}
		next["finishedAt"] = finished
	}
	return next, true
}

func rendererBoundPublicInteraction(interaction Object, limits rendererLimits) (Object, bool) {
	kind := rendererText(interaction["kind"])
	if !rendererOneOf(kind, "permission", "question") {
		return nil, false
	}
	id, ok := rendererPublicIdentity(rendererText(interaction["id"]))
	if !ok {
		return nil, false
	}
	next := Object{
		"id":    id,
		"kind":  kind,
		"title": rendererNonblankText(interaction["title"], min(limits.short, 2_000), "OpenCode interaction"),
	}
	if value, exists := interaction["description"]; exists {
		next["description"] = rendererBoundText(value, limits.short)
	}
	actions := rendererObjects(interaction["actions"])
	boundActions := make([]Object, 0, len(actions))
	for _, action := range actions {
		id, ok := rendererPublicIdentity(rendererText(action["id"]))
		if !ok {
			continue
		}
		intent := rendererText(action["intent"])
		if !rendererOneOf(intent, "allow", "deny", "submit", "cancel") {
			return nil, false
		}
		boundActions = append(boundActions, Object{
			"id":     id,
			"intent": intent,
			"label":  rendererNonblankText(action["label"], min(limits.short, 2_000), "Action"),
		})
	}
	if len(boundActions) == 0 {
		return nil, false
	}
	next["actions"] = boundActions
	questions := rendererObjects(interaction["questions"])
	boundQuestions := make([]Object, 0, len(questions))
	for _, question := range questions {
		if value, ok := rendererBoundQuestion(question, limits); ok {
			boundQuestions = append(boundQuestions, value)
		}
	}
	next["questions"] = boundQuestions
	return next, true
}

func rendererBoundQuestion(question Object, limits rendererLimits) (Object, bool) {
	id, ok := rendererPublicIdentity(rendererText(question["id"]))
	if !ok {
		return nil, false
	}
	next := Object{
		"id":         id,
		"prompt":     rendererNonblankText(question["prompt"], limits.short, "OpenCode question"),
		"multiple":   rendererBool(question["multiple"]),
		"allowOther": rendererBool(question["allowOther"]),
		"secret":     rendererBool(question["secret"]),
	}
	if value, exists := question["header"]; exists {
		next["header"] = rendererBoundText(value, min(limits.short, 2_000))
	}
	if value, exists := question["answerFormat"]; exists {
		if format := rendererText(value); format == "json-object" {
			next["answerFormat"] = format
		}
	}
	if value, exists := question["form"]; exists {
		next["form"] = value
	}
	options := rendererObjects(question["options"])
	boundOptions := make([]Object, 0, len(options))
	for _, option := range options {
		boundOptions = append(boundOptions, Object{
			"value":       option["value"],
			"label":       rendererNonblankText(option["label"], 2_000, "Option"),
			"description": rendererOptionalText(option["description"], min(limits.short, 10_000)),
		})
	}
	next["options"] = boundOptions
	return next, true
}

func rendererBoundTopInteractions(state Object, limits rendererLimits) {
	interactions := rendererObjects(state["interactions"])
	bound := make([]Object, 0, len(interactions))
	for _, interaction := range interactions {
		if value, ok := rendererBoundNativeInteraction(interaction, limits); ok {
			bound = append(bound, value)
		}
	}
	pending := make([]Object, 0, len(bound))
	other := make([]Object, 0, len(bound))
	for _, interaction := range bound {
		if rendererText(interaction["status"]) == "pending" {
			pending = append(pending, interaction)
		} else {
			other = append(other, interaction)
		}
	}
	if len(pending) > limits.interactions {
		pending = pending[len(pending)-limits.interactions:]
	}
	if room := limits.interactions - len(pending); room > 0 {
		if len(other) > room {
			other = other[len(other)-room:]
		}
		pending = append(pending, other...)
	}
	state["interactions"] = pending
}

func rendererBoundNativeInteraction(interaction Object, limits rendererLimits) (Object, bool) {
	kind := rendererText(interaction["kind"])
	if !rendererOneOf(kind, "permission", "form") {
		return nil, false
	}
	id, ok := rendererTextIdentity(rendererText(interaction["id"]), rendererMaxMessageIdentity)
	if !ok {
		return nil, false
	}
	executionID, ok := rendererPublicIdentity(rendererText(interaction["executionId"]))
	if !ok {
		return nil, false
	}
	sessionID, ok := rendererTextIdentity(rendererText(interaction["sessionId"]), rendererMaxNativeIdentity)
	if !ok {
		return nil, false
	}
	status := rendererText(interaction["status"])
	if !rendererOneOf(status, "pending", "answered", "cancelled") {
		status = "cancelled"
	}
	next := Object{
		"id":          id,
		"executionId": executionID,
		"sessionId":   sessionID,
		"kind":        kind,
		"title":       rendererNonblankText(interaction["title"], limits.short, "OpenCode request"),
		"status":      status,
	}
	if kind == "permission" {
		next["action"] = interaction["action"]
		next["resources"] = []string{}
		for _, key := range []string{"resources", "save"} {
			if value, exists := interaction[key]; exists {
				next[key] = value
			}
		}
		if value, exists := interaction["description"]; exists {
			next["description"] = rendererBoundText(value, limits.short)
		}
	} else {
		fields := rendererObjects(interaction["fields"])
		boundFields := make([]Object, 0, len(fields))
		for _, field := range fields {
			if value, ok := rendererBoundFormField(field, limits); ok {
				boundFields = append(boundFields, value)
			}
		}
		if len(boundFields) == 0 {
			return nil, false
		}
		next["fields"] = boundFields
	}
	if value, exists := interaction["metadata"]; exists && !limits.dropOptional && rendererEncodedSize(value) <= rendererDropFieldSize {
		next["metadata"] = value
	}
	return next, true
}

func rendererBoundFormField(field Object, limits rendererLimits) (Object, bool) {
	kind, key := rendererText(field["type"]), rendererText(field["key"])
	if !rendererOneOf(kind, "string", "number", "integer", "boolean", "multiselect", "external") || key == "" || strings.ContainsRune(key, 0) {
		return nil, false
	}
	// Core derives response IDs and validates answers from these exact values.
	// Retain the complete contract, even when it alone exceeds a stage's text
	// allowance. The whole-envelope budget then fails explicitly if necessary.
	next := Object{"type": kind, "key": key}
	for _, name := range []string{"required", "pattern", "format", "custom", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "hidden", "default", "url", "when"} {
		if value, exists := field[name]; exists {
			next[name] = value
		}
	}
	for _, name := range []string{"title", "description", "placeholder"} {
		if value, exists := field[name]; exists {
			next[name] = rendererBoundText(value, limits.short)
		}
	}
	if raw, exists := field["options"]; exists {
		options := rendererObjects(raw)
		bound := make([]Object, 0, len(options))
		for _, option := range options {
			nextOption := Object{"value": option["value"], "label": rendererBoundText(option["label"], 2_000)}
			if description, exists := option["description"]; exists {
				nextOption["description"] = rendererBoundText(description, limits.short)
			}
			bound = append(bound, nextOption)
		}
		next["options"] = bound
	}
	return next, true
}

func rendererBoundTopLevel(state Object, limits rendererLimits) {
	delete(state, "contentTruncated")
	state["contentTruncated"] = true
	if value, exists := state["nativeSessionId"]; exists {
		if native, ok := rendererTextIdentity(rendererText(value), rendererMaxNativeIdentity); ok {
			state["nativeSessionId"] = native
		} else {
			delete(state, "nativeSessionId")
		}
	}
	if value, exists := state["nativeSessionCreated"]; exists {
		if rendererBool(value) {
			if _, hasSession := state["nativeSessionId"]; hasSession {
				state["nativeSessionCreated"] = true
			} else {
				delete(state, "nativeSessionCreated")
			}
		} else {
			delete(state, "nativeSessionCreated")
		}
	}
	if value, exists := state["initialResponseScope"]; exists {
		if rendererBool(value) {
			state["initialResponseScope"] = true
		} else {
			delete(state, "initialResponseScope")
		}
	}
	if value, exists := state["backgroundSessions"]; exists {
		state["backgroundSessions"] = rendererBoundBackgroundSessions(value)
	}
	if value, exists := state["backgroundShells"]; exists {
		state["backgroundShells"] = rendererBoundBackgroundShells(value)
	}
	if value, exists := state["executionAuthors"]; exists {
		state["executionAuthors"] = rendererBoundAuthors(value, state, limits)
	}
	if value, exists := state["foregrounds"]; exists {
		state["foregrounds"] = rendererBoundForegrounds(value, limits)
	}
	if value, exists := state["auxiliaryUsage"]; exists {
		state["auxiliaryUsage"] = rendererBoundAuxiliaryUsage(value, limits)
	}
	if value, exists := state["forkSource"]; exists {
		if fork, ok := rendererBoundForkSource(value, limits); ok {
			state["forkSource"] = fork
		} else {
			delete(state, "forkSource")
		}
	}
}

func rendererBoundBackgroundSessions(value any) []Object {
	var source []BackgroundSession
	switch typed := value.(type) {
	case []BackgroundSession:
		source = typed
	default:
		for _, item := range rendererArrayValues(value) {
			object, ok := item.(Object)
			if !ok {
				continue
			}
			source = append(source, BackgroundSession{SessionID: rendererText(object["sessionId"]), Status: rendererText(object["status"])})
		}
	}
	if len(source) > 32 {
		source = source[len(source)-32:]
	}
	result := make([]Object, 0, len(source))
	for _, item := range source {
		sessionID, ok := rendererTextIdentity(item.SessionID, rendererMaxNativeIdentity)
		if !ok {
			continue
		}
		status := item.Status
		if !rendererOneOf(status, "running", "idle") {
			status = "idle"
		}
		result = append(result, Object{"sessionId": sessionID, "status": status})
	}
	return result
}

func rendererBoundBackgroundShells(value any) []Object {
	var source []BackgroundShell
	switch typed := value.(type) {
	case []BackgroundShell:
		source = typed
	default:
		for _, item := range rendererArrayValues(value) {
			object, ok := item.(Object)
			if !ok {
				continue
			}
			source = append(source, BackgroundShell{ShellID: rendererText(object["shellId"]), SessionID: rendererText(object["sessionId"]), Status: rendererText(object["status"])})
		}
	}
	if len(source) > 32 {
		source = source[len(source)-32:]
	}
	result := make([]Object, 0, len(source))
	for _, item := range source {
		shellID, shellOK := rendererTextIdentity(item.ShellID, rendererMaxNativeIdentity)
		sessionID, sessionOK := rendererTextIdentity(item.SessionID, rendererMaxNativeIdentity)
		if !shellOK || !sessionOK {
			continue
		}
		status := item.Status
		if !rendererOneOf(status, "running", "idle") {
			status = "idle"
		}
		result = append(result, Object{"shellId": shellID, "sessionId": sessionID, "status": status})
	}
	return result
}

func rendererBoundAuthors(value any, state Object, limits rendererLimits) map[string]Object {
	source := map[string]Object{}
	switch typed := value.(type) {
	case map[string]Object:
		for key, item := range typed {
			source[key] = item
		}
	case map[string]any:
		for key, item := range typed {
			if object, ok := item.(Object); ok {
				source[key] = object
			}
		}
	}
	retained := map[string]bool{}
	for _, execution := range rendererObjects(state["executions"]) {
		if id, ok := rendererPublicIdentity(rendererText(execution["executionId"])); ok {
			retained[id] = true
		}
	}
	keys := make([]string, 0, len(source))
	for key := range source {
		if retained[key] {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	limit := max(limits.executions, 8)
	if len(keys) > limit {
		keys = keys[len(keys)-limit:]
	}
	result := make(map[string]Object, len(keys))
	for _, key := range keys {
		item := source[key]
		author := Object{}
		for _, name := range []string{"model", "effort"} {
			if field, exists := item[name]; exists {
				if text := rendererBoundText(field, 4_096); strings.TrimSpace(text) != "" {
					author[name] = text
				}
			}
		}
		if len(author) > 0 {
			result[key] = author
		}
	}
	return result
}

func rendererBoundForegrounds(value any, limits rendererLimits) []Object {
	foregrounds := rendererObjects(value)
	if len(foregrounds) > limits.interactions {
		foregrounds = foregrounds[len(foregrounds)-limits.interactions:]
	}
	result := make([]Object, 0, len(foregrounds))
	for _, entry := range foregrounds {
		executionID, ok := rendererPublicIdentity(rendererText(entry["executionId"]))
		if !ok {
			continue
		}
		foreground, ok := entry["foreground"].(Object)
		if !ok {
			continue
		}
		kind := rendererText(foreground["kind"])
		if !rendererOneOf(kind, "reasoning", "assistant-text", "tool-call") {
			continue
		}
		body := Object{"kind": kind}
		if sequence, ok := rendererInteger(foreground["sequence"]); ok && sequence >= 1 {
			body["sequence"] = sequence
		} else {
			continue
		}
		switch kind {
		case "reasoning":
			body["text"] = rendererTruncateUTF16(rendererText(foreground["text"]), 32_768)
			if offset, ok := rendererInteger(foreground["textOffset"]); ok && offset >= 0 {
				body["textOffset"] = offset
			}
		case "tool-call":
			callID, ok := rendererTextIdentity(rendererText(foreground["callId"]), rendererMaxMessageIdentity)
			if !ok {
				continue
			}
			body["callId"] = callID
			body["toolName"] = rendererNonblankText(foreground["toolName"], 64, "tool")
		}
		next := Object{"executionId": executionID, "foreground": body}
		if segment, exists := entry["segmentId"]; exists {
			next["segmentId"] = rendererBoundText(segment, limits.short)
		}
		result = append(result, next)
	}
	return result
}

func rendererBoundAuxiliaryUsage(value any, limits rendererLimits) []Object {
	samples := rendererObjects(value)
	if len(samples) > limits.interactions {
		samples = samples[len(samples)-limits.interactions:]
	}
	result := make([]Object, 0, len(samples))
	for _, sample := range samples {
		if rendererText(sample["kind"]) != "compaction" {
			continue
		}
		createdAt, ok := rendererNumber(sample["createdAt"])
		if !ok || createdAt < 0 {
			continue
		}
		usage, exists := sample["usage"]
		if !exists || rendererEncodedSize(usage) > limits.short {
			continue
		}
		id, idOK := rendererTextIdentity(rendererText(sample["id"]), rendererMaxMessageIdentity)
		nativeSessionID, nativeOK := rendererTextIdentity(rendererText(sample["nativeSessionId"]), rendererMaxNativeIdentity)
		executionID, executionOK := rendererPublicIdentity(rendererText(sample["executionId"]))
		if !idOK || !nativeOK || !executionOK {
			continue
		}
		next := Object{
			"id":              id,
			"nativeSessionId": nativeSessionID,
			"executionId":     executionID,
			"kind":            "compaction",
			"createdAt":       createdAt,
			"usage":           usage,
		}
		for _, name := range []string{"provider", "model"} {
			if field, exists := sample[name]; exists {
				if text := rendererBoundText(field, limits.short); strings.TrimSpace(text) != "" {
					next[name] = text
				}
			}
		}
		result = append(result, next)
	}
	return result
}

func rendererBoundForkSource(value any, limits rendererLimits) (Object, bool) {
	source, ok := value.(Object)
	if !ok {
		return nil, false
	}
	sessionID, ok := rendererTextIdentity(rendererText(source["sessionId"]), rendererMaxNativeIdentity)
	if !ok {
		return nil, false
	}
	next := Object{"sessionId": sessionID, "transcript": Object{}}
	if messageID, exists := source["messageId"]; exists {
		if text, ok := rendererTextIdentity(rendererText(messageID), rendererMaxNativeIdentity); ok {
			next["messageId"] = text
		}
	}
	return next, true
}

func rendererFilterNonempty(value, state Object, original []Object, budget int) {
	if value["kind"] != "deferred-execution" {
		return
	}
	retained := map[string]bool{}
	for _, message := range rendererObjects(state["messages"]) {
		if id := rendererText(message["id"]); id != "" {
			retained[id] = true
		}
	}
	entries := make([]Object, 0)
	used := 2
	for index := len(original) - 1; index >= 0; index-- {
		entry := original[index]
		id, field := rendererText(entry["id"]), rendererText(entry["field"])
		if !retained[id] || !rendererValidPresenceField(field) {
			continue
		}
		next := Object{"id": id, "field": field}
		size := rendererEncodedSize(next) + 1
		if used+size > budget {
			break
		}
		entries = append(entries, next)
		used += size
	}
	for left, right := 0, len(entries)-1; left < right; left, right = left+1, right-1 {
		entries[left], entries[right] = entries[right], entries[left]
	}
	value["nonempty"] = entries
}

func rendererValidPresenceField(field string) bool {
	if field == "" || len(field) > rendererMaxPresenceField || strings.ContainsRune(field, 0) {
		return false
	}
	return field == "text" || field == "thinking" || strings.HasPrefix(field, "parts:")
}

func rendererMinimalProjection(state Object) Object {
	minimal := Object{
		"version":           1,
		"messages":          []Object{},
		"executions":        []Object{},
		"latestExecutionId": nil,
		"interactions":      []Object{},
		"contentTruncated":  true,
	}
	executions := rendererObjects(state["executions"])
	if len(executions) > 20 {
		executions = append(append([]Object(nil), executions[:10]...), executions[len(executions)-10:]...)
	}
	tiny := make([]Object, 0, len(executions))
	for _, execution := range executions {
		if value, ok := rendererBoundExecution(execution, rendererStages[len(rendererStages)-1], nil); ok {
			tiny = append(tiny, value)
		}
	}
	if len(tiny) > 0 {
		minimal["executions"] = tiny
	}
	latest := rendererLatestExecutionID(state)
	for _, execution := range tiny {
		if rendererText(execution["executionId"]) == latest {
			minimal["latestExecutionId"] = latest
			break
		}
	}
	return minimal
}

func rendererLatestExecutionID(state Object) string {
	var value string
	switch current := state["latestExecutionId"].(type) {
	case string:
		value = current
	case *string:
		if current == nil {
			return ""
		}
		value = *current
	default:
		return ""
	}
	id, _ := rendererPublicIdentity(value)
	return id
}

func rendererObjects(value any) []Object {
	switch values := value.(type) {
	case []Object:
		return values
	case []any:
		result := make([]Object, 0, len(values))
		for _, item := range values {
			if object, ok := item.(Object); ok {
				result = append(result, object)
			}
		}
		return result
	default:
		return nil
	}
}

func rendererArrayValues(value any) []any {
	switch values := value.(type) {
	case []any:
		return values
	case []Object:
		result := make([]any, 0, len(values))
		for _, item := range values {
			result = append(result, item)
		}
		return result
	case []string:
		result := make([]any, 0, len(values))
		for _, item := range values {
			result = append(result, item)
		}
		return result
	default:
		return nil
	}
}

func rendererClampTree(value any, limit int) any {
	switch typed := value.(type) {
	case string:
		return rendererTruncateText(typed, limit)
	case Object:
		for key, item := range typed {
			typed[key] = rendererClampTree(item, limit)
		}
		return typed
	case map[string]Object:
		for key, item := range typed {
			typed[key] = rendererClampTree(item, limit).(Object)
		}
		return typed
	case map[string]string:
		for key, item := range typed {
			typed[key] = rendererTruncateText(item, limit)
		}
		return typed
	case []any:
		for index := range typed {
			typed[index] = rendererClampTree(typed[index], limit)
		}
		return typed
	case []Object:
		for index := range typed {
			if item, ok := rendererClampTree(typed[index], limit).(Object); ok {
				typed[index] = item
			}
		}
		return typed
	case []string:
		for index := range typed {
			typed[index] = rendererTruncateText(typed[index], limit)
		}
		return typed
	default:
		return value
	}
}

func rendererBoundText(value any, limit int) string {
	switch typed := value.(type) {
	case string:
		return rendererTruncateText(strings.ReplaceAll(typed, "\x00", ""), limit)
	case json.RawMessage:
		var text string
		if json.Unmarshal(typed, &text) == nil {
			return rendererTruncateText(strings.ReplaceAll(text, "\x00", ""), limit)
		}
		return rendererTruncationMarker(len(typed))
	default:
		return ""
	}
}

func rendererText(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case json.RawMessage:
		var text string
		if json.Unmarshal(typed, &text) == nil {
			return text
		}
	}
	return ""
}

func rendererNonblankText(value any, limit int, fallback string) string {
	text := rendererBoundText(value, limit)
	if strings.TrimSpace(text) == "" {
		return fallback
	}
	return text
}

func rendererOptionalText(value any, limit int) string {
	if value == nil {
		return ""
	}
	return rendererBoundText(value, limit)
}

func rendererTextIdentity(value string, limit int) (string, bool) {
	if value == "" || len(value) > limit || strings.ContainsRune(value, 0) {
		return "", false
	}
	return value, true
}

func rendererPublicIdentity(value string) (string, bool) {
	if !rendererValidPublicIdentity(value) {
		return "", false
	}
	return value, true
}

func rendererValidPublicIdentity(value string) bool {
	if len(value) == 0 || len(value) > rendererMaxPublicIdentity {
		return false
	}
	for index := 0; index < len(value); index++ {
		unit := value[index]
		alphanumeric := unit >= '0' && unit <= '9' || unit >= 'A' && unit <= 'Z' || unit >= 'a' && unit <= 'z'
		if index == 0 {
			if !alphanumeric {
				return false
			}
			continue
		}
		if !alphanumeric && unit != '.' && unit != '_' && unit != ':' && unit != '-' {
			return false
		}
	}
	return true
}

func rendererTruncateUTF16(text string, limit int) string {
	if limit <= 0 {
		return ""
	}
	text = strings.ReplaceAll(text, "\x00", "")
	units := 0
	for index, point := range text {
		width := 1
		if point > 0xffff {
			width = 2
		}
		if units+width > limit {
			return text[:index]
		}
		units += width
	}
	return text
}

func rendererTruncateText(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	suffix := rendererTruncationSuffix
	if len(suffix) >= limit {
		suffix = "…"
	}
	keep := limit - len(suffix)
	for keep > 0 && !utf8.RuneStart(text[keep]) {
		keep--
	}
	return text[:keep] + suffix
}

func rendererTruncationMarker(size int) string {
	if size <= 0 {
		return rendererTruncationNote
	}
	return fmt.Sprintf("[Content truncated for transport: %d bytes; full content remains in the saved conversation.]", size)
}

func rendererEncodedSize(value any) int {
	return rendererSize(value, 0)
}

func rendererSize(value any, depth int) int {
	if depth > 64 {
		return 6
	}
	switch typed := value.(type) {
	case nil:
		return 4
	case bool:
		if typed {
			return 4
		}
		return 5
	case string:
		return rendererStringSize(typed)
	case json.RawMessage:
		return len(typed)
	case float64:
		return 32
	case int:
		return 20
	case json.Number:
		return len(typed)
	case []Object:
		size := 2
		for _, item := range typed {
			size += rendererSize(item, depth+1) + 1
		}
		return size
	case []any:
		size := 2
		for _, item := range typed {
			size += rendererSize(item, depth+1) + 1
		}
		return size
	case []string:
		size := 2
		for _, item := range typed {
			size += rendererStringSize(item) + 1
		}
		return size
	case Object:
		size := 2
		for key, item := range typed {
			size += rendererStringSize(key) + 1 + rendererSize(item, depth+1) + 1
		}
		return size
	case map[string]Object:
		size := 2
		for key, item := range typed {
			size += rendererStringSize(key) + 1 + rendererSize(item, depth+1) + 1
		}
		return size
	case map[string]string:
		size := 2
		for key, item := range typed {
			size += rendererStringSize(key) + 1 + rendererStringSize(item) + 1
		}
		return size
	default:
		return 32
	}
}

func rendererStringSize(text string) int {
	size := 2
	for index := 0; index < len(text); {
		unit := text[index]
		switch {
		case unit == '"' || unit == '\\':
			size, index = size+2, index+1
		case unit == '\n' || unit == '\r' || unit == '\t' || unit == '\b' || unit == '\f':
			size, index = size+2, index+1
		case unit < 0x20:
			size, index = size+6, index+1
		case unit == '<' || unit == '>' || unit == '&':
			size, index = size+6, index+1
		case unit < utf8.RuneSelf:
			size, index = size+1, index+1
		default:
			runeValue, width := utf8.DecodeRuneInString(text[index:])
			if runeValue == utf8.RuneError && width == 1 {
				size, index = size+3, index+1
			} else if runeValue == 0x2028 || runeValue == 0x2029 {
				size, index = size+6, index+width
			} else {
				size, index = size+width, index+width
			}
		}
	}
	return size
}

func rendererInteger(value any) (int, bool) {
	switch typed := value.(type) {
	case int:
		return typed, true
	case float64:
		if math.IsNaN(typed) || math.IsInf(typed, 0) || typed < 0 || math.Trunc(typed) != typed || typed > math.MaxInt {
			return 0, false
		}
		return int(typed), true
	case json.Number:
		value, err := typed.Int64()
		if err != nil || value < 0 {
			return 0, false
		}
		return int(value), true
	default:
		return 0, false
	}
}

func rendererNumber(value any) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		if math.IsNaN(typed) || math.IsInf(typed, 0) {
			return 0, false
		}
		return typed, true
	case int:
		return float64(typed), true
	case json.Number:
		number, err := typed.Float64()
		if err != nil || math.IsNaN(number) || math.IsInf(number, 0) {
			return 0, false
		}
		return number, true
	default:
		return 0, false
	}
}

func rendererBool(value any) bool {
	flag, _ := value.(bool)
	return flag
}

func rendererOneOf(value string, allowed ...string) bool {
	for _, item := range allowed {
		if value == item {
			return true
		}
	}
	return false
}
