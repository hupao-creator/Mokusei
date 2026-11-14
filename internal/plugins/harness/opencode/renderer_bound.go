package opencode

import (
	"encoding/json"
	"fmt"
	"unicode/utf8"
)

// The transport rejects one encoded content event above 32 MiB. Leave room for
// the event envelope and JSON escaping so an oversized conversation can still
// open with a bounded projection. The persisted native state is never changed.
const (
	rendererWireBudget     = 24 << 20
	rendererLightFieldSize = 512 << 10
	rendererLightToolSize  = 256 << 10
	rendererHeavyFieldSize = 8 << 10
	rendererMaxMessages    = 2000
)

const rendererTruncationSuffix = "\n\n[Truncated for transport; full content remains in the saved conversation.]"

func rendererMarshalProjection(value Object) (json.RawMessage, error) {
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) <= rendererWireBudget {
		return encoded, err
	}
	state := rendererProjectionState(value)
	rendererMarkTruncated(state)
	rendererDegradeMessages(state, rendererLightFieldSize, false)
	encoded, err = json.Marshal(value)
	if err == nil && len(encoded) <= rendererWireBudget {
		return encoded, nil
	}

	// Keep the most useful recent messages before per-message budgets shrink.
	rendererLimitMessageCount(state)
	rendererDegradeMessages(state, rendererHeavyFieldSize, true)
	encoded, err = json.Marshal(value)
	if err == nil && len(encoded) <= rendererWireBudget {
		return encoded, nil
	}

	rendererSkeletonMessages(state)
	encoded, err = json.Marshal(value)
	if err != nil || len(encoded) <= rendererWireBudget {
		return encoded, err
	}
	// A final hard stop prevents an adversarial message/part shape from
	// re-crossing the transport boundary after skeletonization.
	rendererKeepLastMessages(state, 100)
	encoded, err = json.Marshal(value)
	if err != nil || len(encoded) <= rendererWireBudget {
		return encoded, err
	}
	rendererKeepLastMessages(state, 10)
	return json.Marshal(value)
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

func rendererMessages(state Object) []Object {
	messages, _ := state["messages"].([]Object)
	return messages
}

func rendererDegradeMessages(state Object, fieldSize int, heavy bool) {
	messages := rendererMessages(state)
	limit := fieldSize
	if heavy && len(messages) > 0 {
		// Text, reasoning, tool payloads and their displays can each occupy a
		// field. This keeps a large message count inside the overall budget
		// instead of letting a fixed per-field size multiply past the limit.
		share := rendererWireBudget / (len(messages) * 8)
		limit = min(limit, max(share, 512))
	}
	for _, message := range messages {
		role := str(message["role"])
		toolLimit := limit
		if !heavy {
			toolLimit = min(toolLimit, rendererLightToolSize)
		}
		rendererClampTextField(message, "text", limit)
		rendererClampTextField(message, "thinking", limit)
		if parts, ok := message["parts"].([]Object); ok {
			for _, part := range parts {
				rendererClampTextField(part, "text", limit)
			}
		}
		if role == "tool" {
			rendererClampTextField(message, "text", toolLimit)
			// Text is the rendered result for text/file content. Sending the
			// redundant structured result and its display can triple one large
			// tool output without changing what the reader presents.
			if str(message["text"]) != "" {
				delete(message, "result")
				delete(message, "resultDisplay")
			} else {
				rendererBoundToolField(message, "result", toolLimit)
			}
			rendererBoundToolField(message, "arguments", toolLimit)
		}
		if heavy {
			delete(message, "metadata")
			delete(message, "todos")
			delete(message, "annotations")
			delete(message, "attachments")
			continue
		}
		rendererDropLargeField(message, "metadata", 64<<10)
		rendererDropLargeField(message, "todos", 64<<10)
		rendererDropLargeField(message, "annotations", 64<<10)
		rendererDropLargeField(message, "attachments", 64<<10)
	}
	if heavy {
		rendererCapExecutions(state, 500)
		rendererCapCollection(state, "interactions", 200)
		rendererCapCollection(state, "auxiliaryUsage", 200)
	}
}

func rendererClampTextField(object Object, key string, limit int) {
	switch value := object[key].(type) {
	case string:
		object[key] = rendererTruncateText(value, limit)
	case json.RawMessage:
		if len(value) > limit {
			var text string
			if json.Unmarshal(value, &text) == nil {
				object[key] = rendererTruncateText(text, limit)
			} else {
				object[key] = rendererTruncationMarker(len(value))
			}
		}
	}
}

