package codex

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type sessionStateAdapter struct{}

func NewSessionStateAdapter() plugin.SessionStateAdapter { return sessionStateAdapter{} }

func stDecodeRaw(raw json.RawMessage) (Map, error) {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return EmptyState(0), nil
	}
	var value Map
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, fmt.Errorf("Codex sessionState 无效: %w", err)
	}
	if !stValidState(value) {
		return nil, fmt.Errorf("Codex sessionState 无效")
	}
	return value, nil
}

func (sessionStateAdapter) Project(raw json.RawMessage) (model.PublicObservation, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return model.PublicObservation{}, err
	}
	encoded, err := json.Marshal(ProjectObservation(state))
	if err != nil {
		return model.PublicObservation{}, err
	}
	var result model.PublicObservation
	err = json.Unmarshal(encoded, &result)
	return result, err
}

func (sessionStateAdapter) ProjectRenderer(raw json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(ProjectRenderer(state, Map{"kind": scope.Kind, "key": scope.Key}))
}

func (sessionStateAdapter) ReadContext(raw json.RawMessage) (json.RawMessage, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(state["turns"])
}

func (sessionStateAdapter) ResolveExecution(raw json.RawMessage, id string) (*model.PublicExecution, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return nil, err
	}
	execution := ResolveExecution(state, id)
	if execution == nil {
		return nil, nil
	}
	encoded, err := json.Marshal(execution)
	if err != nil {
		return nil, err
	}
	var result model.PublicExecution
	if err := json.Unmarshal(encoded, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func (sessionStateAdapter) Settle(request plugin.SettleRequest) (json.RawMessage, error) {
	if len(request.SessionState) == 0 || strings.TrimSpace(string(request.SessionState)) == "null" {
		return json.RawMessage("null"), nil
	}
	state, err := stDecodeRaw(request.SessionState)
	if err != nil {
		return nil, err
	}
	if !stOneOf(request.Outcome, "completed", "failed", "interrupted") {
		return nil, fmt.Errorf("invalid Codex settlement outcome: %s", request.Outcome)
	}
	next := SettleExecution(state, request.ExecutionID, request.Outcome, request.FinishedAt, "")
	// Core settles only the named foreground execution; the native session may
	// still describe unrelated work and remains owned by its event consumer.
	if activity, exists := state["nativeActivity"]; exists {
		next = stClone(next)
		next["nativeActivity"] = stCloneValue(activity)
	}
	return json.Marshal(next)
}

// ProjectRenderer excludes native replay and tool-configuration data in every
// scope. An omitted scope requests the full display state for native clients.
func ProjectRenderer(state Map, scopes ...Map) Map {
	if state == nil {
		state = EmptyState(0)
	}
	base := Map{"schema": state["schema"], "updatedAt": state["updatedAt"], "backgroundTerminals": []any{}}
	if id := stString(state["primarySessionId"]); id != "" {
		base["primarySessionId"] = id
	}
	if native := stMap(state["nativeActivity"]); native != nil {
		activity := Map{"status": native["status"], "updatedAt": native["updatedAt"]}
		if detail := stString(native["detail"]); detail != "" {
			activity["detail"] = stHead(detail, 1200)
		}
		base["nativeActivity"] = activity
	}
	terminals := stArray(state["backgroundTerminals"])
	if len(terminals) > 32 {
		terminals = terminals[len(terminals)-32:]
	}
	for _, value := range terminals {
		terminal := stClone(stMap(value))
		terminal["command"], terminal["cwd"] = stHead(stString(terminal["command"]), 1200), stHead(stString(terminal["cwd"]), 1200)
		base["backgroundTerminals"] = append(stArray(base["backgroundTerminals"]), terminal)
	}
	var scope Map
	if len(scopes) > 0 {
		scope = scopes[0]
	}
	kind := stString(scope["kind"])
	turns, history := stArray(state["turns"]), stArray(state["forkHistory"])
	if kind == "overview" {
		base["initialResponseScope"] = len(turns) <= 1 && state["nativeHistorySeed"] == nil && state["forkHistory"] == nil
	}
	if kind == "turn" || kind == "execution" {
		key := stString(scope["key"])
		if strings.HasPrefix(key, "turn:") {
			key = strings.TrimPrefix(key, "turn:")
		} else {
			key = ""
		}
		current, inherited := stFindTurn(turns, key), stFindTurn(history, key)
		selected := current
		if selected == nil {
			selected = inherited
		}
		base["turns"] = []any{}
		deferred := kind == "turn" && selected != nil && !stActive(selected)
		nonempty := []any{}
		if selected != nil {
			projected := stProjectTurn(selected)
			if deferred {
				if strings.TrimSpace(stString(projected["reasoning"])) != "" {
					nonempty = append(nonempty, Map{"id": projected["executionId"], "field": "reasoning"})
				}
				projected["reasoning"] = ""
				delete(projected, "foreground")
				for _, value := range stArray(projected["timeline"]) {
					item := stMap(value)
					if item["kind"] == "reasoning" {
						if strings.TrimSpace(stString(item["content"])) != "" {
							nonempty = append(nonempty, Map{"id": item["id"], "field": "content"})
						}
						item["content"] = ""
					}
				}
				for _, value := range stArray(projected["activities"]) {
					activity := stMap(value)
					delete(activity, "detail")
					activity["label"] = ""
				}
			}
			if current != nil {
				base["turns"] = []any{projected}
			} else {
				base["forkHistory"] = []any{projected}
			}
		}
		if deferred {
			return Map{"kind": "deferred-execution", "state": base, "nonempty": nonempty}
		}
		return base
	}
	if kind == "thread" {
		base["turns"] = stCompactTurns(turns, nil, true, false)
		if len(history) > 0 {
			base["forkHistory"] = stCompactTurns(history, nil, true, false)
		}
		return base
	}
	if kind != "" && kind != "full" {
		base["turns"] = stCompactTurns(turns, stOverviewTurns(turns), false, true)
		if len(history) > 0 {
			inherited := stOverviewTurns(history)
			result := []any{}
			for i, value := range history {
				result = append(result, stCompactTurn(stMap(value), inherited[i], false, true))
			}
			base["forkHistory"] = result
		}
		return base
	}
	base["turns"] = []any{}
	for _, value := range turns {
		base["turns"] = append(stArray(base["turns"]), stProjectTurn(stMap(value)))
	}
	if len(history) > 0 {
		base["forkHistory"] = []any{}
		for _, value := range history {
			base["forkHistory"] = append(stArray(base["forkHistory"]), stProjectTurn(stMap(value)))
		}
	}
	return base
}

func stFindTurn(turns []any, id string) Map {
	for _, value := range turns {
		turn := stMap(value)
		if turn["executionId"] == id {
			return turn
		}
	}
	return nil
}
func stProjectTurn(turn Map) Map {
	result := stClone(turn)
	interactions := []any{}
	for _, value := range stArray(turn["interactions"]) {
		interactions = append(interactions, stRendererInteraction(stMap(value)))
	}
	result["interactions"] = interactions
	return result
}
func stRendererInteraction(interaction Map) Map {
	result := stClone(interaction)
	if result["kind"] == "mcp-elicitation" && stMap(result["elicitation"])["mode"] == "form" {
		result["mcpSchemaDisplay"] = stPrettyJSON(stMap(result["elicitation"])["requestedSchema"])
	}
	return result
}

func stOverviewTurns(turns []any) map[int]bool {
	result := map[int]bool{}
	if len(turns) > 0 {
		result[len(turns)-1] = true
	}
	card, reply := false, false
	for i := len(turns) - 1; i >= 0; i-- {
		turn := stMap(turns[i])
		if !card && (stCardMessage(turn) != nil || turn["status"] == "completed" && (strings.TrimSpace(stString(turn["answer"])) != "" || strings.TrimSpace(stString(turn["reasoning"])) != "")) {
			result[i], card = true, true
		}
		if !reply && turn["status"] == "completed" && stLastAssistant(turn) != nil {
			result[i], reply = true, true
		}
	}
	return result
}

func stCardMessage(turn Map) Map {
	eligible := stActive(turn) || turn["status"] == "completed"
	timeline := stArray(turn["timeline"])
	for i := len(timeline) - 1; i >= 0; i-- {
		item := stMap(timeline[i])
		if (item["kind"] == "assistant" && item["status"] == "complete" || item["kind"] == "reasoning" && eligible) && strings.TrimSpace(stString(item["content"])) != "" {
			return item
		}
	}
	return nil
}

func stLastAssistant(turn Map) Map {
	timeline := stArray(turn["timeline"])
	for i := len(timeline) - 1; i >= 0; i-- {
		item := stMap(timeline[i])
		if item["kind"] == "assistant" && strings.TrimSpace(stString(item["content"])) != "" {
			return item
		}
	}
	return nil
}

func stCompactTurns(turns []any, previews map[int]bool, all, overview bool) []any {
	result := []any{}
	for i, value := range turns {
		result = append(result, stCompactTurn(stMap(value), all || previews[i], overview && i == len(turns)-1, overview))
	}
	return result
}

func stCompactTurn(turn Map, preview, current, overview bool) Map {
	result := Map{"executionId": turn["executionId"], "createdAt": turn["createdAt"], "updatedAt": turn["updatedAt"], "status": turn["status"], "messages": []any{}, "timeline": []any{}, "answer": "", "reasoning": "", "plan": []any{}, "activities": []any{}, "interactions": []any{}, "notices": []any{}}
	for _, key := range []string{"finishedAt", "author", "runtimeModel", "runtimeServiceTier", "usage"} {
		if value, exists := turn[key]; exists {
			result[key] = stCloneValue(value)
		}
	}
	if label := stString(turn["statusLabel"]); label != "" {
		result["statusLabel"] = stHead(label, 1200)
	}
	if preview {
		messages := []Map{}
		for _, value := range stArray(turn["messages"]) {
			message := stMap(value)
			if message["role"] == "user" && message["internal"] != true {
				messages = append(messages, message)
			}
		}
		if len(messages) > 1 {
			messages = []Map{messages[0], messages[len(messages)-1]}
		}
		for _, message := range messages {
			projected := stClone(message)
			projected["content"], projected["attachments"] = stHead(stString(message["content"]), 600), []any{}
			result["messages"] = append(stArray(result["messages"]), projected)
		}
		result["answer"] = stHead(stString(turn["answer"]), 600)
		if errorText := stString(turn["error"]); errorText != "" {
			result["error"] = stHead(errorText, 1200)
		}
		if snapshot := stMap(turn["lastAssistantMessage"]); snapshot != nil {
			snapshot = stClone(snapshot)
			snapshot["text"] = stHead(stString(snapshot["text"]), 1200)
			result["lastAssistantMessage"] = snapshot
		}
		if overview {
			card := stCardMessage(turn)
			var reply Map
			if turn["status"] == "completed" {
				reply = stLastAssistant(turn)
			}
			hasText := false
			for _, value := range stArray(turn["timeline"]) {
				item := stMap(value)
				if item["kind"] == "assistant" || item["kind"] == "reasoning" {
					hasText = true
				}
				if card != nil && item["id"] == card["id"] || reply != nil && item["id"] == reply["id"] {
					projected := stClone(item)
					projected["content"] = stHead(strings.TrimSpace(stString(item["content"])), 1200)
					result["timeline"] = append(stArray(result["timeline"]), projected)
				}
			}
			if !hasText {
				result["reasoning"] = stHead(stString(turn["reasoning"]), 1200)
			}
		}
	}
	if current {
		plan := stArray(turn["plan"])
		if len(plan) > 32 {
			plan = plan[:32]
		}
		for _, value := range plan {
			step := stClone(stMap(value))
			step["step"] = stHead(stString(step["step"]), 600)
			result["plan"] = append(stArray(result["plan"]), step)
		}
		activities := stArray(turn["activities"])
		if len(activities) > 32 {
			activities = activities[len(activities)-32:]
		}
		for _, value := range activities {
			activity := stClone(stMap(value))
			delete(activity, "detail")
			activity["label"] = stHead(stString(activity["label"]), 1200)
			result["activities"] = append(stArray(result["activities"]), activity)
		}
		for _, value := range stArray(turn["interactions"]) {
			interaction := stMap(value)
			if interaction["status"] == "pending" && interaction["blocksTurn"] == true {
				result["interactions"] = append(stArray(result["interactions"]), stRendererInteraction(interaction))
			}
		}
		if foreground := stMap(turn["foreground"]); foreground != nil {
			result["foreground"] = stCompactForeground(foreground)
		}
	}
	return result
}

func stCompactForeground(foreground Map) Map {
	result := stClone(foreground)
	if result["kind"] != "reasoning" {
		return result
	}
	source := stString(result["text"])
	points := []rune(source)
	if len(points) <= 1200 {
		return result
	}
	text := string(points[len(points)-1200:])
	result["text"], result["textOffset"] = text, stInt(result["textOffset"])+int64(stLen(source)-stLen(text))
	return result
}

// ProjectObservation publishes the smallest stable execution contract. Native
// session IDs, tool names and native interaction IDs never cross this boundary.
func ProjectObservation(state Map) Map {
	result := Map{"latestExecution": nil, "backgroundWork": nil}
	background := len(stArray(state["backgroundTerminals"])) > 0
	for _, value := range stArray(state["turns"]) {
		turn := stMap(value)
		if stActive(turn) {
			continue
		}
		for _, value := range stArray(turn["activities"]) {
			if stMap(value)["status"] == "running" {
				background = true
			}
		}
	}
	if background {
		result["backgroundWork"] = Map{"status": "running"}
	}
	turn := LatestTurn(state)
	if turn == nil {
		return result
	}
	execution := Map{"executionId": turn["executionId"], "startedAt": turn["createdAt"]}
	if summary := stSummary(turn); summary != "" {
		execution["summary"] = summary
	}
	if !stActive(turn) {
		execution["status"], execution["finishedAt"] = turn["status"], turn["finishedAt"]
		if turn["status"] == "failed" && stString(turn["error"]) != "" {
			execution["error"] = turn["error"]
		}
	} else {
		interactions := []any{}
		for _, value := range stArray(turn["interactions"]) {
			interaction := stMap(value)
			if interaction["status"] == "pending" && interaction["blocksTurn"] == true {
				interactions = append(interactions, PublicInteraction(interaction))
			}
		}
		execution["status"] = "running"
		if len(interactions) > 0 {
			execution["status"], execution["interactions"] = "waiting-for-user", interactions
		}
	}
	result["latestExecution"] = execution
	return result
}

func ResolveExecution(state Map, id string) Map {
	turn := stFindTurn(stArray(state["turns"]), id)
	if turn == nil {
		return nil
	}
	selected := stClone(state)
	selected["turns"] = []any{turn}
	return stMap(ProjectObservation(selected)["latestExecution"])
}

func stSummary(turn Map) string {
	if !stActive(turn) {
		return stString(stMap(turn["lastAssistantMessage"])["text"])
	}
	source := strings.TrimSpace(stString(turn["answer"]))
	if source == "" {
		source = strings.TrimSpace(stString(turn["error"]))
	}
	if source == "" {
		messages := stArray(turn["messages"])
		for i := len(messages) - 1; i >= 0; i-- {
			message := stMap(messages[i])
			if message["internal"] != true {
				source = strings.TrimSpace(stString(message["content"]))
				break
			}
		}
	}
	return stHead(strings.Join(strings.Fields(source), " "), 2000)
}

func PublicInteractionID(nativeID string) string {
	return "codex-interaction-sha256-" + stOpaqueDigest("interaction", nativeID)
}
func PublicQuestionID(interactionID, questionID string) string {
	return "codex-question-sha256-" + stOpaqueDigest("question", interactionID, questionID)
}
func PublicOptionID(interactionID, questionID, optionID string) string {
	return "codex-option-sha256-" + stOpaqueDigest("option", interactionID, questionID, optionID)
}
func stOpaqueDigest(parts ...string) string {
	digest := sha256.New()
	_, _ = digest.Write([]byte("mokusei.codex.public-interaction.v1"))
	for _, part := range parts {
		_, _ = digest.Write([]byte(strconv.Itoa(len([]byte(part))) + ":"))
		_, _ = digest.Write([]byte(part))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func PublicInteraction(interaction Map) Map {
	var elicitation Map
	if interaction["kind"] == "mcp-elicitation" {
		elicitation = stMap(interaction["elicitation"])
	}
	confirmation := elicitation["mode"] == "form" && stConfirmationSchema(stMap(elicitation["requestedSchema"]))
	kind := "permission"
	if interaction["kind"] == "user-input" || elicitation["mode"] == "form" && !confirmation {
		kind = "question"
	}
	schema := ""
	if elicitation["mode"] == "form" && !confirmation {
		schema = stPrettyJSON(elicitation["requestedSchema"])
	}
	description := stString(interaction["detail"])
	if schema != "" {
		description = schema
	}
	if elicitation["mode"] == "url" {
		description = stString(elicitation["url"])
	}
	fallback := "Codex 请求确认"
	if kind == "question" {
		fallback = "Codex 需要补充信息"
	}
	result := Map{"id": PublicInteractionID(stString(interaction["id"])), "kind": kind, "title": stDisplay(stString(interaction["title"]), 2000, fallback), "actions": []any{}, "questions": []any{}}
	if description != "" {
		if text := stDisplay(description, 20000, ""); text != "" {
			result["description"] = text
		}
	}
	for _, value := range stArray(interaction["actions"]) {
		action := stMap(value)
		intent := stString(action["intent"])
		label := stDisplay(stString(action["label"]), 2000, map[string]string{"allow": "允许", "deny": "拒绝", "submit": "提交", "cancel": "取消"}[intent])
		if confirmation && action["id"] == "submit" {
			intent, label = "allow", "允许"
		}
		result["actions"] = append(stArray(result["actions"]), Map{"id": action["id"], "intent": intent, "label": label})
	}
	if confirmation {
		return result
	}
	id := stString(interaction["id"])
	for _, value := range stArray(interaction["questions"]) {
		question := stMap(value)
		questionID := stString(question["id"])
		prompt := stString(question["prompt"])
		isForm := elicitation["mode"] == "form" && question["id"] == elicitation["questionId"]
		if isForm {
			prompt = "JSON form values matching this schema:\n" + schema
		}
		projected := Map{"id": PublicQuestionID(id, questionID), "prompt": stDisplay(prompt, 20000, "Codex question"), "multiple": false, "allowOther": question["allowOther"], "secret": question["secret"], "options": []any{}}
		if header := stDisplay(stString(question["header"]), 2000, ""); header != "" {
			projected["header"] = header
		}
		if isForm {
			projected["answerFormat"] = "json-object"
		}
		for index, value := range stArray(question["options"]) {
			option := stMap(value)
			entry := Map{"value": PublicOptionID(id, questionID, stString(option["id"])), "label": stDisplay(stString(option["label"]), 2000, fmt.Sprintf("选项 %d", index+1))}
			if description := stDisplay(stString(option["description"]), 10000, ""); description != "" {
				entry["description"] = description
			}
			projected["options"] = append(stArray(projected["options"]), entry)
		}
		result["questions"] = append(stArray(result["questions"]), projected)
	}
	return result
}

func stConfirmationSchema(schema Map) bool {
	properties := stMap(schema["properties"])
	if schema["type"] != "object" || properties == nil || len(properties) != 0 {
		return false
	}
	for key, value := range schema {
		switch key {
		case "type", "properties":
		case "required":
			if !stIsArray(value) || len(stArray(value)) != 0 {
				return false
			}
		case "additionalProperties":
			if value != false {
				return false
			}
		case "$schema", "$id", "$comment", "title", "description":
			if _, ok := value.(string); !ok {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func stDisplay(value string, maximum int, fallback string) string {
	value = stHead(strings.TrimSpace(strings.ReplaceAll(value, "\x00", "�")), maximum)
	if value == "" {
		return fallback
	}
	return value
}
func stPrettyJSON(value any) string {
	bytes, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return ""
	}
	return string(bytes)
}
