package pi

import (
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"slices"
	"strings"
)

type MessageState struct {
	ID          string          `json:"id"`
	ExecutionID string          `json:"executionId"`
	Role        string          `json:"role"`
	Text        string          `json:"text"`
	Status      string          `json:"status,omitempty"`
	Thinking    string          `json:"thinking,omitempty"`
	ToolCallID  string          `json:"toolCallId,omitempty"`
	ToolName    string          `json:"toolName,omitempty"`
	IsError     bool            `json:"isError,omitempty"`
	Todos       []Todo          `json:"todos,omitzero"`
	Model       string          `json:"model,omitempty"`
	Provider    string          `json:"provider,omitempty"`
	Usage       *Usage          `json:"usage,omitempty"`
	Annotations json.RawMessage `json:"annotations,omitempty"`
}
type ForkSource struct {
	JSONL string `json:"jsonl"`
}
type ForegroundState struct {
	ExecutionID string                `json:"executionId"`
	Foreground  model.HarnessActivity `json:"foreground"`
}
type State struct {
	Version            int                        `json:"version"`
	SessionFile        string                     `json:"sessionFile,omitempty"`
	NativeSessionJSONL string                     `json:"nativeSessionJsonl,omitempty"`
	ForkSource         *ForkSource                `json:"forkSource,omitempty"`
	Messages           []MessageState             `json:"messages"`
	Executions         []model.PublicExecution    `json:"executions"`
	ExecutionAuthors   map[string]json.RawMessage `json:"executionAuthors,omitempty"`
	LatestExecutionID  *string                    `json:"latestExecutionId"`
	Foregrounds        []ForegroundState          `json:"foregrounds,omitempty"`
}

func decodeState(raw json.RawMessage) (State, error) {
	state := State{Version: 1, Messages: []MessageState{}, Executions: []model.PublicExecution{}}
	if model.IsNull(raw) {
		return state, nil
	}
	if err := model.Unmarshal(raw, &state); err != nil {
		return state, fmt.Errorf("invalid Pi session state: %w", err)
	}
	if state.Version != 1 || state.Messages == nil || state.Executions == nil {
		return state, errors.New("invalid Pi session state version or collections")
	}
	seen := map[string]bool{}
	for _, row := range state.Messages {
		if row.ID == "" || row.ExecutionID == "" || seen[row.ID] || !slices.Contains([]string{"user", "assistant", "tool"}, row.Role) {
			return state, errors.New("invalid or duplicate Pi message")
		}
		if strings.ContainsRune(row.ID, 0) || strings.ContainsRune(row.ExecutionID, 0) || utf16Length(row.ID) > 100000 || utf16Length(row.ExecutionID) > 1024 {
			return state, errors.New("invalid Pi message identity")
		}
		if row.Role != "tool" && (row.ToolCallID != "" || row.ToolName != "" || row.IsError || row.Todos != nil) {
			return state, errors.New("non-tool Pi message carries tool fields")
		}
		if row.Role != "user" && len(row.Annotations) > 0 {
			return state, errors.New("Pi annotations belong only to user messages")
		}
		if row.Usage != nil {
			u := row.Usage
			if u.Input < 0 || u.Output < 0 || u.CacheRead < 0 || u.CacheWrite < 0 || u.Reasoning != nil && *u.Reasoning < 0 || u.Cost != nil && *u.Cost < 0 {
				return state, errors.New("invalid Pi usage")
			}
		}
		todoIDs := map[int64]bool{}
		for _, todo := range row.Todos {
			if todo.ID <= 0 || todoIDs[todo.ID] || strings.TrimSpace(todo.Text) == "" || strings.ContainsRune(todo.Text, 0) {
				return state, errors.New("invalid Pi todo")
			}
			todoIDs[todo.ID] = true
		}
		seen[row.ID] = true
		if row.Status != "" && !slices.Contains([]string{"streaming", "complete", "failed", "cancelled"}, row.Status) {
			return state, errors.New("invalid Pi message status")
		}
		if row.Role != "assistant" && (row.Usage != nil || row.Thinking != "" || row.Status != "") {
			return state, errors.New("non-assistant Pi message carries assistant fields")
		}
		if row.Todos != nil && (row.Role != "tool" || row.ToolName != "todo" || row.IsError) {
			return state, errors.New("invalid Pi todo snapshot")
		}
	}
	seen = map[string]bool{}
	for _, execution := range state.Executions {
		if execution.ExecutionID == "" || seen[execution.ExecutionID] || !slices.Contains([]string{"running", "waiting-for-user", "completed", "failed", "interrupted"}, execution.Status) || execution.StartedAt < 0 {
			return state, errors.New("invalid or duplicate Pi execution")
		}
		executionJSON, _ := json.Marshal(execution)
		if _, err := model.ParsePublicExecution(executionJSON); err != nil {
			return state, fmt.Errorf("invalid Pi public execution: %w", err)
		}
		seen[execution.ExecutionID] = true
	}
	foregroundIDs := map[string]bool{}
	for _, entry := range state.Foregrounds {
		f := entry.Foreground
		if entry.ExecutionID == "" || foregroundIDs[entry.ExecutionID] || f.Sequence < 1 || f.TextOffset < 0 {
			return state, errors.New("invalid Pi foreground")
		}
		foregroundIDs[entry.ExecutionID] = true
		switch f.Kind {
		case "reasoning":
			if len([]rune(f.Text)) > 32768 || strings.ContainsRune(f.Text, 0) {
				return state, errors.New("invalid Pi reasoning window")
			}
		case "tool-call":
			if f.CallID == "" || utf16Length(f.CallID) > 1024 || strings.TrimSpace(f.ToolName) == "" || len([]rune(f.ToolName)) > 64 {
				return state, errors.New("invalid Pi tool foreground")
			}
		case "assistant-text":
		default:
			return state, errors.New("invalid Pi activity kind")
		}
	}
	if state.LatestExecutionID != nil && !seen[*state.LatestExecutionID] {
		return state, errors.New("Pi latest execution does not exist")
	}
	return state, nil
}

