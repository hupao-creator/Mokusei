package opencode

import (
	"crypto/sha256"
	"encoding/hex"
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
	rendererWireBudget     = 24 << 20
	rendererMaxIdentity    = 128
	rendererDropFieldSize  = 64 << 10
	rendererTruncationNote = "[Content omitted or truncated for transport; full content remains in the saved conversation.]"
)

const rendererTruncationSuffix = "\n\n[Truncated for transport; full content remains in the saved conversation.]"

type rendererLimits struct {
	text, tool, short          int
	parts                      int
	messages, messageHead      int
	executions, interactions   int
	actions, questions, fields int
	options                    int
	nonemptyBudget             int
	dropOptional               bool
}

var rendererStages = []rendererLimits{
	{
		text: 512 << 10, tool: 256 << 10, short: 16 << 10,
		parts: 256, executions: 1000, interactions: 200,
		actions: 64, questions: 64, fields: 64, options: 64,
		nonemptyBudget: 2 << 20,
	},
	{
		text: 8 << 10, tool: 8 << 10, short: 2 << 10,
		parts: 16, messages: 2000, messageHead: 100,
		executions: 200, interactions: 32,
		actions: 16, questions: 16, fields: 32, options: 32,
		nonemptyBudget: 512 << 10, dropOptional: true,
	},
	{
		text: 2 << 10, tool: 2 << 10, short: 512,
		parts: 8, messages: 500, messageHead: 20,
		executions: 100, interactions: 8,
		actions: 8, questions: 8, fields: 16, options: 16,
		nonemptyBudget: 128 << 10, dropOptional: true,
	},
	{
		text: 512, tool: 512, short: 256,
		parts: 4, messages: 10,
		executions: 1, interactions: 1,
		actions: 4, questions: 4, fields: 4, options: 4,
		nonemptyBudget: 16 << 10, dropOptional: true,
	},
}

