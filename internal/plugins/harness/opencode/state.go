package opencode

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Usage struct {
	Input      float64  `json:"input"`
	Output     float64  `json:"output"`
	CacheRead  float64  `json:"cacheRead"`
	CacheWrite float64  `json:"cacheWrite"`
	Reasoning  float64  `json:"reasoning,omitempty"`
	Cost       *float64 `json:"cost,omitempty"`
}
type Message struct {
	ID              string          `json:"id"`
	ExecutionID     string          `json:"executionId"`
	Role            string          `json:"role"`
	Text            string          `json:"text"`
	NativeSessionID string          `json:"nativeSessionId,omitempty"`
	NativeMessageID string          `json:"nativeMessageId,omitempty"`
	CreatedAt       int64           `json:"createdAt,omitempty"`
	Status          string          `json:"status,omitempty"`
	Thinking        string          `json:"thinking,omitempty"`
	Parts           []Part          `json:"parts,omitempty"`
	ToolCallID      string          `json:"toolCallId,omitempty"`
	ToolName        string          `json:"toolName,omitempty"`
	Arguments       any             `json:"arguments,omitempty"`
	Result          any             `json:"result,omitempty"`
	Metadata        Object          `json:"metadata,omitempty"`
	IsError         bool            `json:"isError,omitempty"`
	Model           string          `json:"model,omitempty"`
	Provider        string          `json:"provider,omitempty"`
	Variant         string          `json:"variant,omitempty"`
	Usage           *Usage          `json:"usage,omitempty"`
	Inherited       bool            `json:"inherited,omitempty"`
	Annotations     json.RawMessage `json:"annotations,omitempty"`
	Todos           []Object        `json:"todos,omitempty"`
	Attachments     []Object        `json:"attachments,omitempty"`
}
type Part struct {
	Type       string `json:"type"`
	Ordinal    int    `json:"ordinal,omitempty"`
	Text       string `json:"text,omitempty"`
	ToolCallID string `json:"toolCallId,omitempty"`
}

func (part Part) MarshalJSON() ([]byte, error) {
	if part.Type == "tool" {
		return json.Marshal(Object{"type": "tool", "toolCallId": part.ToolCallID})
	}
	return json.Marshal(Object{"type": part.Type, "ordinal": part.Ordinal, "text": part.Text})
}

type Interaction struct {
	ID          string   `json:"id"`
	ExecutionID string   `json:"executionId"`
	SessionID   string   `json:"sessionId"`
	Kind        string   `json:"kind"`
	Title       string   `json:"title"`
	Status      string   `json:"status"`
	Action      string   `json:"action,omitempty"`
	Resources   []string `json:"resources,omitempty"`
	Save        []string `json:"save,omitempty"`
	Description string   `json:"description,omitempty"`
	Fields      []Object `json:"fields,omitempty"`
	Metadata    Object   `json:"metadata,omitempty"`
}
type BackgroundSession struct {
	SessionID string `json:"sessionId"`
	Status    string `json:"status"`
}
type BackgroundShell struct {
	ShellID   string `json:"shellId"`
	SessionID string `json:"sessionId"`
	Status    string `json:"status"`
}
type AuxiliaryUsage struct {
	ID              string `json:"id"`
	NativeSessionID string `json:"nativeSessionId"`
	CreatedAt       int64  `json:"createdAt"`
	ExecutionID     string `json:"executionId"`
	Kind            string `json:"kind"`
	Usage           Usage  `json:"usage"`
	Provider        string `json:"provider,omitempty"`
	Model           string `json:"model,omitempty"`
}
type ForkSource struct {
	SessionID  string `json:"sessionId"`
	MessageID  string `json:"messageId,omitempty"`
	Transcript Object `json:"transcript"`
}
type State struct {
	Version              int                      `json:"version"`
	NativeSessionID      string                   `json:"nativeSessionId,omitempty"`
	NativeSessionCreated bool                     `json:"nativeSessionCreated,omitempty"`
	NativeReadPrefix     Object                   `json:"nativeReadPrefix,omitempty"`
	NativeTranscript     Object                   `json:"nativeTranscript,omitempty"`
	NativeContextEntries []plugin.ContextEntry    `json:"nativeContextEntries,omitempty"`
	ForkSource           *ForkSource              `json:"forkSource,omitempty"`
	Messages             []*Message               `json:"messages"`
	ExecutionAuthors     map[string]Object        `json:"executionAuthors,omitempty"`
	Executions           []*model.PublicExecution `json:"executions"`
	LatestExecutionID    *string                  `json:"latestExecutionId"`
	Interactions         []*Interaction           `json:"interactions"`
	BackgroundSessions   []BackgroundSession      `json:"backgroundSessions,omitempty"`
	BackgroundShells     []BackgroundShell        `json:"backgroundShells,omitempty"`
	Cursors              map[string]int64         `json:"cursors,omitempty"`
	NativeExecutions     map[string]string        `json:"nativeExecutions,omitempty"`
	AutomaticExecutions  map[string][]string      `json:"automaticExecutions,omitempty"`
	AuxiliaryUsage       []AuxiliaryUsage         `json:"auxiliaryUsage,omitempty"`
	UsageRecorded        []string                 `json:"usageRecorded,omitempty"`
	Foregrounds          []Object                 `json:"foregrounds,omitempty"`
}