// Usage belongs to one ended model call, not to the native session. In-flight
// calls have no usage yet; failed calls may report zero or omit it altogether.
func executionUsage(messages []MessageState) map[string]*Usage {
	result := map[string]*Usage{}
	for _, row := range messages {
		if row.Role != "assistant" || row.Usage == nil {
			continue
		}
		u := row.Usage
		total := result[row.ExecutionID]
		if total == nil {
			copy := *u
			result[row.ExecutionID] = &copy
			continue
		}
		total.Input += u.Input
		total.Output += u.Output
		total.CacheRead += u.CacheRead
		total.CacheWrite += u.CacheWrite
		if total.Reasoning != nil && u.Reasoning != nil {
			n := *total.Reasoning + *u.Reasoning
			total.Reasoning = &n
		} else {
			total.Reasoning = nil
		}
		if total.Cost != nil && u.Cost != nil {
			n := *total.Cost + *u.Cost
			total.Cost = &n
		} else {
			total.Cost = nil
		}
	}
	return result
}

func clean(value string, maximum int) string {
	value = strings.ReplaceAll(value, "\x00", "")
	units := 0
	for index, r := range value {
		width := 1
		if r > 0xffff {
			width = 2
		}
		if units+width > maximum {
			return value[:index]
		}
		units += width
	}
	return value
}

func lastAssistant(state State, executionID string) string {
	for i := len(state.Messages) - 1; i >= 0; i-- {
		row := state.Messages[i]
		if row.Role == "assistant" && row.ExecutionID == executionID {
			return clean(row.Text, 100000)
		}
	}
	return ""
}
func activeExecution(state *State) *model.PublicExecution {
	if state.LatestExecutionID == nil {
		return nil
	}
	for i := range state.Executions {
		e := &state.Executions[i]
		if e.ExecutionID == *state.LatestExecutionID && !e.Terminal() {
			return e
		}
	}
	return nil
}

type stateAdapter struct{}

