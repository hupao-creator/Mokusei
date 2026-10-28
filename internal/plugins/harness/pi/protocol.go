package pi

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
)

// Model is the native model metadata. Optional booleans retain the distinction
// between an explicit capability and a capability Pi did not report.
type Model struct {
	Input                   []string           `json:"input,omitempty"`
	Provider                string             `json:"provider"`
	ID                      string             `json:"id"`
	Name                    string             `json:"name"`
	BaseURL                 string             `json:"baseUrl,omitempty"`
	API                     string             `json:"api,omitempty"`
	Reasoning               *bool              `json:"reasoning,omitempty"`
	ThinkingLevels          []string           `json:"thinkingLevels,omitempty"`
	ThinkingLevelMap        map[string]*string `json:"thinkingLevelMap,omitempty"`
	ThinkingFormat          string             `json:"thinkingFormat,omitempty"`
	SupportsReasoningEffort *bool              `json:"supportsReasoningEffort,omitempty"`
	HasRequestOverrides     bool               `json:"hasRequestOverrides,omitempty"`
}

type NativeState struct {
	SessionFile   string `json:"sessionFile,omitempty"`
	SessionID     string `json:"sessionId,omitempty"`
	Model         *Model `json:"model,omitempty"`
	ThinkingLevel string `json:"thinkingLevel,omitempty"`
}

type Command struct {
	Name       string `json:"name"`
	Source     string `json:"source"`
	SourcePath string `json:"sourcePath,omitempty"`
}

type Image struct {
	Type     string `json:"type"`
	MimeType string `json:"mimeType"`
	Data     string `json:"data"`
}

type PromptInput struct {
	Message string
	Images  []Image
	Steer   bool
}

type InteractionAnswer struct {
	Confirmed *bool   `json:"confirmed,omitempty"`
	Cancelled bool    `json:"cancelled,omitempty"`
	Value     *string `json:"value,omitempty"`
}

type Usage struct {
	Input      int64    `json:"input"`
	Output     int64    `json:"output"`
	CacheRead  int64    `json:"cacheRead"`
	CacheWrite int64    `json:"cacheWrite"`
	Reasoning  *int64   `json:"reasoning,omitempty"`
	Cost       *float64 `json:"cost,omitempty"`
}

type Todo struct {
	ID   int64  `json:"id"`
	Text string `json:"text"`
	Done bool   `json:"done"`
}

// Event contains one normalized native event. Only settled includes Completion;
// agent_end is deliberately ignored because queued native work may follow it.
type Event struct {
	Type       string      `json:"type"`
	Phase      string      `json:"phase,omitempty"`
	Text       string      `json:"text,omitempty"`
	Thinking   string      `json:"thinking,omitempty"`
	Model      string      `json:"model,omitempty"`
	Provider   string      `json:"provider,omitempty"`
	StopReason string      `json:"stopReason,omitempty"`
	Error      string      `json:"error,omitempty"`
	Usage      *Usage      `json:"usage,omitempty"`
	CallID     string      `json:"callId,omitempty"`
	Name       string      `json:"name,omitempty"`
	IsError    bool        `json:"isError,omitempty"`
	Todos      []Todo      `json:"todos,omitzero"`
	ID         string      `json:"id,omitempty"`
	Method     string      `json:"method,omitempty"`
	Title      string      `json:"title,omitempty"`
	Message    string      `json:"message,omitempty"`
	Prefill    *string     `json:"prefill,omitempty"`
	Options    []string    `json:"options,omitempty"`
	Timeout    *float64    `json:"timeout,omitempty"`
	Completion *Completion `json:"completion,omitempty"`
}

func piRecord(value any, field string) (map[string]any, error) {
	if v, ok := value.(map[string]any); ok && v != nil {
		return v, nil
	}
	return nil, fmt.Errorf("invalid Pi %s", field)
}

func piText(value any, field string) (string, error) {
	if v, ok := value.(string); ok {
		return v, nil
	}
	return "", fmt.Errorf("invalid Pi %s", field)
}

func piOptionalText(source map[string]any, key, field string) (string, error) {
	v, exists := source[key]
	if !exists {
		return "", nil
	}
	return piText(v, field)
}