func rendererMarshalProjection(value Object) (json.RawMessage, error) {
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) <= rendererWireBudget {
		return encoded, err
	}
	state := rendererProjectionState(value)
	rendererMarkTruncated(state)
	for _, limits := range rendererStages {
		rendererApplyLimits(value, state, limits)
		encoded, err = json.Marshal(value)
		if err != nil {
			return nil, err
		}
		if len(encoded) <= rendererWireBudget {
			return encoded, nil
		}
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

func rendererApplyLimits(value, state Object, limits rendererLimits) {
	rendererLimitMessages(state, limits.messages, limits.messageHead)
	rendererBoundMessages(state, limits)
	rendererBoundExecutions(state, limits)
	rendererBoundTopInteractions(state, limits)
	rendererBoundTopLevel(state, limits)
	rendererClampTree(state, limits.text)
	rendererRebuildNonempty(value, state, limits.nonemptyBudget)
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
	if messages == nil {
		messages = []Object{}
	}
	for _, message := range messages {
		rendererBoundMessage(message, limits)
	}
	state["messages"] = messages
}

func rendererBoundMessage(message Object, limits rendererLimits) {
	message["id"] = rendererBoundTextIdentity(rendererText(message["id"]))
	message["executionId"] = rendererBoundPublicIdentity(rendererText(message["executionId"]))
	for _, key := range []string{"nativeSessionId", "nativeMessageId", "toolCallId"} {
		if value, exists := message[key]; exists {
			message[key] = rendererBoundTextIdentity(rendererText(value))
		}
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
	if rendererText(message["role"]) == "tool" {
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
}

func rendererBoundPart(part Object, limits rendererLimits) bool {
	kind := rendererText(part["type"])
	if !rendererOneOf(kind, "text", "reasoning", "tool") {
		kind = "text"
	}
	part["type"] = kind
	if kind == "tool" {
		toolCallID := rendererBoundTextIdentity(rendererText(part["toolCallId"]))
		if toolCallID == "" {
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
	bound := make([]Object, 0, len(executions))
	for _, execution := range executions {
		if next, ok := rendererBoundExecution(execution, limits); ok {
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
		if rendererBoundPublicIdentity(rendererText(execution["executionId"])) == latest {
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

func rendererBoundExecution(execution Object, limits rendererLimits) (Object, bool) {
	executionID := rendererBoundPublicIdentity(rendererText(execution["executionId"]))
	if executionID == "" {
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
		if len(interactions) > limits.interactions {
			interactions = interactions[:limits.interactions]
		}
		bound := make([]Object, 0, len(interactions))
		for _, interaction := range interactions {
			if value, ok := rendererBoundPublicInteraction(interaction, limits); ok {
				bound = append(bound, value)
			}
		}
		if len(bound) == 0 {
			status = "failed"
			next["status"] = status
			next["finishedAt"] = started
			next["error"] = rendererTruncationNote
			break
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
	next := Object{
		"id":    rendererBoundPublicIdentity(rendererText(interaction["id"])),
		"kind":  kind,
		"title": rendererNonblankText(interaction["title"], limits.short, "OpenCode interaction"),
	}
	if value, exists := interaction["description"]; exists {
		next["description"] = rendererBoundText(value, limits.short)
	}
	actions := rendererObjects(interaction["actions"])
	if len(actions) > limits.actions {
		actions = actions[:limits.actions]
	}
	boundActions := make([]Object, 0, len(actions))
	for _, action := range actions {
		intent := rendererText(action["intent"])
		if !rendererOneOf(intent, "allow", "deny", "submit", "cancel") {
			intent = "allow"
		}
		boundActions = append(boundActions, Object{
			"id":     rendererBoundPublicIdentity(rendererText(action["id"])),
			"intent": intent,
			"label":  rendererNonblankText(action["label"], limits.short, "Allow"),
		})
	}
	if len(boundActions) == 0 {
		boundActions = append(boundActions, Object{"id": "allow", "intent": "allow", "label": "Allow"})
	}
	next["actions"] = boundActions
	questions := rendererObjects(interaction["questions"])
	if len(questions) > limits.questions {
		questions = questions[:limits.questions]
	}
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
	id := rendererBoundPublicIdentity(rendererText(question["id"]))
	if id == "" {
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
		next["header"] = rendererBoundText(value, limits.short)
	}
	if value, exists := question["answerFormat"]; exists {
		if format := rendererText(value); format == "json-object" {
			next["answerFormat"] = format
		}
	}
	if value, exists := question["form"]; exists && rendererEncodedSize(value) <= limits.short*4 {
		next["form"] = value
	}
	options := rendererObjects(question["options"])
	if len(options) > limits.options {
		options = options[:limits.options]
	}
	boundOptions := make([]Object, 0, len(options))
	for index, option := range options {
		boundOptions = append(boundOptions, Object{
			"value":       rendererOptionValue(option["value"], index),
			"label":       rendererNonblankText(option["label"], 2_000, "Option"),
			"description": rendererOptionalText(option["description"], limits.short),
		})
	}
	next["options"] = boundOptions
	return next, true
}

func rendererBoundTopInteractions(state Object, limits rendererLimits) {
	interactions := rendererObjects(state["interactions"])
	if len(interactions) > limits.interactions {
		interactions = interactions[len(interactions)-limits.interactions:]
	}
	bound := make([]Object, 0, len(interactions))
	for _, interaction := range interactions {
		if value, ok := rendererBoundNativeInteraction(interaction, limits); ok {
			bound = append(bound, value)
		}
	}
	state["interactions"] = bound
}

func rendererBoundNativeInteraction(interaction Object, limits rendererLimits) (Object, bool) {
	kind := rendererText(interaction["kind"])
	if !rendererOneOf(kind, "permission", "form") {
		return nil, false
	}
	status := rendererText(interaction["status"])
	if !rendererOneOf(status, "pending", "answered", "cancelled") {
		status = "cancelled"
	}
	next := Object{
		"id":          rendererBoundTextIdentity(rendererText(interaction["id"])),
		"executionId": rendererBoundPublicIdentity(rendererText(interaction["executionId"])),
		"sessionId":   rendererBoundTextIdentity(rendererText(interaction["sessionId"])),
		"kind":        kind,
		"title":       rendererNonblankText(interaction["title"], limits.short, "OpenCode request"),
		"status":      status,
	}
	if kind == "permission" {
		next["action"] = rendererNonblankText(interaction["action"], limits.short, "allow")
		next["resources"] = rendererBoundStringArray(interaction["resources"], limits.actions, limits.short)
		next["save"] = rendererBoundStringArray(interaction["save"], limits.actions, limits.short)
		if value, exists := interaction["description"]; exists {
			next["description"] = rendererBoundText(value, limits.short)
		}
	} else {
		fields := rendererObjects(interaction["fields"])
		if len(fields) > limits.fields {
			fields = fields[:limits.fields]
		}
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
	kind := rendererText(field["type"])
	if !rendererOneOf(kind, "string", "number", "integer", "boolean", "multiselect", "external") {
		kind = "string"
	}
	key := rendererBoundText(field["key"], limits.short)
	if key == "" {
		return nil, false
	}
	next := Object{"type": kind, "key": key, "required": rendererBool(field["required"])}
	for _, name := range []string{"title", "description", "placeholder", "pattern"} {
		if value, exists := field[name]; exists {
			next[name] = rendererBoundText(value, limits.short)
		}
	}
	if value, exists := field["format"]; exists {
		if format := rendererText(value); rendererOneOf(format, "email", "uri", "date", "date-time") {
			next["format"] = format
		}
	}
	if value, exists := field["custom"]; exists {
		next["custom"] = rendererBool(value)
	}
	for _, name := range []string{"minimum", "maximum"} {
		if value, exists := field[name]; exists {
			if number, ok := rendererNumber(value); ok {
				next[name] = number
			}
		}
	}
	for _, name := range []string{"minLength", "maxLength", "minItems", "maxItems"} {
		if value, exists := field[name]; exists {
			if integer, ok := rendererInteger(value); ok {
				next[name] = integer
			}
		}
	}
	if value, exists := field["hidden"]; exists {
		next["hidden"] = rendererBool(value)
	}
	if value, exists := field["default"]; exists && rendererEncodedSize(value) <= limits.short {
		next["default"] = value
	}
	if value, exists := field["url"]; exists {
		next["url"] = rendererBoundText(value, 4_096)
	}
	if options := rendererObjects(field["options"]); len(options) > 0 {
		if len(options) > limits.options {
			options = options[:limits.options]
		}
		bound := make([]Object, 0, len(options))
		for index, option := range options {
			bound = append(bound, Object{
				"value":       rendererOptionValue(option["value"], index),
				"label":       rendererNonblankText(option["label"], 2_000, "Option"),
				"description": rendererOptionalText(option["description"], limits.short),
			})
		}
		next["options"] = bound
	}
	if when := rendererObjects(field["when"]); len(when) > 0 {
		if len(when) > limits.options {
			when = when[:limits.options]
		}
		bound := make([]Object, 0, len(when))
		for _, condition := range when {
			op := rendererText(condition["op"])
			if !rendererOneOf(op, "eq", "neq") {
				op = "eq"
			}
			bound = append(bound, Object{
				"questionId": rendererBoundText(condition["questionId"], limits.short),
				"op":         op,
				"value":      condition["value"],
			})
		}
		next["when"] = bound
	}
	return next, true
}

func rendererBoundStringArray(value any, limit, size int) []string {
	values := rendererArrayValues(value)
	if len(values) > limit {
		values = values[:limit]
	}
	result := make([]string, 0, len(values))
	for _, item := range values {
		if text := rendererBoundText(item, size); text != "" {
			result = append(result, text)
		}
	}
	return result
}

func rendererBoundTopLevel(state Object, limits rendererLimits) {
	delete(state, "contentTruncated")
	state["contentTruncated"] = true
	if value, exists := state["nativeSessionId"]; exists {
		state["nativeSessionId"] = rendererBoundTextIdentity(rendererText(value))
	}
	if value, exists := state["nativeSessionCreated"]; exists {
		if rendererBool(value) {
			state["nativeSessionCreated"] = true
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
		state["executionAuthors"] = rendererBoundAuthors(value, limits)
	}
	if value, exists := state["foregrounds"]; exists {
		state["foregrounds"] = rendererBoundForegrounds(value, limits)
	}
	if value, exists := state["auxiliaryUsage"]; exists {
		state["auxiliaryUsage"] = rendererBoundAuxiliaryUsage(value, limits)
	}
	if value, exists := state["forkSource"]; exists {
		fork := rendererBoundForkSource(value, limits)
		if rendererText(fork["sessionId"]) == "" {
			delete(state, "forkSource")
		} else {
			state["forkSource"] = fork
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
		status := item.Status
		if !rendererOneOf(status, "running", "idle") {
			status = "idle"
		}
		result = append(result, Object{"sessionId": rendererBoundTextIdentity(item.SessionID), "status": status})
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
		status := item.Status
		if !rendererOneOf(status, "running", "idle") {
			status = "idle"
		}
		result = append(result, Object{"shellId": rendererBoundTextIdentity(item.ShellID), "sessionId": rendererBoundTextIdentity(item.SessionID), "status": status})
	}
	return result
}

func rendererBoundAuthors(value any, limits rendererLimits) map[string]Object {
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
	keys := make([]string, 0, len(source))
	for key := range source {
		keys = append(keys, key)
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
				if text := rendererBoundText(field, limits.short); strings.TrimSpace(text) != "" {
					author[name] = text
				}
			}
		}
		if len(author) > 0 {
			result[rendererBoundPublicIdentity(key)] = author
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
			body["text"] = rendererBoundText(foreground["text"], limits.text)
			if offset, ok := rendererInteger(foreground["textOffset"]); ok && offset >= 0 {
				body["textOffset"] = offset
			}
		case "tool-call":
			body["callId"] = rendererBoundTextIdentity(rendererText(foreground["callId"]))
			body["toolName"] = rendererBoundText(foreground["toolName"], 64)
		}
		next := Object{"executionId": rendererBoundPublicIdentity(rendererText(entry["executionId"])), "foreground": body}
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
		next := Object{
			"id":              rendererBoundTextIdentity(rendererText(sample["id"])),
			"nativeSessionId": rendererBoundTextIdentity(rendererText(sample["nativeSessionId"])),
			"executionId":     rendererBoundPublicIdentity(rendererText(sample["executionId"])),
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

func rendererBoundForkSource(value any, limits rendererLimits) Object {
	source, ok := value.(Object)
	if !ok {
		return Object{"sessionId": "", "transcript": Object{}}
	}
	next := Object{
		"sessionId":  rendererBoundTextIdentity(rendererText(source["sessionId"])),
		"transcript": Object{},
	}
	if messageID, exists := source["messageId"]; exists {
		next["messageId"] = rendererBoundTextIdentity(rendererText(messageID))
	}
	return next
}

func rendererRebuildNonempty(value, state Object, budget int) {
	if value["kind"] != "deferred-execution" {
		return
	}
	messages := rendererObjects(state["messages"])
	entries := make([]Object, 0)
	used := 2
	for index := len(messages) - 1; index >= 0; index-- {
		message := messages[index]
		id := rendererText(message["id"])
		if id == "" {
			continue
		}
		add := func(field string) bool {
			entry := Object{"id": id, "field": field}
			size := rendererEncodedSize(entry) + 1
			if used+size > budget {
				return false
			}
			entries = append(entries, entry)
			used += size
			return true
		}
		if rendererNativeNonempty(rendererText(message["text"])) && !add("text") {
			break
		}
		if rendererNativeNonempty(rendererText(message["thinking"])) && !add("thinking") {
			break
		}
		parts := rendererObjects(message["parts"])
		stopped := false
		for _, part := range parts {
			if rendererText(part["type"]) == "tool" || !rendererNativeNonempty(rendererText(part["text"])) {
				continue
			}
			ordinal, _ := rendererInteger(part["ordinal"])
			if !add(fmt.Sprintf("parts:%s:%d", rendererText(part["type"]), ordinal)) {
				stopped = true
				break
			}
		}
		if stopped {
			break
		}
	}
	for left, right := 0, len(entries)-1; left < right; left, right = left+1, right-1 {
		entries[left], entries[right] = entries[right], entries[left]
	}
	value["nonempty"] = entries
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
		id := rendererBoundPublicIdentity(rendererText(execution["executionId"]))
		if id == "" {
			continue
		}
		tiny = append(tiny, Object{
			"executionId": id,
			"status":      "failed",
			"startedAt":   0,
			"finishedAt":  0,
			"error":       rendererTruncationNote,
		})
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
	switch value := state["latestExecutionId"].(type) {
	case string:
		return rendererBoundPublicIdentity(value)
	case *string:
		if value == nil {
			return ""
		}
		return rendererBoundPublicIdentity(*value)
	default:
		return ""
	}
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
		return rendererTruncateText(typed, limit)
	case json.RawMessage:
		if len(typed) <= limit {
			return rendererText(typed)
		}
		var text string
		if json.Unmarshal(typed, &text) == nil {
			return rendererTruncateText(text, limit)
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

func rendererBoundUniqueText(value any, limit int) string {
	text := rendererBoundText(value, limit)
	if text == "" {
		return ""
	}
	if len(rendererText(value)) <= limit {
		return text
	}
	hash := sha256.Sum256([]byte(rendererText(value)))
	suffix := "~" + hex.EncodeToString(hash[:6])
	keep := limit - len(suffix)
	if keep < 1 {
		return hex.EncodeToString(hash[:6])
	}
	text = rendererTruncateText(rendererText(value), keep)
	return text + suffix
}

func rendererOptionValue(value any, index int) string {
	text := rendererBoundUniqueText(value, 2_000)
	if strings.TrimSpace(text) == "" {
		return fmt.Sprintf("option-%d", index)
	}
	return text
}

func rendererBoundTextIdentity(value string) string {
	if value == "" {
		hash := sha256.Sum256(nil)
		return "d-" + hex.EncodeToString(hash[:12])
	}
	if len(value) <= rendererMaxIdentity && !strings.ContainsRune(value, 0) {
		return value
	}
	return rendererHashedIdentity(value)
}

func rendererBoundPublicIdentity(value string) string {
	if rendererValidPublicIdentity(value) {
		return value
	}
	return rendererHashedIdentity(value)
}

func rendererValidPublicIdentity(value string) bool {
	if len(value) == 0 || len(value) > rendererMaxIdentity {
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

func rendererHashedIdentity(value string) string {
	hash := sha256.Sum256([]byte(value))
	return "d-" + hex.EncodeToString(hash[:12])
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