func (stateAdapter) Project(raw json.RawMessage) (model.PublicObservation, error) {
	state, err := decodeState(raw)
	if err != nil {
		return model.PublicObservation{}, err
	}
	result := model.PublicObservation{}
	if state.LatestExecutionID != nil {
		for i := range state.Executions {
			if state.Executions[i].ExecutionID == *state.LatestExecutionID {
				result.LatestExecution = &state.Executions[i]
				break
			}
		}
	}
	return result, nil
}
func (stateAdapter) ReadContext(raw json.RawMessage) (json.RawMessage, error) {
	state, err := decodeState(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(model.Object{"messages": state.Messages, "executions": state.Executions})
}
func (stateAdapter) ResolveExecution(raw json.RawMessage, id string) (*model.PublicExecution, error) {
	state, err := decodeState(raw)
	if err != nil {
		return nil, err
	}
	for _, e := range state.Executions {
		if e.ExecutionID == id {
			return &e, nil
		}
	}
	return nil, nil
}
func (stateAdapter) Settle(input plugin.SettleRequest) (json.RawMessage, error) {
	state, err := decodeState(input.SessionState)
	if err != nil {
		return nil, err
	}
	if input.Outcome != "failed" && input.Outcome != "interrupted" {
		return nil, errors.New("invalid Pi settlement")
	}
	for i, e := range state.Executions {
		if e.ExecutionID == input.ExecutionID && !e.Terminal() {
			finish := max(e.StartedAt, input.FinishedAt)
			e.Status = input.Outcome
			e.FinishedAt = &finish
			e.Interactions = nil
			summary := lastAssistant(state, input.ExecutionID)
			if summary != "" {
				e.Summary = &summary
			}
			state.Executions[i] = e
		}
	}
	state.Foregrounds = slices.DeleteFunc(state.Foregrounds, func(f ForegroundState) bool { return f.ExecutionID == input.ExecutionID })
	return json.Marshal(state)
}
func (stateAdapter) ProjectRenderer(raw json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	state, err := decodeState(raw)
	if err != nil {
		return nil, err
	}
	// Compact scopes omit most model calls. Carry their totals separately rather
	// than turning the last message's per-call usage into an execution total.
	out := struct {
		State
		ExecutionUsage       map[string]*Usage `json:"executionUsage,omitempty"`
		InitialResponseScope *bool             `json:"initialResponseScope,omitempty"`
	}{State: State{Version: 1, Messages: []MessageState{}, Executions: []model.PublicExecution{}, LatestExecutionID: state.LatestExecutionID}}
	if scope.Kind == "turn" || scope.Kind == "execution" {
		out.LatestExecutionID = nil
		for _, e := range state.Executions {
			if e.ExecutionID == scope.Key {
				out.Executions = append(out.Executions, e)
				if state.LatestExecutionID != nil && *state.LatestExecutionID == e.ExecutionID {
					out.LatestExecutionID = state.LatestExecutionID
				}
			}
		}
		for _, row := range state.Messages {
			if row.ExecutionID == scope.Key {
				out.Messages = append(out.Messages, row)
			}
		}
		if author, ok := state.ExecutionAuthors[scope.Key]; ok {
			out.ExecutionAuthors = map[string]json.RawMessage{scope.Key: author}
		}
		for _, f := range state.Foregrounds {
			if f.ExecutionID == scope.Key {
				out.Foregrounds = append(out.Foregrounds, f)
			}
		}
		out.ExecutionUsage = executionUsage(out.Messages)
		deferred := scope.Kind == "turn" && len(out.Executions) > 0
		for _, execution := range out.Executions {
			if !execution.Terminal() {
				deferred = false
			}
		}
		if deferred {
			final := -1
			for index, row := range out.Messages {
				if row.Role == "assistant" && strings.TrimSpace(row.Text) != "" {
					final = index
				}
			}
			nonempty := []model.Object{}
			for index := range out.Messages {
				row := &out.Messages[index]
				if row.Role == "user" {
					continue
				}
				row.Todos = nil
				if index != final {
					if strings.TrimSpace(row.Text) != "" {
						nonempty = append(nonempty, model.Object{"id": row.ID, "field": "text"})
					}
					row.Text = ""
				}
				if strings.TrimSpace(row.Thinking) != "" {
					nonempty = append(nonempty, model.Object{"id": row.ID, "field": "thinking"})
				}
				row.Thinking = ""
			}
			out.Foregrounds = nil
			return json.Marshal(model.Object{"kind": "deferred-execution", "state": out, "nonempty": nonempty})
		}
		return json.Marshal(out)
	}
	if scope.Kind == "overview" {
		// A fork retains inherited executions even after its native fork source is consumed.
		initial := len(state.Executions) <= 1 && state.ForkSource == nil && (len(state.Executions) == 0 || state.LatestExecutionID != nil)
		out.InitialResponseScope = &initial
	}
	out.ExecutionUsage = executionUsage(state.Messages)
	completed := map[string]bool{}
	for _, e := range state.Executions {
		if e.Status == "completed" {
			completed[e.ExecutionID] = true
		}
	}
	latest := ""
	if state.LatestExecutionID != nil {
		latest = *state.LatestExecutionID
	}
	live := activeExecution(&state) != nil
	card, reply := -1, -1
	for i := len(state.Messages) - 1; i >= 0; i-- {
		row := state.Messages[i]
		if row.Role != "assistant" {
			continue
		}
		complete := row.Status == "complete"
		current := row.ExecutionID == latest && live
		if card < 0 && (complete || current) && (complete && strings.TrimSpace(row.Text) != "" || (completed[row.ExecutionID] || current) && strings.TrimSpace(row.Thinking) != "") {
			card = i
		}
	}
	for e := len(state.Executions) - 1; e >= 0 && reply < 0; e-- {
		execution := state.Executions[e]
		if execution.Status == "completed" {
			for i := len(state.Messages) - 1; i >= 0; i-- {
				row := state.Messages[i]
				if row.ExecutionID == execution.ExecutionID && row.Role == "assistant" && strings.TrimSpace(row.Text) != "" {
					reply = i
					break
				}
			}
		}
	}
	selected, preview := map[int]bool{}, map[int]bool{}
	for _, i := range []int{card, reply} {
		if i >= 0 {
			selected[i] = true
			preview[i] = true
		}
	}
	groups := map[string][]int{}
	for i, row := range state.Messages {
		groups[row.ExecutionID] = append(groups[row.ExecutionID], i)
	}
	for id, indexes := range groups {
		first, last, answer, usage := -1, -1, -1, -1
		for _, i := range indexes {
			row := state.Messages[i]
			if row.Role == "user" {
				if first < 0 {
					first = i
				}
				last = i
			}
			if row.Role == "assistant" {
				if strings.TrimSpace(row.Text) != "" {
					answer = i
				}
				if row.Usage != nil {
					usage = i
				}
			}
		}
		if usage >= 0 {
			selected[usage] = true
		}
		if scope.Kind == "thread" || id == latest {
			for _, i := range []int{first, last} {
				if i >= 0 {
					selected[i] = true
					preview[i] = true
				}
			}
			if scope.Kind == "thread" && answer >= 0 {
				selected[answer] = true
				preview[answer] = true
			}
		}
	}
	todo := -1
	for i := len(state.Messages) - 1; i >= 0; i-- {
		row := state.Messages[i]
		if row.ExecutionID == latest && row.Role == "tool" && row.Todos != nil {
			todo = i
			break
		}
	}
	if scope.Kind == "overview" && todo >= 0 {
		selected[todo] = true
	}
	for i, row := range state.Messages {
		if !selected[i] {
			continue
		}
		result := MessageState{ID: row.ID, ExecutionID: row.ExecutionID, Role: row.Role, Text: ""}
		if preview[i] {
			limit := 1200
			if row.Role == "user" {
				limit = 600
			}
			result.Text = clean(strings.TrimSpace(row.Text), limit)
		}
		if row.Role == "assistant" {
			result.Status = row.Status
			result.Model = row.Model
			result.Provider = row.Provider
			result.Usage = row.Usage
			if scope.Kind == "overview" && i == card && (row.Status != "complete" || strings.TrimSpace(row.Text) == "") {
				result.Thinking = clean(strings.TrimSpace(row.Thinking), 1200)
			}
		}
		if scope.Kind == "overview" && i == todo {
			result.ToolName = "todo"
			result.Todos = append([]Todo{}, row.Todos[:min(32, len(row.Todos))]...)
			for j := range result.Todos {
				result.Todos[j].Text = clean(result.Todos[j].Text, 600)
			}
		}
		out.Messages = append(out.Messages, result)
	}
	out.ExecutionAuthors = state.ExecutionAuthors
	for _, e := range state.Executions {
		if e.Summary != nil {
			if scope.Kind == "thread" || e.ExecutionID == latest {
				text := clean(*e.Summary, 600)
				e.Summary = &text
			} else {
				e.Summary = nil
			}
		}
		if e.Error != nil {
			text := clean(*e.Error, 1200)
			e.Error = &text
		}
		out.Executions = append(out.Executions, e)
	}
	if scope.Kind == "overview" {
		for _, f := range state.Foregrounds {
			if f.ExecutionID == latest {
				runes := []rune(f.Foreground.Text)
				if len(runes) > 1200 {
					f.Foreground.TextOffset += utf16Length(string(runes[:len(runes)-1200]))
					f.Foreground.Text = string(runes[len(runes)-1200:])
				}
				out.Foregrounds = append(out.Foregrounds, f)
			}
		}
	}
	return json.Marshal(out)
}

func utf16Length(text string) int64 {
	var length int64
	for _, r := range text {
		length++
		if r > 0xffff {
			length++
		}
	}
	return length
}

// The persisted foreground is the activity body plus sequence. The public
// activity's executionId belongs to the enclosing entry, never to this body;
// Swift's Pi decoder rejects extra body fields.
func (entry ForegroundState) MarshalJSON() ([]byte, error) {
	f := entry.Foreground
	body := model.Object{"sequence": f.Sequence, "kind": f.Kind}
	switch f.Kind {
	case "reasoning":
		body["text"] = f.Text
		if f.TextOffset > 0 {
			body["textOffset"] = f.TextOffset
		}
	case "tool-call":
		body["callId"] = f.CallID
		body["toolName"] = f.ToolName
	}
	return json.Marshal(model.Object{"executionId": entry.ExecutionID, "foreground": body})
}