func rendererBoundToolField(message Object, key string, limit int) {
	value, exists := message[key]
	if !exists {
		return
	}
	encoded, err := json.Marshal(value)
	if err == nil && len(encoded) <= limit {
		// A pretty display can be larger than its source. When it cannot be
		// represented intact, replace the source too: the Swift reader validates
		// that any display it trusts is an exact rendering of that source.
		if display, ok := message[key+"Display"]; ok {
			if raw, err := json.Marshal(display); err != nil || len(raw) > limit {
				message[key] = rendererTruncationMarker(len(encoded))
				delete(message, key+"Display")
			}
		}
		return
	}
	message[key] = rendererTruncationMarker(len(encoded))
	delete(message, key+"Display")
}

func rendererDropLargeField(object Object, key string, limit int) {
	value, exists := object[key]
	if !exists {
		return
	}
	if raw, err := json.Marshal(value); err != nil || len(raw) > limit {
		delete(object, key)
	}
}

func rendererCapCollection(state Object, key string, limit int) {
	values, ok := state[key].([]Object)
	if !ok || len(values) <= limit {
		return
	}
	state[key] = append([]Object(nil), values[len(values)-limit:]...)
}

func rendererCapExecutions(state Object, limit int) {
	values, ok := state["executions"].([]Object)
	if !ok || len(values) <= limit {
		return
	}
	limited := append([]Object(nil), values[len(values)-limit:]...)
	latest := str(state["latestExecutionId"])
	if latest == "" {
		state["executions"] = limited
		return
	}
	for _, value := range limited {
		if str(value["executionId"]) == latest {
			state["executions"] = limited
			return
		}
	}
	// Swift rejects a latestExecutionId that is outside the execution list.
	for _, value := range values {
		if str(value["executionId"]) == latest {
			limited[0] = value
			break
		}
	}
	state["executions"] = limited
}

func rendererLimitMessageCount(state Object) {
	messages := rendererMessages(state)
	if len(messages) <= rendererMaxMessages {
		return
	}
	const head = 100
	tail := rendererMaxMessages - head
	limited := make([]Object, 0, rendererMaxMessages)
	limited = append(limited, messages[:head]...)
	limited = append(limited, messages[len(messages)-tail:]...)
	state["messages"] = limited
}

func rendererKeepLastMessages(state Object, limit int) {
	messages := rendererMessages(state)
	if len(messages) <= limit {
		return
	}
	state["messages"] = append([]Object(nil), messages[len(messages)-limit:]...)
}

func rendererSkeletonMessages(state Object) {
	messages := rendererMessages(state)
	if len(messages) > 500 {
		messages = messages[len(messages)-500:]
	}
	skeleton := make([]Object, 0, len(messages))
	for _, message := range messages {
		next := Object{}
		for _, key := range []string{
			"id", "executionId", "role", "status", "createdAt", "nativeSessionId",
			"nativeMessageId", "inherited", "isError", "model", "provider", "variant",
			"usage", "toolCallId", "toolName", "presentation", "followUp",
		} {
			if value, exists := message[key]; exists {
				next[key] = value
			}
		}
		text := str(message["text"])
		if text == "" && str(message["role"]) == "tool" {
			text = rendererTruncationMarker(0)
		}
		next["text"] = rendererTruncateText(text, 2048)
		if thinking := str(message["thinking"]); thinking != "" {
			next["thinking"] = rendererTruncateText(thinking, 1024)
		}
		if parts, ok := message["parts"].([]Object); ok && len(parts) > 0 {
			trimmed := make([]Object, 0, min(len(parts), 32))
			for _, part := range parts[:min(len(parts), 32)] {
				item := Object{}
				for _, key := range []string{"type", "ordinal", "toolCallId", "text"} {
					if value, exists := part[key]; exists {
						item[key] = value
					}
				}
				rendererClampTextField(item, "text", 1024)
				trimmed = append(trimmed, item)
			}
			next["parts"] = trimmed
		}
		skeleton = append(skeleton, next)
	}
	state["messages"] = skeleton
	rendererCapExecutions(state, 200)
	rendererCapCollection(state, "interactions", 100)
	rendererCapCollection(state, "auxiliaryUsage", 100)
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
		return "[Content omitted for transport; full content remains in the saved conversation.]"
	}
	return fmt.Sprintf("[Content truncated for transport: %d bytes; full content remains in the saved conversation.]", size)
}