func DecodeState(raw json.RawMessage) (*State, error) {
	s := &State{Version: 1, Messages: []*Message{}, Executions: []*model.PublicExecution{}, Interactions: []*Interaction{}}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, s); err != nil {
			return nil, err
		}
		if s.Version != 1 {
			return nil, errors.New("unsupported OpenCode state version")
		}
	}
	if s.NativeExecutions == nil {
		s.NativeExecutions = map[string]string{}
	}
	if s.Cursors == nil {
		s.Cursors = map[string]int64{}
	}
	if s.AutomaticExecutions == nil {
		s.AutomaticExecutions = map[string][]string{}
	}
	if s.ExecutionAuthors == nil {
		s.ExecutionAuthors = map[string]Object{}
	}
	ids := map[string]bool{}
	for _, v := range s.Messages {
		if v == nil || v.ID == "" || v.ExecutionID == "" || ids[v.ID] || (v.Role != "assistant" && v.Role != "user" && v.Role != "tool") {
			return nil, errors.New("invalid OpenCode message state")
		}
		ids[v.ID] = true
	}
	ids = map[string]bool{}
	for _, v := range s.Executions {
		if v == nil || v.ExecutionID == "" || ids[v.ExecutionID] {
			return nil, errors.New("invalid OpenCode execution state")
		}
		ids[v.ExecutionID] = true
	}
	if s.LatestExecutionID != nil && !ids[*s.LatestExecutionID] {
		return nil, errors.New("OpenCode latest execution is missing")
	}
	for _, v := range s.Interactions {
		if v == nil || v.ID == "" || v.ExecutionID == "" || v.SessionID == "" {
			return nil, errors.New("invalid OpenCode interaction state")
		}
		if v.Kind == "form" {
			if err := ValidateFields(v.Fields); err != nil {
				return nil, err
			}
		}
	}
	return s, nil
}
func (s *State) Encode() json.RawMessage { b, _ := json.Marshal(s); return b }
func (s *State) Current() *model.PublicExecution {
	if s.LatestExecutionID != nil {
		for _, e := range s.Executions {
			if e.ExecutionID == *s.LatestExecutionID {
				return e
			}
		}
	}
	return nil
}
func (s *State) Active() *model.PublicExecution {
	e := s.Current()
	if e != nil && !e.Terminal() {
		return e
	}
	return nil
}
func (s *State) Begin(id string, at int64) error {
	for _, v := range s.Executions {
		if v.ExecutionID == id {
			return errors.New("execution already exists")
		}
	}
	s.Executions = append(s.Executions, &model.PublicExecution{ExecutionID: id, Status: "running", StartedAt: at})
	s.LatestExecutionID = &id
	return nil
}
func (s *State) Settle(id, outcome string, at int64, reason string) {
	for _, e := range s.Executions {
		if e.ExecutionID != id || e.Terminal() {
			continue
		}
		e.Status = outcome
		at = max(at, e.StartedAt)
		e.FinishedAt = &at
		e.Interactions = nil
		for i := len(s.Messages) - 1; i >= 0; i-- {
			m := s.Messages[i]
			if m.ExecutionID == id && m.Role == "assistant" && (m.NativeSessionID == "" || m.NativeSessionID == s.NativeSessionID) && strings.TrimSpace(m.Text) != "" {
				text := clip(m.Text, 100000)
				e.Summary = &text
				break
			}
		}
		if outcome == "failed" && reason != "" {
			reason = clip(reason, 100000)
			e.Error = &reason
		}
	}
	for _, v := range s.Interactions {
		if v.ExecutionID == id && v.Status == "pending" {
			v.Status = "cancelled"
		}
	}
	for _, m := range s.Messages {
		if m.ExecutionID == id && m.Status == "streaming" {
			background := false
			for _, b := range s.BackgroundSessions {
				if b.SessionID == m.NativeSessionID && b.Status == "running" {
					background = true
				}
			}
			if !background {
				m.Status = map[string]string{"completed": "complete", "failed": "failed", "interrupted": "cancelled"}[outcome]
			}
		}
	}
}
func (s *State) RefreshInteractions(id string) {
	for _, e := range s.Executions {
		if e.ExecutionID != id || e.Terminal() {
			continue
		}
		e.Interactions = nil
		for _, v := range s.Interactions {
			if v.ExecutionID == id && v.Status == "pending" {
				e.Interactions = append(e.Interactions, publicInteraction(v))
			}
		}
		e.Status = "running"
		if len(e.Interactions) > 0 {
			e.Status = "waiting-for-user"
		}
	}
}
func (s *State) message(role, id, session string) *Message {
	for _, m := range s.Messages {
		if m.Role == role && (m.ID == id || (m.NativeMessageID == id && (m.NativeSessionID == "" || m.NativeSessionID == session))) {
			return m
		}
	}
	return nil
}
func (s *State) assistant(id, session, execution string, at int64) *Message {
	if m := s.message("assistant", id, session); m != nil {
		return m
	}
	if execution == "" {
		return nil
	}
	m := &Message{ID: id, NativeMessageID: id, NativeSessionID: session, ExecutionID: execution, Role: "assistant", Status: "streaming", CreatedAt: at, Parts: []Part{}}
	s.Messages = append(s.Messages, m)
	return m
}
func (s *State) tool(m *Message, id string, at int64) *Message {
	key := m.ID + ":tool:" + id
	for _, v := range s.Messages {
		if v.ID == key {
			return v
		}
	}
	t := &Message{ID: key, NativeMessageID: m.NativeMessageID, NativeSessionID: m.NativeSessionID, ExecutionID: m.ExecutionID, Role: "tool", ToolCallID: id, Status: "streaming", CreatedAt: at, Inherited: m.Inherited}
	s.Messages = append(s.Messages, t)
	m.Parts = append(m.Parts, Part{Type: "tool", ToolCallID: id})
	return t
}
func segment(m *Message, kind string, ordinal int, text string, replace bool) {
	found := -1
	for i, v := range m.Parts {
		if v.Type == kind && v.Ordinal == ordinal {
			found = i
			break
		}
	}
	if found < 0 {
		m.Parts = append(m.Parts, Part{Type: kind, Ordinal: ordinal})
		found = len(m.Parts) - 1
	}
	if replace {
		m.Parts[found].Text = text
	} else {
		m.Parts[found].Text += text
	}
	m.Text = ""
	m.Thinking = ""
	for _, p := range m.Parts {
		if p.Type == "text" {
			m.Text += p.Text
		} else if p.Type == "reasoning" {
			m.Thinking += p.Text
		}
	}
}
func nativeUsage(tokens any, cost any) *Usage {
	t := object(tokens)
	cache := object(t["cache"])
	for _, v := range []any{t["input"], t["output"], t["reasoning"], cache["read"], cache["write"]} {
		if _, ok := v.(float64); !ok || number(v) < 0 {
			return nil
		}
	}
	usage := &Usage{Input: number(t["input"]), Output: number(t["output"]), CacheRead: number(cache["read"]), CacheWrite: number(cache["write"]), Reasoning: number(t["reasoning"])}
	if amount, ok := cost.(float64); ok && amount >= 0 && !math.IsNaN(amount) && !math.IsInf(amount, 0) {
		usage.Cost = &amount
	}
	return usage
}
func contentText(value any) string {
	parts := []string{}
	for _, v := range array(value) {
		p := object(v)
		if p["type"] == "text" {
			parts = append(parts, str(p["text"]))
		} else if p["type"] == "file" {
			parts = append(parts, str(p["name"])+": "+str(p["uri"]))
		}
	}
	return strings.Join(parts, "\n")
}
func toolResult(t *Message, content, nativeError, metadata any) {
	t.Result = content
	t.Text = contentText(content)
	t.Metadata = object(metadata)
	t.Status = "complete"
	if nativeError != nil {
		t.IsError = true
		t.Status = "failed"
		t.Text = strings.TrimSpace(t.Text + "\n" + nativeFailure(nativeError))
		t.Result = Object{"content": content, "error": nativeError}
	}
	if !t.IsError && (t.ToolName == "todo" || t.ToolName == "todowrite") {
		for i, v := range array(object(t.Arguments)["todos"]) {
			o := object(v)
			id := str(o["id"])
			if id == "" {
				id = fmt.Sprint(i)
			}
			t.Todos = append(t.Todos, Object{"id": id, "text": str(o["content"]), "done": o["status"] == "completed"})
		}
	}
}
func (s *State) MergeMessages(messages []any, session, execution string, inherited bool) {
	for _, value := range messages {
		v := object(value)
		id := str(v["id"])
		if id == "" {
			continue
		}
		kind := str(v["type"])
		known := s.message(kind, id, session)
		owner := execution
		if known != nil {
			owner = known.ExecutionID
		}
		if owner == "" {
			continue
		}
		at := int64(number(object(v["time"])["created"]))
		if kind == "user" {
			if known == nil {
				s.Messages = append(s.Messages, &Message{ID: id, NativeMessageID: id, NativeSessionID: session, ExecutionID: owner, Role: "user", Text: str(v["text"]), CreatedAt: at, Inherited: inherited})
			} else {
				known.NativeMessageID = id
				known.NativeSessionID = session
			}
			continue
		}
		if kind != "assistant" {
			continue
		}
		m := s.assistant(id, session, owner, at)
		m.Inherited = m.Inherited || inherited
		ref := object(v["model"])
		m.Provider = str(ref["providerID"])
		m.Model = str(ref["id"])
		m.Variant = str(ref["variant"])
		m.Usage = nativeUsage(v["tokens"], v["cost"])
		if v["error"] != nil {
			m.Status = "failed"
		} else if object(v["time"])["completed"] != nil {
			m.Status = "complete"
		}
		m.Parts = []Part{}
		m.Text = ""
		m.Thinking = ""
		ordinals := map[string]int{}
		for _, part := range array(v["content"]) {
			p := object(part)
			t := str(p["type"])
			if t == "text" || t == "reasoning" {
				segment(m, t, ordinals[t], str(p["text"]), true)
				ordinals[t]++
			} else if t == "tool" {
				tool := s.tool(m, str(p["id"]), at)
				present := false
				for _, part := range m.Parts {
					if part.Type == "tool" && part.ToolCallID == str(p["id"]) {
						present = true
					}
				}
				if !present {
					m.Parts = append(m.Parts, Part{Type: "tool", ToolCallID: str(p["id"])})
				}
				tool.ToolName = str(p["name"])
				tool.Inherited = m.Inherited
				state := object(p["state"])
				tool.Arguments = state["input"]
				tool.Status = "streaming"
				if state["status"] == "completed" || state["status"] == "error" {
					toolResult(tool, state["content"], state["error"], state["metadata"])
				}
			}
		}
	}
}
func (s *State) background(id, status string) {
	if id == s.NativeSessionID {
		return
	}
	for i, v := range s.BackgroundSessions {
		if v.SessionID == id {
			s.BackgroundSessions[i].Status = status
			return
		}
	}
	s.BackgroundSessions = append(s.BackgroundSessions, BackgroundSession{id, status})
}
func (s *State) Reduce(event Event, owner string) error {
	if event.Durable != nil {
		d := event.Durable
		if prev, ok := s.Cursors[d.AggregateID]; ok && prev >= d.Seq {
			return nil
		}
		s.Cursors[d.AggregateID] = d.Seq
	}
	data := event.Data
	session := str(data["sessionID"])
	t := event.Type
	if t == "permission.asked" || t == "form.created" {
		if owner == "" {
			return nil
		}
		var interaction *Interaction
		var err error
		if t == "permission.asked" {
			interaction, err = parsePermission(data, owner)
		} else {
			interaction, err = parseForm(object(data["form"]), owner)
		}
		if err != nil {
			return err
		}
		found := false
		for _, v := range s.Interactions {
			if v.ID == interaction.ID && v.ExecutionID == owner {
				found = true
			}
		}
		if !found {
			s.Interactions = append(s.Interactions, interaction)
		}
		s.RefreshInteractions(owner)
		return nil
	}
	if t == "permission.replied" || t == "form.replied" || t == "form.cancelled" {
		id := str(data["id"])
		if t == "permission.replied" {
			id = str(data["requestID"])
		}
		for _, v := range s.Interactions {
			if v.ID == id && (session == "" || v.SessionID == session) && v.Status == "pending" {
				v.Status = "answered"
				if t == "form.cancelled" {
					v.Status = "cancelled"
				}
				s.RefreshInteractions(v.ExecutionID)
			}
		}
		return nil
	}
	if t == "session.status" {
		status := "running"
		if object(data["status"])["type"] == "idle" {
			status = "idle"
		}
		s.background(session, status)
	}
	if strings.HasPrefix(t, "session.execution.") || t == "session.idle" || t == "session.deleted" {
		status := "idle"
		if t == "session.execution.started" {
			status = "running"
		}
		s.background(session, status)
	}
	if t == "session.shell.started" || t == "session.shell.ended" {
		shell := str(object(data["shell"])["id"])
		status := "idle"
		if t == "session.shell.started" {
			status = "running"
		}
		found := false
		for i, v := range s.BackgroundShells {
			if v.ShellID == shell {
				s.BackgroundShells[i].Status = status
				found = true
			}
		}
		if !found {
			s.BackgroundShells = append(s.BackgroundShells, BackgroundShell{shell, session, status})
		}
	}
	if t == "shell.created" {
		info := object(data["info"])
		session = str(object(info["metadata"])["sessionID"])
		if session != "" {
			found := false
			for i, previous := range s.BackgroundShells {
				if previous.ShellID == str(info["id"]) {
					s.BackgroundShells[i].Status = str(info["status"])
					found = true
				}
			}
			if !found {
				s.BackgroundShells = append(s.BackgroundShells, BackgroundShell{str(info["id"]), session, str(info["status"])})
			}
		}
	}
	if t == "shell.exited" || t == "shell.deleted" {
		for i, v := range s.BackgroundShells {
			if v.ShellID == str(data["id"]) {
				s.BackgroundShells[i].Status = "idle"
			}
		}
	}
	if t == "session.inbox.enqueued" && owner != "" {
		item := object(data["item"])
		id := str(data["inboxID"])
		if item["type"] == "user" && s.message("user", id, session) == nil {
			s.Messages = append(s.Messages, &Message{ID: id, NativeMessageID: id, NativeSessionID: session, ExecutionID: owner, Role: "user", Text: str(object(item["payload"])["text"]), CreatedAt: event.Created})
		}
	}
	if (t == "session.compaction.ended" || t == "session.compaction.failed") && owner != "" {
		if u := nativeUsage(data["tokens"], data["cost"]); u != nil {
			id := "compaction:" + event.ID
			found := false
			for _, v := range s.AuxiliaryUsage {
				if v.ID == id {
					found = true
				}
			}
			if !found {
				ref := object(data["model"])
				s.AuxiliaryUsage = append(s.AuxiliaryUsage, AuxiliaryUsage{id, session, event.Created, owner, "compaction", *u, str(ref["providerID"]), str(ref["id"])})
			}
		}
	}
	id := str(data["assistantMessageID"])
	if id == "" || session == "" {
		return nil
	}
	m := s.assistant(id, session, owner, event.Created)
	if m == nil {
		return nil
	}
	if t == "session.step.started" {
		ref := object(data["model"])
		m.Provider = str(ref["providerID"])
		m.Model = str(ref["id"])
		m.Variant = str(ref["variant"])
	}
	if t == "session.step.ended" || t == "session.step.failed" {
		m.Status = "complete"
		if t == "session.step.failed" {
			m.Status = "failed"
		}
		m.Usage = nativeUsage(data["tokens"], data["cost"])
	}
	if strings.HasPrefix(t, "session.text.") || strings.HasPrefix(t, "session.reasoning.") {
		kind := "text"
		if strings.HasPrefix(t, "session.reasoning.") {
			kind = "reasoning"
		}
		text := ""
		if strings.HasSuffix(t, ".delta") {
			text = str(data["delta"])
		} else if strings.HasSuffix(t, ".ended") {
			text = str(data["text"])
		}
		ordinal := int(number(data["ordinal"]))
		existing := false
		if strings.HasSuffix(t, ".started") {
			for _, part := range m.Parts {
				if part.Type == kind && part.Ordinal == ordinal {
					existing = true
					break
				}
			}
		}
		// A buffered start can arrive after a newer full snapshot during reconnect.
		// It initializes a missing segment but cannot erase recovered text.
		if !existing {
			segment(m, kind, ordinal, text, !strings.HasSuffix(t, ".delta"))
		}
	}
	if strings.HasPrefix(t, "session.tool.") {
		tool := s.tool(m, str(data["id"]), event.Created)
		if name := str(data["name"]); name != "" {
			tool.ToolName = name
		}
		switch t {
		case "session.tool.input.delta":
			tool.Arguments = str(tool.Arguments) + str(data["delta"])
		case "session.tool.input.ended":
			tool.Arguments = str(data["text"])
		case "session.tool.called":
			tool.Arguments = data["input"]
		case "session.tool.progress":
			tool.Metadata = object(data["metadata"])
		case "session.tool.success":
			toolResult(tool, data["content"], nil, data["metadata"])
		case "session.tool.failed":
			toolResult(tool, data["content"], data["error"], data["metadata"])
		}
	}
	return nil
}
func nativeFailure(value any) string {
	o := object(value)
	if message := str(o["message"]); message != "" {
		return message
	}
	if response := object(o["response"]); str(response["body"]) != "" {
		var body Object
		if json.Unmarshal([]byte(str(response["body"])), &body) == nil {
			if message := str(object(body["error"])["message"]); message != "" {
				return message
			}
		}
	}
	if t := str(o["type"]); t != "" {
		return t
	}
	if text := str(value); text != "" {
		return text
	}
	return "OpenCode execution failed"
}
func clip(s string, n int) string {
	s = strings.ReplaceAll(s, "\x00", "")
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

var identityMu sync.Mutex
var identityTime int64
var identityCounter uint64

// NewSessionID ports @opencode/schema 2.0.25's descending identifier allocator.
func NewSessionID() string {
	identityMu.Lock()
	at := time.Now().UnixMilli()
	if at != identityTime {
		identityTime = at
		identityCounter = 0
	}
	identityCounter++
	value := ^(uint64(at)*0x1000 + identityCounter)
	identityMu.Unlock()
	prefix := make([]byte, 6)
	for i := range prefix {
		prefix[i] = byte(value >> uint(40-8*i))
	}
	random := make([]byte, 14)
	if _, err := rand.Read(random); err != nil {
		panic(err)
	}
	const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	for i, v := range random {
		random[i] = alphabet[int(v)%len(alphabet)]
	}
	return "ses_" + hex.EncodeToString(prefix) + string(random)
}
func newMessageID() string { return "msg_" + strings.TrimPrefix(NewSessionID(), "ses_") }

type StateAdapter struct{}

func (StateAdapter) Project(raw json.RawMessage) (model.PublicObservation, error) {
	s, err := DecodeState(raw)
	if err != nil {
		return model.PublicObservation{}, err
	}
	out := model.PublicObservation{LatestExecution: s.Current()}
	for _, v := range s.BackgroundSessions {
		if v.Status == "running" {
			out.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
		}
	}
	for _, v := range s.BackgroundShells {
		if v.Status == "running" {
			out.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
		}
	}
	return out, nil
}
func (StateAdapter) ReadContext(raw json.RawMessage) (json.RawMessage, error) {
	s, err := DecodeState(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(Object{"messages": s.Messages, "executions": s.Executions})
}
func (StateAdapter) ResolveExecution(raw json.RawMessage, id string) (*model.PublicExecution, error) {
	s, err := DecodeState(raw)
	if err != nil {
		return nil, err
	}
	for _, e := range s.Executions {
		if e.ExecutionID == id {
			return e, nil
		}
	}
	return nil, nil
}
func (StateAdapter) Settle(req plugin.SettleRequest) (json.RawMessage, error) {
	s, err := DecodeState(req.SessionState)
	if err != nil {
		return nil, err
	}
	s.Settle(req.ExecutionID, req.Outcome, req.FinishedAt, "")
	return s.Encode(), nil
}

func display(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b)
}