func piIdentifier(value any, field string) (string, error) {
	v, err := piText(value, field)
	if err != nil || v == "" || strings.ContainsRune(v, '\x00') {
		return "", fmt.Errorf("invalid Pi %s", field)
	}
	return v, nil
}

func piStrings(value any, field string) ([]string, error) {
	values, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("invalid Pi %s", field)
	}
	result := make([]string, len(values))
	for i, v := range values {
		var err error
		result[i], err = piText(v, field)
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}

func piNumber(value any, field string) (float64, error) {
	var n float64
	switch v := value.(type) {
	case float64:
		n = v
	case json.Number:
		var err error
		n, err = v.Float64()
		if err != nil {
			return 0, fmt.Errorf("invalid Pi %s", field)
		}
	default:
		return 0, fmt.Errorf("invalid Pi %s", field)
	}
	if math.IsNaN(n) || math.IsInf(n, 0) || n < 0 {
		return 0, fmt.Errorf("invalid Pi %s", field)
	}
	return n, nil
}

func piCount(value any, field string) (int64, error) {
	n, err := piNumber(value, field)
	if err != nil || n > 9007199254740991 || math.Trunc(n) != n {
		return 0, fmt.Errorf("invalid Pi %s", field)
	}
	return int64(n), nil
}

func piContent(value any, kind string) (string, error) {
	if s, ok := value.(string); ok {
		if kind == "text" {
			return s, nil
		}
		return "", nil
	}
	items, ok := value.([]any)
	if !ok {
		return "", fmt.Errorf("invalid Pi message content")
	}
	var parts []string
	for _, value := range items {
		item, err := piRecord(value, "content block")
		if err != nil {
			return "", err
		}
		if item["type"] == kind {
			part, err := piText(item[kind], kind+" content")
			if err != nil {
				return "", err
			}
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, "\n"), nil
}

func piUsage(value any) (*Usage, error) {
	source, err := piRecord(value, "usage")
	if err != nil {
		return nil, err
	}
	u := &Usage{}
	for _, entry := range []struct {
		key string
		out *int64
	}{{"input", &u.Input}, {"output", &u.Output}, {"cacheRead", &u.CacheRead}, {"cacheWrite", &u.CacheWrite}} {
		*entry.out, err = piCount(source[entry.key], entry.key+" tokens")
		if err != nil {
			return nil, err
		}
	}
	if value, exists := source["reasoning"]; exists {
		n, err := piCount(value, "reasoning tokens")
		if err != nil {
			return nil, err
		}
		u.Reasoning = &n
	}
	if value, exists := source["cost"]; exists {
		cost, err := piRecord(value, "usage cost")
		if err != nil {
			return nil, err
		}
		n, err := piNumber(cost["total"], "usage cost")
		if err != nil {
			return nil, err
		}
		u.Cost = &n
	}
	return u, nil
}

func piTodos(value any) []Todo {
	values, ok := value.([]any)
	if !ok {
		return nil
	}
	todos := make([]Todo, 0, len(values))
	ids := map[int64]bool{}
	for _, value := range values {
		entry, err := piRecord(value, "todo")
		if err != nil {
			return nil
		}
		id, err := piCount(entry["id"], "todo ID")
		text, textOK := entry["text"].(string)
		done, doneOK := entry["done"].(bool)
		if err != nil || id < 1 || ids[id] || !textOK || strings.TrimSpace(text) == "" || strings.ContainsRune(text, '\x00') || !doneOK {
			return nil
		}
		ids[id] = true
		todos = append(todos, Todo{ID: id, Text: text, Done: done})
	}
	return todos
}

func decodeEvent(frame map[string]any) (*Event, error) {
	typ, err := piText(frame["type"], "event type")
	if err != nil {
		return nil, err
	}
	switch typ {
	case "agent_start":
		return &Event{Type: "started"}, nil
	case "agent_settled":
		return &Event{Type: "settled"}, nil
	case "extension_error":
		errText, err := piOptionalText(frame, "error", "extension error")
		if _, exists := frame["error"]; !exists {
			errText = "unknown extension error"
		}
		return &Event{Type: "extension-error", Error: errText}, err
	case "message_start", "message_update", "message_end":
		message, err := piRecord(frame["message"], "message")
		if err != nil {
			return nil, err
		}
		if message["role"] == "user" && typ == "message_start" {
			text, err := piContent(message["content"], "text")
			return &Event{Type: "user", Text: text}, err
		}
		if message["role"] != "assistant" {
			return nil, nil
		}
		e := &Event{Type: "assistant", Phase: strings.TrimPrefix(typ, "message_")}
		e.Text, err = piContent(message["content"], "text")
		if err != nil {
			return nil, err
		}
		e.Thinking, err = piContent(message["content"], "thinking")
		if err != nil {
			return nil, err
		}
		for _, entry := range []struct {
			key string
			out *string
		}{{"model", &e.Model}, {"provider", &e.Provider}, {"stopReason", &e.StopReason}, {"errorMessage", &e.Error}} {
			*entry.out, err = piOptionalText(message, entry.key, entry.key)
			if err != nil {
				return nil, err
			}
		}
		if value, exists := message["usage"]; e.Phase == "end" && exists {
			e.Usage, err = piUsage(value)
			if err != nil {
				return nil, err
			}
		}
		return e, nil
	case "tool_execution_start", "tool_execution_update", "tool_execution_end":
		e := &Event{Type: "tool", Phase: strings.TrimPrefix(typ, "tool_execution_")}
		e.CallID, err = piIdentifier(frame["toolCallId"], "tool call ID")
		if err != nil {
			return nil, err
		}
		e.Name, err = piIdentifier(frame["toolName"], "tool name")
		if err != nil {
			return nil, err
		}
		if value, exists := frame["isError"]; exists {
			var ok bool
			e.IsError, ok = value.(bool)
			if !ok {
				return nil, fmt.Errorf("invalid Pi tool error flag")
			}
		}
		if e.Phase == "start" {
			args := frame["args"]
			if args == nil {
				args = map[string]any{}
			}
			bytes, err := json.Marshal(args)
			if err != nil {
				return nil, err
			}
			e.Text = string(bytes)
			return e, nil
		}
		value := frame["result"]
		if value == nil {
			value = frame["partialResult"]
		}
		result, err := piRecord(value, "tool result")
		if err != nil {
			return nil, err
		}
		e.Text, err = piContent(result["content"], "text")
		if err != nil {
			return nil, err
		}
		if details, ok := result["details"].(map[string]any); ok && e.Phase == "end" && e.Name == "todo" && !e.IsError {
			if _, hasError := details["error"]; !hasError {
				e.Todos = piTodos(details["todos"])
			}
		}
		return e, nil
	case "extension_ui_request":
		method, err := piText(frame["method"], "interaction method")
		if err != nil {
			return nil, err
		}
		switch method {
		case "notify", "setStatus", "setWidget", "setTitle", "set_editor_text":
			e := &Event{Type: "notification", Method: method}
			value, hasValue := frame["text"]
			for _, key := range []string{"message", "statusText", "title"} {
				if frame[key] != nil {
					value = frame[key]
					hasValue = true
					break
				}
			}
			if hasValue {
				e.Text, err = piText(value, "notification text")
			} else if value, exists := frame["widgetLines"]; exists {
				var lines []string
				lines, err = piStrings(value, "widget lines")
				e.Text = strings.Join(lines, "\n")
			}
			return e, err
		case "confirm", "select", "input", "editor":
		default:
			return nil, fmt.Errorf("unsupported Pi interaction: %s", method)
		}
		e := &Event{Type: "interaction", Method: method, Options: []string{}}
		e.ID, err = piIdentifier(frame["id"], "interaction ID")
		if err != nil {
			return nil, err
		}
		e.Title, err = piOptionalText(frame, "title", "interaction title")
		if err != nil {
			return nil, err
		}
		if method == "editor" {
			if value, exists := frame["prefill"]; exists {
				prefill, err := piText(value, "editor prefill")
				if err != nil {
					return nil, err
				}
				e.Prefill = &prefill
			}
		}
		e.Message, err = piOptionalText(frame, "message", "interaction message")
		if err != nil {
			return nil, err
		}
		if value, exists := frame["options"]; exists {
			e.Options, err = piStrings(value, "interaction options")
			if err != nil {
				return nil, err
			}
		}
		if value, exists := frame["timeout"]; exists {
			n, err := piNumber(value, "interaction timeout")
			if err != nil {
				return nil, err
			}
			e.Timeout = &n
		}
		return e, nil
	}
	return nil, nil
}

type eventDecoder struct {
	assistant map[string]any
	blocks    map[int64]map[string]any
}

func (d *eventDecoder) reset() { d.assistant = nil; d.blocks = nil }

// Pi 1.0 emits delta-only message updates. Accumulation belongs to one native
// session, and partial tool argument JSON must never become executable input.
func (d *eventDecoder) decode(frame map[string]any) (*Event, error) {
	if _, exists := frame["message"]; frame["type"] == "message_update" && !exists {
		delta, err := piRecord(frame["assistantMessageEvent"], "assistant message delta")
		if err != nil {
			return nil, err
		}
		typ, err := piText(delta["type"], "assistant delta type")
		if err != nil {
			return nil, err
		}
		kind, phase, ok := strings.Cut(typ, "_")
		if !ok || (kind != "text" && kind != "thinking") || (phase != "start" && phase != "delta" && phase != "end") {
			return nil, nil
		}
		if d.assistant == nil {
			return nil, fmt.Errorf("Pi assistant delta arrived without a message start")
		}
		index, err := piCount(delta["contentIndex"], "content index")
		if err != nil {
			return nil, err
		}
		previous := d.blocks[index]
		if previous != nil && previous["type"] != kind {
			return nil, fmt.Errorf("Pi assistant content type changed while streaming")
		}
		value := ""
		if phase == "end" {
			value, err = piText(delta["content"], "completed content")
		} else if phase == "delta" {
			if previous != nil {
				value, err = piText(previous[kind], "accumulated content")
				if err != nil {
					return nil, err
				}
			}
			part, partErr := piText(delta["delta"], "content delta")
			err = partErr
			value += part
		}
		if err != nil {
			return nil, err
		}
		d.blocks[index] = map[string]any{"type": kind, kind: value}
		indexes := make([]int64, 0, len(d.blocks))
		for index := range d.blocks {
			indexes = append(indexes, index)
		}
		sort.Slice(indexes, func(i, j int) bool { return indexes[i] < indexes[j] })
		content := make([]any, 0, len(indexes))
		for _, index := range indexes {
			content = append(content, d.blocks[index])
		}
		message := cloneRecord(d.assistant)
		message["content"] = content
		out := cloneRecord(frame)
		out["message"] = message
		return decodeEvent(out)
	}
	event, err := decodeEvent(frame)
	if err != nil || event == nil {
		return event, err
	}
	if event.Type == "assistant" {
		d.reset()
		if event.Phase != "end" {
			d.assistant, _ = piRecord(frame["message"], "message")
			d.blocks = map[int64]map[string]any{}
			if content, ok := d.assistant["content"].([]any); ok {
				for index, block := range content {
					item, _ := piRecord(block, "content block")
					if item["type"] == "text" || item["type"] == "thinking" {
						d.blocks[int64(index)] = cloneRecord(item)
					}
				}
			}
		}
	} else if event.Type == "settled" || event.Type == "started" {
		d.reset()
	}
	return event, nil
}

func cloneRecord(source map[string]any) map[string]any {
	result := make(map[string]any, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func decodeModel(value any) (Model, error) {
	source, err := piRecord(value, "model")
	if err != nil {
		return Model{}, err
	}
	m := Model{}
	m.ID, err = piIdentifier(source["id"], "model ID")
	if err != nil {
		return m, err
	}
	m.Provider, err = piIdentifier(source["provider"], "model provider")
	if err != nil {
		return m, err
	}
	m.Name, err = piOptionalText(source, "name", "model name")
	if err != nil {
		return m, err
	}
	if _, exists := source["name"]; !exists {
		m.Name = m.ID
	}
	if value, exists := source["input"]; exists {
		m.Input, err = piStrings(value, "model input modalities")
		if err != nil {
			return m, err
		}
	}
	if value, exists := source["api"]; exists {
		m.API, err = piIdentifier(value, "model API")
		if err != nil {
			return m, err
		}
	}
	if value, exists := source["reasoning"]; exists {
		flag, ok := value.(bool)
		if !ok {
			return m, fmt.Errorf("invalid Pi model reasoning flag")
		}
		m.Reasoning = &flag
	}
	if value, exists := source["thinkingLevelMap"]; exists {
		levels, err := piRecord(value, "thinking level map")
		if err != nil {
			return m, err
		}
		m.ThinkingLevelMap = make(map[string]*string, len(levels))
		for level, value := range levels {
			if value == nil {
				m.ThinkingLevelMap[level] = nil
				continue
			}
			mapped, ok := value.(string)
			if !ok || mapped == "" {
				return m, fmt.Errorf("invalid Pi thinking level mapping")
			}
			m.ThinkingLevelMap[level] = &mapped
		}
	}
	if value, exists := source["samplingParams"]; exists {
		params, err := piRecord(value, "model request overrides")
		if err != nil {
			return m, err
		}
		m.HasRequestOverrides = len(params) > 0
	}
	if value, exists := source["compat"]; exists {
		compat, err := piRecord(value, "model compatibility")
		if err != nil {
			return m, err
		}
		if value, exists := compat["thinkingFormat"]; exists {
			m.ThinkingFormat, err = piIdentifier(value, "thinking format")
			if err != nil {
				return m, err
			}
		}
		if value, exists := compat["supportsReasoningEffort"]; exists {
			flag, ok := value.(bool)
			if !ok {
				return m, fmt.Errorf("invalid Pi effort forwarding flag")
			}
			m.SupportsReasoningEffort = &flag
		}
	}
	m.BaseURL, err = piOptionalText(source, "baseUrl", "model endpoint")
	if err == nil && m.API == "openai-completions" && m.SupportsReasoningEffort == nil {
		// Resolve URL-sensitive native defaults before catalogs redact BaseURL.
		forwarding := forwardsChatEffort(m)
		m.SupportsReasoningEffort = &forwarding
	}
	return m, err
}

func decodeNativeState(source map[string]any) (NativeState, error) {
	s := NativeState{}
	var err error
	for _, entry := range []struct {
		key string
		out *string
	}{{"sessionFile", &s.SessionFile}, {"sessionId", &s.SessionID}, {"thinkingLevel", &s.ThinkingLevel}} {
		*entry.out, err = piOptionalText(source, entry.key, entry.key)
		if err != nil {
			return s, err
		}
	}
	if value := source["model"]; value != nil {
		m, err := decodeModel(value)
		if err != nil {
			return s, err
		}
		s.Model = &m
	}
	return s, nil
}

func decodeModels(source map[string]any) ([]Model, error) {
	values, ok := source["models"].([]any)
	if !ok {
		return nil, fmt.Errorf("invalid Pi model catalog")
	}
	models := make([]Model, 0, len(values))
	for _, value := range values {
		m, err := decodeModel(value)
		if err != nil {
			return nil, err
		}
		m.BaseURL = ""
		models = append(models, m)
	}
	return models, nil
}

func decodeCommands(source map[string]any) ([]Command, error) {
	values, ok := source["commands"].([]any)
	if !ok {
		return nil, fmt.Errorf("invalid Pi command catalog")
	}
	commands := make([]Command, 0, len(values))
	for _, value := range values {
		entry, err := piRecord(value, "command")
		if err != nil {
			return nil, err
		}
		command := Command{}
		command.Name, err = piIdentifier(entry["name"], "command name")
		if err != nil {
			return nil, err
		}
		command.Source, err = piText(entry["source"], "command source")
		if err != nil {
			return nil, err
		}
		if value, exists := entry["sourceInfo"]; exists {
			info, err := piRecord(value, "command source")
			if err != nil {
				return nil, err
			}
			command.SourcePath, err = piOptionalText(info, "path", "command source path")
			if err != nil {
				return nil, err
			}
		}
		commands = append(commands, command)
	}
	return commands, nil
}
