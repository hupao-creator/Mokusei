package codex

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const StateSchema = "mokusei.harness.codex.thread.v1"
const stMaxTurns = 200
const stMaxAnswer = 256 * 1024
const stMaxReasoning = 64 * 1024
const stMaxDetail = 32 * 1024
const stMaxNotice = 16 * 1024
const stMaxPersisted = 8 * 1024 * 1024

func EmptyState(at int64) Map {
	return Map{"schema": StateSchema, "updatedAt": at, "backgroundTerminals": []any{}, "turns": []any{}}
}

// DecodeState accepts only the persisted Codex schema and returns detached data.
func DecodeState(value any) (Map, error) {
	bytes, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("Codex sessionState 无效: %w", err)
	}
	var state Map
	if err := json.Unmarshal(bytes, &state); err != nil {
		return nil, fmt.Errorf("Codex sessionState 无效: %w", err)
	}
	if !stValidState(state) {
		return nil, errors.New("Codex sessionState 无效")
	}
	return state, nil
}

func BindPrimarySession(state Map, id string, at int64) (Map, error) {
	if !stCanonical(id, 1024) {
		return nil, errors.New("Codex Primary Native Session ID 无效")
	}
	if old := stString(state["primarySessionId"]); old != "" {
		if old != id {
			return nil, errors.New("Codex Thread 已绑定另一 Primary Native Session")
		}
		return state, nil
	}
	next := stClone(state)
	next["primarySessionId"], next["updatedAt"] = id, stNextAt(state, at)
	return next, nil
}

func StageExecution(state Map, id string, input Map, at int64, settings Map) Map {
	next, err := StageExecutionChecked(state, id, input, at, settings)
	if err != nil {
		return state
	}
	return next
}

func StageExecutionChecked(state Map, id string, input Map, at int64, settings Map) (Map, error) {
	for _, value := range stArray(state["turns"]) {
		if stActive(stMap(value)) {
			return nil, errors.New("Codex Thread 已有 active Execution")
		}
	}
	if !stCanonical(id, 1024) {
		return nil, errors.New("Codex Execution ID 无效")
	}
	next := stClone(state)
	timestamp := stNextAt(state, at)
	messageID := stString(input["messageId"])
	if messageID == "" {
		messageID = "message:" + id
	}
	turn := Map{"executionId": id, "createdAt": timestamp, "updatedAt": timestamp, "status": "running", "statusLabel": "正在连接 Codex", "messages": []any{stMessage(input, messageID, "prompt", timestamp)}, "timeline": []any{Map{"id": fmt.Sprintf("tl:%d:user-message:0", timestamp), "kind": "user-message", "createdAt": timestamp, "messageId": messageID}}, "answer": "", "reasoning": "", "plan": []any{}, "activities": []any{}, "interactions": []any{}, "notices": []any{}}
	if settings != nil {
		author := Map{}
		if model := strings.TrimSpace(stString(settings["model"])); model != "" {
			author["model"] = model
		}
		effort := strings.TrimSpace(stString(settings["effort"]))
		thinking := stMap(settings["thinking"])
		if mode := stString(thinking["mode"]); mode != "" {
			effort = mode
			if mode == "effort" {
				effort = stString(thinking["effort"])
			}
		}
		if effort != "" {
			author["effort"] = effort
		}
		turn["author"] = author
	}
	turns := append(stArray(next["turns"]), turn)
	if len(turns) > stMaxTurns {
		turns = turns[len(turns)-stMaxTurns:]
	}
	next["turns"], next["updatedAt"] = turns, timestamp
	return next, nil
}

func AppendFollowUp(state Map, id string, input Map, at int64, messageID string) Map {
	next, turn, timestamp := stEditActive(state, id, at)
	if turn == nil {
		return state
	}
	turn["messages"] = append(stArray(turn["messages"]), stMessage(input, messageID, "follow-up", timestamp))
	turn["timeline"] = stReference(stArray(turn["timeline"]), "user-message", messageID, timestamp)
	turn["statusLabel"] = "已追加指令"
	return next
}

func RejectFollowUp(state Map, id, message string, at int64, noticeID string) Map {
	// A steer reply can arrive after native completion. Keep its audit notice
	// without altering the execution's canonical outcome, summary or finish time.
	next, turn, timestamp := stEditTurn(state, id, at, false)
	if turn == nil {
		return state
	}
	turn["notices"] = append(stArray(turn["notices"]), Map{"id": noticeID, "level": "error", "message": stTail(message, stMaxNotice)})
	turn["timeline"] = stReference(stArray(turn["timeline"]), "notice", noticeID, timestamp)
	return next
}

// ReduceEvent uses event.at when supplied, allowing deterministic native replay.
// Telemetry and public-final are consumed by the controller, not durable state.
func ReduceEvent(state Map, executionID string, event Map) Map {
	kind := stString(event["type"])
	at := time.Now().UnixMilli()
	if value, ok := event["at"]; ok {
		at = stInt(value)
	}
	if kind == "public-final" || kind == "generation-usage" {
		return state
	}
	if kind == "session" {
		next, err := BindPrimarySession(state, stString(event["sessionId"]), at)
		if err == nil {
			return next
		}
		return state
	}
	next, turn, timestamp := stEditActive(state, executionID, at)
	if turn == nil {
		return state
	}
	timeline := stArray(turn["timeline"])
	switch kind {
	case "status":
		if label, exists := event["label"]; exists {
			turn["statusLabel"] = label
		}
	case "runtime-model":
		turn["runtimeModel"] = event["model"]
	case "runtime-service-tier":
		turn["runtimeServiceTier"] = event["serviceTier"]
	case "text-delta", "text-final":
		text := stString(event["text"])
		if kind == "text-delta" {
			text = stString(event["delta"])
		}
		// Native JSON permits NUL, while every persisted text projection rejects
		// it. Normalize before splitting the text into history and live snapshots.
		text = strings.ReplaceAll(text, "\x00", "")
		itemID := stString(event["itemId"])
		index := stIndex(timeline, "itemId", itemID)
		var item Map
		if index >= 0 {
			item = stMap(timeline[index])
		}
		if kind == "text-delta" && item != nil && stString(item["status"]) != "streaming" {
			return next
		}
		if item == nil {
			item = Map{"id": stTimelineID(timeline, "assistant", timestamp), "kind": "assistant", "itemId": itemID, "content": "", "createdAt": timestamp, "status": "streaming"}
			timeline = append(timeline, item)
		}
		if kind == "text-final" {
			item["content"], item["status"] = stTail(text, stMaxAnswer), "complete"
		} else {
			item["content"] = stTail(stString(item["content"])+text, stMaxAnswer)
		}
		turn["timeline"], turn["answer"] = timeline, stTimelineAnswer(timeline)
		for i := len(timeline) - 1; i >= 0; i-- {
			last := stMap(timeline[i])
			if stString(last["kind"]) != "assistant" {
				continue
			}
			if stString(last["itemId"]) == itemID {
				message := text
				if kind == "text-delta" {
					previous := stMap(turn["lastAssistantMessage"])
					if stString(previous["itemId"]) == itemID {
						message = stString(previous["text"]) + text
					}
				}
				turn["lastAssistantMessage"] = Map{"itemId": itemID, "text": stHead(message, 100000)}
			}
			break
		}
		if kind == "text-delta" && text != "" {
			turn["foreground"] = stForeground(stMap(turn["foreground"]), Map{"kind": "assistant-text"}, false)
		}
	case "reasoning-delta":
		delta := strings.ReplaceAll(stString(event["delta"]), "\x00", "")
		continues := len(timeline) > 0 && stString(stMap(timeline[len(timeline)-1])["kind"]) == "reasoning"
		if continues {
			last := stMap(timeline[len(timeline)-1])
			last["content"] = stTail(stString(last["content"])+delta, stMaxReasoning)
		} else {
			timeline = append(timeline, Map{"id": stTimelineID(timeline, "reasoning", timestamp), "kind": "reasoning", "content": stTail(delta, stMaxReasoning), "createdAt": timestamp})
		}
		turn["timeline"], turn["reasoning"] = timeline, stTail(stString(turn["reasoning"])+delta, stMaxReasoning)
		if delta != "" {
			turn["foreground"] = stReasoning(stMap(turn["foreground"]), delta, continues && turn["reasoningBreak"] != true)
			if turn["reasoningBreak"] == true {
				turn["reasoningBreak"] = false
			}
		}
	case "plan":
		steps := stArray(event["steps"])
		if len(steps) > 200 {
			steps = steps[:200]
		}
		turn["plan"], turn["reasoningBreak"] = steps, true
		delete(turn, "planExplanation")
		if text := stString(event["explanation"]); text != "" {
			turn["planExplanation"] = stTail(text, stMaxDetail)
		}
		turn["timeline"] = stMarker(timeline, "plan", timestamp, false)
	case "diff", "review":
		turn[kind], turn["reasoningBreak"], turn["timeline"] = stTail(stString(event[kind]), stMaxAnswer), true, stMarker(timeline, kind, timestamp, false)
	case "context-compacted":
		turn["contextCompacted"], turn["timeline"] = true, stMarker(timeline, "context-compaction", timestamp, true)
	case "activity-start":
		incoming := stMap(event["activity"])
		activities := stArray(turn["activities"])
		id := stString(incoming["id"])
		index := stIndex(activities, "id", id)
		activity := Map{"id": id, "kind": incoming["kind"], "label": stTail(stString(incoming["label"]), stMaxDetail), "status": "running"}
		if value, exists := incoming["toolCall"]; exists {
			activity["toolCall"] = value
		}
		if paths, exists := incoming["filePaths"]; exists {
			activity["filePaths"] = paths
		}
		if index >= 0 {
			activity["status"] = stMap(activities[index])["status"]
		}
		if stString(incoming["kind"]) == "tool" {
			if name, exists := incoming["toolName"]; exists {
				activity["toolName"] = stTail(stString(name), 1024)
				if index < 0 {
					turn["foreground"] = stForeground(stMap(turn["foreground"]), Map{"kind": "tool-call", "callId": id, "toolName": stHeadPoints(stString(name), 64)}, false)
				}
			}
		}
		turn["activities"] = stUpsert(activities, activity)
		if index < 0 {
			turn["timeline"] = stReference(timeline, "activity", id, timestamp)
		}
	case "activity-update": // Raw inputs and progress are deliberately not persisted.
	case "activity-end":
		for _, value := range stArray(turn["activities"]) {
			activity := stMap(value)
			if activity["id"] != event["activityId"] {
				continue
			}
			activity["status"] = event["status"]
			if paths, exists := event["filePaths"]; exists {
				if len(stArray(paths)) == 0 {
					delete(activity, "filePaths")
				} else {
					activity["filePaths"] = paths
				}
			}
			delete(activity, "detail")
			if stString(activity["kind"]) == "command" && stString(event["detail"]) != "" {
				activity["detail"] = stTail(stString(event["detail"]), stMaxDetail)
			}
		}
	case "interaction-opened":
		interaction := stMap(event["interaction"])
		if !stValidInteraction(interaction) {
			return state
		}
		interactions := stArray(turn["interactions"])
		id := stString(interaction["id"])
		if interaction["blocksTurn"] == true {
			turn["status"], turn["statusLabel"] = "waiting-input", "等待你的输入"
		}
		if stIndex(interactions, "id", id) < 0 {
			turn["timeline"] = stReference(timeline, "interaction", id, timestamp)
		}
		turn["interactions"] = stUpsert(interactions, stClone(interaction))
	case "interaction-closed":
		waiting := false
		for _, value := range stArray(turn["interactions"]) {
			interaction := stMap(value)
			if interaction["id"] == event["interactionId"] {
				resolution := stString(event["resolution"])
				interaction["status"], interaction["resolution"] = stInteractionStatus(resolution), stTail(resolution, 1000)
			}
			if interaction["status"] == "pending" && interaction["blocksTurn"] == true {
				waiting = true
			}
		}
		if turn["status"] == "waiting-input" && !waiting {
			turn["status"], turn["statusLabel"] = "running", "正在工作"
		}
	case "usage":
		turn["usage"] = stClone(stMap(event["usage"]))
	case "warning", "error":
		id := stString(event["generatedId"])
		if id == "" {
			id = fmt.Sprintf("notice:%d:%d", timestamp, len(stArray(turn["notices"])))
		}
		text := stTail(stString(event["message"]), stMaxNotice)
		turn["notices"] = append(stArray(turn["notices"]), Map{"id": id, "level": kind, "message": text})
		turn["timeline"] = stReference(timeline, "notice", id, timestamp)
		if kind == "error" {
			turn["error"], turn["timeline"] = text, stMarker(stArray(turn["timeline"]), "error", timestamp, false)
		}
	case "done":
		outcome := stString(event["outcome"])
		if !stOneOf(outcome, "completed", "failed", "interrupted") {
			return state
		}
		// A turn-scoped Hook/tool is finished with its turn. Only native
		// background terminals may retain running activities after a known list.
		background := map[string]bool{}
		for _, value := range stArray(state["backgroundTerminals"]) {
			background[stString(stMap(value)["id"])] = true
		}
		if event["backgroundUnknown"] == true {
			for _, value := range stArray(turn["activities"]) {
				item := stMap(value)
				if item["kind"] != "hook" {
					background[stString(item["id"])] = true
				}
			}
		}
		stSetTerminal(turn, outcome, at, true, background)
		turn["statusLabel"] = stTerminalLabel(outcome)
	default:
		return state
	}
	return next
}

func SettleExecution(state Map, id, outcome string, at int64, errorText string) Map {
	if !stOneOf(outcome, "completed", "failed", "interrupted") {
		return state
	}
	next, turn, _ := stEditActive(state, id, at)
	if turn == nil {
		return state
	}
	background := map[string]bool{}
	for _, value := range stArray(state["backgroundTerminals"]) {
		background[stString(stMap(value)["id"])] = true
	}
	previousError := stString(turn["error"])
	delete(turn, "error")
	if errorText == "" {
		errorText = previousError
	}
	if outcome == "failed" && errorText != "" {
		turn["error"] = stTail(errorText, stMaxNotice)
	}
	stSetTerminal(turn, outcome, at, true, background)
	turn["statusLabel"] = stTerminalLabel(outcome)
	if activity := stMap(next["nativeActivity"]); activity != nil && stInt(activity["updatedAt"]) <= at {
		delete(next, "nativeActivity")
	}
	return next
}

func SettleOrphanedExecutions(state Map, at int64, errorText string) Map {
	next := state
	for _, value := range stArray(state["turns"]) {
		turn := stMap(value)
		if stActive(turn) {
			next = SettleExecution(next, stString(turn["executionId"]), "interrupted", at, errorText)
		}
	}
	return next
}

func UpdateNativeActivity(state Map, status, detail string, at int64) Map {
	next := stClone(state)
	timestamp := stNextAt(state, at)
	activity := Map{"status": stTail(status, 256), "updatedAt": timestamp}
	if detail != "" {
		activity["detail"] = stTail(detail, stMaxDetail)
	}
	next["updatedAt"], next["nativeActivity"] = timestamp, activity
	return next
}

func ClearNativeActivity(state Map, at int64) Map {
	if state["nativeActivity"] == nil {
		return state
	}
	next := stClone(state)
	delete(next, "nativeActivity")
	next["updatedAt"] = stNextAt(state, at)
	return next
}

func UpdateBackgroundTerminals(state Map, terminals []any, at int64) Map {
	next := stClone(state)
	if terminals == nil {
		terminals = []any{}
	}
	next["backgroundTerminals"], next["updatedAt"] = stCloneValue(terminals), stNextAt(state, at)
	return next
}

func CompleteBackgroundActivity(state Map, id, status, detail string, at int64) Map {
	turns := stArray(state["turns"])
	for i := len(turns) - 1; i >= 0; i-- {
		for _, value := range stArray(stMap(turns[i])["activities"]) {
			activity := stMap(value)
			if activity["id"] != id || !stOneOf(stString(activity["status"]), "running", "cancelled") {
				continue
			}
			next := stClone(state)
			timestamp := stNextAt(state, at)
			turn := stMap(stArray(next["turns"])[i])
			turn["updatedAt"], next["updatedAt"] = timestamp, timestamp
			for _, val := range stArray(turn["activities"]) {
				target := stMap(val)
				if target["id"] == id {
					target["status"] = status
					if detail != "" {
						target["detail"] = stTail(detail, stMaxDetail)
					}
				}
			}
			return next
		}
	}
	return state
}

func RetireBackgroundTerminals(state Map, at int64) Map {
	needs := len(stArray(state["backgroundTerminals"])) > 0
	for _, value := range stArray(state["turns"]) {
		turn := stMap(value)
		if !stActive(turn) {
			for _, entry := range stArray(turn["activities"]) {
				if stMap(entry)["status"] == "running" {
					needs = true
				}
			}
		}
	}
	if !needs {
		return state
	}
	next := stClone(state)
	next["backgroundTerminals"], next["updatedAt"] = []any{}, stNextAt(state, at)
	for _, value := range stArray(next["turns"]) {
		turn := stMap(value)
		if !stActive(turn) {
			for _, entry := range stArray(turn["activities"]) {
				activity := stMap(entry)
				if activity["status"] == "running" {
					activity["status"] = "cancelled"
				}
			}
		}
	}
	return next
}

func LatestTurn(state Map) Map {
	turns := stArray(state["turns"])
	if len(turns) == 0 {
		return nil
	}
	return stMap(turns[len(turns)-1])
}

func stSetTerminal(turn Map, outcome string, at int64, settleActivities bool, background map[string]bool) {
	turn["status"], turn["finishedAt"] = outcome, max(stInt(turn["createdAt"]), at)
	status := "cancelled"
	if outcome == "completed" {
		status = "complete"
	} else if outcome == "failed" {
		status = "failed"
	}
	for _, value := range stArray(turn["timeline"]) {
		item := stMap(value)
		if item["kind"] == "assistant" && item["status"] == "streaming" {
			item["status"] = status
		}
	}
	for _, value := range stArray(turn["interactions"]) {
		item := stMap(value)
		if item["status"] == "pending" {
			item["status"] = "cancelled"
		}
	}
	if settleActivities {
		for _, value := range stArray(turn["activities"]) {
			item := stMap(value)
			if item["status"] == "running" && !background[stString(item["id"])] {
				item["status"] = "cancelled"
				if outcome == "failed" {
					item["status"] = "failed"
				}
			}
		}
	}
}

func stEditActive(state Map, id string, at int64) (Map, Map, int64) {
	return stEditTurn(state, id, at, true)
}

func stEditTurn(state Map, id string, at int64, activeOnly bool) (Map, Map, int64) {
	index := -1
	for candidate, value := range stArray(state["turns"]) {
		turn := stMap(value)
		if turn["executionId"] == id && (!activeOnly || stActive(turn)) {
			index = candidate
			break
		}
	}
	if index < 0 {
		return state, nil, 0
	}
	// Earlier executions are immutable. Copy only the selected execution so a
	// streamed delta does not duplicate the entire retained conversation.
	next := Map{}
	for key, value := range state {
		next[key] = value
	}
	turns := append([]any{}, stArray(state["turns"])...)
	turns[index] = stClone(stMap(turns[index]))
	next["turns"] = turns
	timestamp := stNextAt(state, at)
	turn := stMap(stArray(next["turns"])[index])
	turn["updatedAt"], next["updatedAt"] = timestamp, timestamp
	return next, turn, timestamp
}

func stMessage(input Map, id, kind string, at int64) Map {
	texts := []string{}
	attachments := []any{}
	for _, value := range stArray(input["parts"]) {
		part := stMap(value)
		switch stString(part["kind"]) {
		case "text":
			if stString(part["annotationId"]) == "" {
				texts = append(texts, stString(part["text"]))
			}
		case "mention":
			texts = append(texts, "@"+stString(part["name"]))
		case "skill":
			texts = append(texts, "$"+stString(part["name"]))
		case "image", "audio", "local-file":
			file := stMap(part["file"])
			attachmentKind := stString(part["kind"])
			if attachmentKind == "local-file" {
				attachmentKind = "file"
			}
			attachments = append(attachments, Map{"id": file["id"], "name": file["name"], "mimeType": file["mimeType"], "size": file["size"], "kind": attachmentKind})
		case "image-url", "audio-url":
			attachmentKind := strings.TrimSuffix(stString(part["kind"]), "-url")
			attachments = append(attachments, Map{"id": fmt.Sprintf("%s-url:%d", attachmentKind, len(attachments)), "name": part["url"], "mimeType": attachmentKind + "/*", "size": 0, "kind": attachmentKind})
		}
	}
	message := Map{"id": id, "role": "user", "kind": kind, "content": strings.Join(texts, "\n"), "createdAt": at, "attachments": attachments}
	if input["annotations"] != nil {
		message["annotations"] = stCloneValue(input["annotations"])
	}
	if input["presentation"] == "internal" {
		message["internal"] = true
	}
	return message
}

func stReference(timeline []any, kind, id string, at int64) []any {
	key := map[string]string{"user-message": "messageId", "activity": "activityId", "interaction": "interactionId", "notice": "noticeId"}[kind]
	for _, value := range timeline {
		item := stMap(value)
		if item["kind"] == kind && item[key] == id {
			return timeline
		}
	}
	return append(timeline, Map{"id": stTimelineID(timeline, kind, at), "kind": kind, "createdAt": at, key: id})
}
func stMarker(timeline []any, kind string, at int64, repeat bool) []any {
	if !repeat {
		for _, value := range timeline {
			if stMap(value)["kind"] == kind {
				return timeline
			}
		}
	}
	return append(timeline, Map{"id": stTimelineID(timeline, kind, at), "kind": kind, "createdAt": at})
}
func stTimelineID(timeline []any, kind string, at int64) string {
	return fmt.Sprintf("tl:%d:%s:%d", at, kind, len(timeline))
}
func stTimelineAnswer(timeline []any) string {
	joined := ""
	for _, value := range timeline {
		item := stMap(value)
		text := stString(item["content"])
		if item["kind"] != "assistant" || text == "" {
			continue
		}
		if joined != "" {
			trailing := len(joined) - len(strings.TrimRight(joined, "\n"))
			leading := len(text) - len(strings.TrimLeft(text, "\n"))
			joined += strings.Repeat("\n", max(0, 2-trailing-leading))
		}
		joined += text
	}
	return stTail(joined, stMaxAnswer)
}
func stForeground(previous, next Map, newSegment bool) Map {
	sequence := stInt(previous["sequence"]) + 1
	if previous != nil && previous["kind"] == next["kind"] && !newSegment && (previous["kind"] != "tool-call" || previous["callId"] == next["callId"]) {
		sequence = stInt(previous["sequence"])
	}
	next["sequence"] = sequence
	return next
}
func stReasoning(previous Map, delta string, continues bool) Map {
	source := delta
	offset := int64(0)
	if continues && previous["kind"] == "reasoning" {
		source = stString(previous["text"]) + delta
		offset = stInt(previous["textOffset"])
	}
	points := []rune(source)
	text := source
	if len(points) > 32768 {
		text = string(points[len(points)-32768:])
	}
	offset += int64(stLen(source) - stLen(text))
	next := Map{"kind": "reasoning", "text": text}
	if offset > 0 {
		next["textOffset"] = offset
	}
	return stForeground(previous, next, !continues)
}
func stInteractionStatus(resolution string) string {
	switch strings.TrimSpace(resolution) {
	case "accept", "acceptForSession", "turn", "session":
		return "allowed"
	case "submit":
		return "submitted"
	case "cancel":
		return "cancelled"
	case "decline":
		return "denied"
	}
	return "resolved"
}
func stTerminalLabel(outcome string) string {
	switch outcome {
	case "completed":
		return "已完成"
	case "failed":
		return "失败"
	default:
		return "已中断"
	}
}
func stActive(turn Map) bool             { return turn["status"] == "running" || turn["status"] == "waiting-input" }
func stNextAt(state Map, at int64) int64 { return max(stInt(state["updatedAt"])+1, at) }
func stUpsert(values []any, item Map) []any {
	index := stIndex(values, "id", stString(item["id"]))
	if index < 0 {
		return append(values, item)
	}
	values[index] = item
	return values
}
func stIndex(values []any, key, id string) int {
	for i, value := range values {
		if stString(stMap(value)[key]) == id {
			return i
		}
	}
	return -1
}
func stMap(value any) Map { result, _ := value.(map[string]any); return result }
func stArray(value any) []any {
	switch value := value.(type) {
	case []any:
		return value
	case []Map:
		result := make([]any, len(value))
		for i, item := range value {
			result[i] = item
		}
		return result
	}
	return nil
}
func stString(value any) string { text, _ := value.(string); return text }
func stInt(value any) int64 {
	switch value := value.(type) {
	case int:
		return int64(value)
	case int64:
		return value
	case float64:
		return int64(value)
	case json.Number:
		result, _ := value.Int64()
		return result
	}
	return 0
}
func stClone(value Map) Map {
	if value == nil {
		return Map{}
	}
	result, _ := stCloneValue(value).(map[string]any)
	return result
}
func stCloneValue(value any) any {
	switch value := value.(type) {
	case map[string]any:
		result := Map{}
		for key, entry := range value {
			result[key] = stCloneValue(entry)
		}
		return result
	case []any:
		result := make([]any, len(value))
		for i, entry := range value {
			result[i] = stCloneValue(entry)
		}
		return result
	case []Map:
		result := make([]any, len(value))
		for i, entry := range value {
			result[i] = stClone(entry)
		}
		return result
	default:
		return value
	}
}

// Count UTF-16 code units directly, without allocating complete rune and
// surrogate buffers for each validation or bounded preview.
func stLen(value string) int {
	length := 0
	for _, point := range value {
		length++
		if point > 0xffff {
			length++
		}
	}
	return length
}
func stPrefix(value string) string {
	if utf8.ValidString(value) {
		return value
	}
	return string([]rune(value))
}
func stHead(value string, maximum int) string {
	units := 0
	for index, point := range value {
		width := 1
		if point > 0xffff {
			width = 2
		}
		if units+width > maximum {
			return strings.Clone(stPrefix(value[:index]))
		}
		units += width
	}
	return value
}
func stHeadPoints(value string, maximum int) string {
	count := 0
	for index := range value {
		if count == maximum {
			return strings.Clone(stPrefix(value[:index]))
		}
		count++
	}
	return stPrefix(value)
}
func stTail(value string, maximum int) string {
	if stLen(value) <= maximum {
		return value
	}
	budget := maximum - 2 // Reserve the ellipsis and newline.
	start, units := len(value), 0
	for start > 0 {
		point, size := utf8.DecodeLastRuneInString(value[:start])
		width := 1
		if point > 0xffff {
			width = 2
		}
		if units+width > budget {
			break
		}
		start -= size
		units += width
	}
	return "…\n" + stPrefix(value[start:])
}
func stOneOf(value string, choices ...string) bool {
	for _, choice := range choices {
		if value == choice {
			return true
		}
	}
	return false
}
func stCanonical(value any, maximum int) bool {
	text, ok := value.(string)
	return ok && text != "" && strings.TrimSpace(text) == text && stBounded(value, maximum)
}
func stBounded(value any, maximum int) bool {
	text, ok := value.(string)
	if !ok {
		return false
	}
	units := 0
	for _, point := range text {
		if point == 0 {
			return false
		}
		units++
		if point > 0xffff {
			units++
		}
		if units > maximum {
			return false
		}
	}
	return units <= maximum
}
func stNonEmpty(value any, maximum int) bool {
	return stBounded(value, maximum) && stString(value) != ""
}
func stOnly(value Map, keys ...string) bool {
	if value == nil {
		return false
	}
	for key := range value {
		if !stOneOf(key, keys...) {
			return false
		}
	}
	return true
}
func stOptionalText(value Map, key string, maximum int) bool {
	item, exists := value[key]
	return !exists || stBounded(item, maximum)
}
func stNumber(value any) (float64, bool) {
	switch value := value.(type) {
	case float64:
		return value, !math.IsInf(value, 0) && !math.IsNaN(value)
	case int64:
		return float64(value), true
	case int:
		return float64(value), true
	case json.Number:
		n, err := value.Float64()
		return n, err == nil && !math.IsInf(n, 0) && !math.IsNaN(n)
	}
	return 0, false
}
func stTimestamp(value any) bool { n, ok := stNumber(value); return ok && n >= 0 }
func stWithin(value any, min, max int64) bool {
	n, ok := stNumber(value)
	return ok && n >= float64(min) && n <= float64(max)
}
func stIsArray(value any) bool {
	switch value.(type) {
	case []any, []Map:
		return true
	}
	return false
}
func stIsBool(value any) bool { _, ok := value.(bool); return ok }

var stHash = regexp.MustCompile(`^[a-f0-9]{64}$`)

func stValidState(state Map) bool {
	if !stOnly(state, "schema", "primarySessionId", "nativeToolConfiguration", "nativeToolMode", "nativeHistorySeed", "forkHistory", "updatedAt", "nativeActivity", "backgroundTerminals", "turns") || state["schema"] != StateSchema || !stTimestamp(state["updatedAt"]) || !stIsArray(state["turns"]) || !stIsArray(state["backgroundTerminals"]) || len(stArray(state["turns"])) > stMaxTurns || len(stArray(state["backgroundTerminals"])) > 2000 {
		return false
	}
	if id, exists := state["primarySessionId"]; exists && !stCanonical(id, 1024) {
		return false
	}
	if hash, exists := state["nativeToolConfiguration"]; exists && !stHash.MatchString(stString(hash)) {
		return false
	}
	if mode, exists := state["nativeToolMode"]; exists && !stOneOf(stString(mode), "extend", "exclusive") {
		return false
	}
	if !stOptionalText(state, "nativeHistorySeed", stMaxPersisted) {
		return false
	}
	updated := stInt(state["updatedAt"])
	if value, exists := state["nativeActivity"]; exists {
		activity := stMap(value)
		if !stOnly(activity, "status", "detail", "updatedAt") || !stBounded(activity["status"], 256) || !stOptionalText(activity, "detail", stMaxDetail) || !stWithin(activity["updatedAt"], 0, updated) {
			return false
		}
	}
	for _, value := range stArray(state["backgroundTerminals"]) {
		terminal := stMap(value)
		if !stOnly(terminal, "id", "command", "cwd") || !stCanonical(terminal["id"], 1024) || !stBounded(terminal["command"], stMaxDetail) || !stBounded(terminal["cwd"], stMaxDetail) {
			return false
		}
	}
	for _, value := range stArray(state["turns"]) {
		if !stValidTurn(stMap(value), updated) {
			return false
		}
	}
	if history, exists := state["forkHistory"]; exists {
		if !stIsArray(history) || len(stArray(history)) > stMaxTurns {
			return false
		}
		for _, value := range stArray(history) {
			turn := stMap(value)
			if !stValidTurn(turn, updated) || stActive(turn) {
				return false
			}
			for _, item := range stArray(turn["activities"]) {
				if stMap(item)["status"] == "running" {
					return false
				}
			}
			for _, item := range stArray(turn["interactions"]) {
				if stMap(item)["status"] == "pending" {
					return false
				}
			}
		}
	}
	return true
}

func stValidTurn(turn Map, stateUpdated int64) bool {
	if !stOnly(turn, "executionId", "createdAt", "updatedAt", "finishedAt", "status", "statusLabel", "foreground", "reasoningBreak", "author", "runtimeModel", "runtimeServiceTier", "messages", "timeline", "answer", "lastAssistantMessage", "reasoning", "plan", "planExplanation", "activities", "interactions", "notices", "usage", "diff", "review", "contextCompacted", "error") || !stCanonical(turn["executionId"], 1024) || !stTimestamp(turn["createdAt"]) || !stWithin(turn["updatedAt"], stInt(turn["createdAt"]), stateUpdated) || !stOneOf(stString(turn["status"]), "running", "waiting-input", "completed", "failed", "interrupted") {
		return false
	}
	created, updated := stInt(turn["createdAt"]), stInt(turn["updatedAt"])
	_, hasFinished := turn["finishedAt"]
	if stActive(turn) {
		if hasFinished {
			return false
		}
	} else if !stWithin(turn["finishedAt"], created, updated) {
		return false
	}
	for key, limit := range map[string]int{"statusLabel": stMaxPersisted, "runtimeModel": stMaxPersisted, "planExplanation": stMaxDetail, "diff": stMaxAnswer, "review": stMaxAnswer, "error": stMaxNotice} {
		if !stOptionalText(turn, key, limit) {
			return false
		}
	}
	for _, key := range []string{"reasoningBreak", "contextCompacted"} {
		if value, exists := turn[key]; exists && !stIsBool(value) {
			return false
		}
	}
	if tier, exists := turn["runtimeServiceTier"]; exists && tier != nil && !stCanonical(tier, 128) {
		return false
	}
	if author, exists := turn["author"]; exists {
		item := stMap(author)
		if !stOnly(item, "model", "effort") {
			return false
		}
		for _, value := range item {
			if !stNonEmpty(value, 4096) || strings.TrimSpace(stString(value)) == "" {
				return false
			}
		}
	}
	if foreground, exists := turn["foreground"]; exists && !stValidForeground(stMap(foreground)) {
		return false
	}
	if snapshot, exists := turn["lastAssistantMessage"]; exists {
		item := stMap(snapshot)
		if !stOnly(item, "itemId", "text") || !stCanonical(item["itemId"], 1024) || !stBounded(item["text"], 100000) {
			return false
		}
	}
	if !stBounded(turn["answer"], stMaxAnswer) || !stBounded(turn["reasoning"], stMaxReasoning) {
		return false
	}
	for _, key := range []string{"messages", "timeline", "plan", "activities", "interactions", "notices"} {
		if !stIsArray(turn[key]) {
			return false
		}
	}
	if len(stArray(turn["plan"])) > 200 {
		return false
	}
	for _, value := range stArray(turn["messages"]) {
		if !stValidMessage(stMap(value), created, updated) {
			return false
		}
	}
	for _, value := range stArray(turn["timeline"]) {
		if !stValidTimeline(stMap(value), created, updated) {
			return false
		}
	}
	for _, value := range stArray(turn["plan"]) {
		item := stMap(value)
		if !stOnly(item, "step", "status") || !stBounded(item["step"], stMaxPersisted) || !stOneOf(stString(item["status"]), "pending", "inProgress", "completed") {
			return false
		}
	}
	for _, value := range stArray(turn["activities"]) {
		item := stMap(value)
		if !stOnly(item, "id", "kind", "label", "status", "detail", "toolName", "toolCall", "filePaths") || !stCanonical(item["id"], 1024) || !stOneOf(stString(item["kind"]), "command", "file", "tool", "search", "agent", "subagent", "review", "hook") || !stBounded(item["label"], stMaxDetail) || !stOneOf(stString(item["status"]), "running", "completed", "failed", "cancelled") || !stOptionalText(item, "detail", stMaxDetail) {
			return false
		}
		if name, exists := item["toolName"]; exists && !stNonEmpty(name, 1024) {
			return false
		}
		if call, exists := item["toolCall"]; exists && !stIsBool(call) {
			return false
		}
		if paths, exists := item["filePaths"]; exists {
			if !stIsArray(paths) {
				return false
			}
			for _, path := range stArray(paths) {
				if !stNonEmpty(path, stMaxPersisted) {
					return false
				}
			}
		}
	}
	for _, value := range stArray(turn["interactions"]) {
		if !stValidInteraction(stMap(value)) {
			return false
		}
	}
	for _, value := range stArray(turn["notices"]) {
		item := stMap(value)
		if !stOnly(item, "id", "level", "message") || !stCanonical(item["id"], 1024) || !stOneOf(stString(item["level"]), "info", "warning", "error") || !stBounded(item["message"], stMaxNotice) {
			return false
		}
	}
	if usage, exists := turn["usage"]; exists {
		item := stMap(usage)
		if !stOnly(item, "inputTokens", "cachedInputTokens", "outputTokens", "reasoningTokens", "contextWindow") {
			return false
		}
		for _, value := range item {
			if _, ok := stNumber(value); !ok {
				return false
			}
		}
	}
	return true
}

func stValidForeground(item Map) bool {
	sequence, ok := stNumber(item["sequence"])
	if !ok || sequence < 1 || sequence != math.Trunc(sequence) || sequence > 9007199254740991 {
		return false
	}
	switch item["kind"] {
	case "assistant-text":
		return stOnly(item, "kind", "sequence")
	case "reasoning":
		if !stOnly(item, "kind", "sequence", "text", "textOffset") || !stBounded(item["text"], 65536) || len([]rune(stString(item["text"]))) > 32768 {
			return false
		}
		if offset, exists := item["textOffset"]; exists {
			n, ok := stNumber(offset)
			if !ok || n < 0 || n != math.Trunc(n) || n > 9007199254740991 {
				return false
			}
		}
		return true
	case "tool-call":
		return stOnly(item, "kind", "sequence", "callId", "toolName") && stCanonical(item["callId"], 1024) && stNonEmpty(item["toolName"], 1024)
	}
	return false
}

func stValidMessage(item Map, created, updated int64) bool {
	if !stOnly(item, "id", "role", "kind", "content", "createdAt", "attachments", "annotations", "internal") || !stCanonical(item["id"], 1024) || !stOneOf(stString(item["role"]), "user", "assistant") || !stOneOf(stString(item["kind"]), "prompt", "follow-up", "answer") || !stBounded(item["content"], stMaxPersisted) || !stWithin(item["createdAt"], created, updated) || !stIsArray(item["attachments"]) || len(stArray(item["attachments"])) > 128 {
		return false
	}
	if internal, exists := item["internal"]; exists && internal != true {
		return false
	}
	if annotations, exists := item["annotations"]; exists {
		if !stIsArray(annotations) || len(stArray(annotations)) > 20 {
			return false
		}
		for _, value := range stArray(annotations) {
			if !stValidAnnotation(stMap(value)) {
				return false
			}
		}
	}
	for _, value := range stArray(item["attachments"]) {
		file := stMap(value)
		size, ok := stNumber(file["size"])
		if !stOnly(file, "id", "name", "mimeType", "size", "kind") || !stNonEmpty(file["id"], 1024) || !stBounded(file["name"], 4*1024*1024) || !stBounded(file["mimeType"], 256) || !ok || size < 0 || size != math.Trunc(size) || size > 9007199254740991 || !stOneOf(stString(file["kind"]), "image", "audio", "file") {
			return false
		}
	}
	return true
}

var stUUID = regexp.MustCompile(`(?i)^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$`)

func stValidAnnotation(item Map) bool {
	if !stOnly(item, "id", "comment", "url", "title", "kind", "rect", "viewport", "selector", "text", "screenshotId") || !stUUID.MatchString(stString(item["id"])) || !stBounded(item["comment"], 10000) || strings.TrimSpace(stString(item["comment"])) == "" || !stBounded(item["title"], 2048) || !stOneOf(stString(item["kind"]), "element", "region") || !stOptionalText(item, "selector", 4096) || !stOptionalText(item, "text", 4000) {
		return false
	}
	parsed, err := url.Parse(stString(item["url"]))
	if err != nil || !stOneOf(parsed.Scheme, "http", "https") || parsed.Host == "" {
		return false
	}
	if id, exists := item["screenshotId"]; exists && !stUUID.MatchString(stString(id)) {
		return false
	}
	rect, viewport := stMap(item["rect"]), stMap(item["viewport"])
	if !stOnly(rect, "x", "y", "width", "height") || !stOnly(viewport, "width", "height", "scrollX", "scrollY") {
		return false
	}
	for _, key := range []string{"x", "y", "width", "height"} {
		number, ok := stNumber(rect[key])
		if !ok || number < 0 || number > 100000 || (key == "width" || key == "height") && number == 0 {
			return false
		}
	}
	for _, key := range []string{"width", "height"} {
		number, ok := stNumber(viewport[key])
		if !ok || number <= 0 || number > 100000 {
			return false
		}
	}
	for _, key := range []string{"scrollX", "scrollY"} {
		if _, ok := stNumber(viewport[key]); !ok {
			return false
		}
	}
	return true
}

func stValidTimeline(item Map, created, updated int64) bool {
	if !stCanonical(item["id"], 1024) || !stWithin(item["createdAt"], created, updated) {
		return false
	}
	kind := stString(item["kind"])
	if key := map[string]string{"user-message": "messageId", "activity": "activityId", "interaction": "interactionId", "notice": "noticeId"}[kind]; key != "" {
		return stOnly(item, "id", "kind", "createdAt", key) && stCanonical(item[key], 1024)
	}
	if kind == "assistant" {
		return stOnly(item, "id", "kind", "createdAt", "itemId", "content", "status") && stCanonical(item["itemId"], 1024) && stBounded(item["content"], stMaxAnswer) && stOneOf(stString(item["status"]), "complete", "streaming", "failed", "cancelled")
	}
	if kind == "reasoning" {
		return stOnly(item, "id", "kind", "createdAt", "content") && stBounded(item["content"], stMaxReasoning)
	}
	return stOnly(item, "id", "kind", "createdAt") && stOneOf(kind, "plan", "diff", "review", "context-compaction", "error")
}

func ValidateInteraction(interaction Map) error {
	if !stValidInteraction(interaction) {
		return errors.New("Codex interaction 无效")
	}
	return nil
}

func stValidInteraction(item Map) bool {
	keys := []string{"id", "kind", "title", "detail", "blocksTurn", "status", "resolution", "actions", "questions"}
	if item["kind"] == "mcp-elicitation" {
		keys = append(keys, "elicitation")
	}
	if !stOnly(item, keys...) || !stCanonical(item["id"], 1024) || !stOneOf(stString(item["kind"]), "command-approval", "file-approval", "permissions", "user-input", "mcp-elicitation") || !stBounded(item["title"], stMaxPersisted) || !stOptionalText(item, "detail", stMaxPersisted) || !stIsBool(item["blocksTurn"]) || !stOneOf(stString(item["status"]), "pending", "allowed", "denied", "submitted", "cancelled", "resolved") || !stOptionalText(item, "resolution", 1000) || !stIsArray(item["actions"]) || !stIsArray(item["questions"]) {
		return false
	}
	for _, value := range stArray(item["actions"]) {
		action := stMap(value)
		if !stOnly(action, "id", "intent", "label") || !stOneOf(stString(action["id"]), "allow-once", "allow-session", "deny", "cancel", "submit") || !stOneOf(stString(action["intent"]), "allow", "deny", "cancel", "submit") || !stBounded(action["label"], stMaxPersisted) {
			return false
		}
	}
	for _, value := range stArray(item["questions"]) {
		question := stMap(value)
		if !stOnly(question, "id", "header", "prompt", "secret", "allowOther", "options") || !stNonEmpty(question["id"], stMaxPersisted) || !stOptionalText(question, "header", stMaxPersisted) || !stBounded(question["prompt"], stMaxPersisted) || !stIsBool(question["secret"]) || !stIsBool(question["allowOther"]) || !stIsArray(question["options"]) {
			return false
		}
		for _, value := range stArray(question["options"]) {
			option := stMap(value)
			if !stOnly(option, "id", "label", "description") || !stNonEmpty(option["id"], stMaxPersisted) || !stBounded(option["label"], stMaxPersisted) || !stOptionalText(option, "description", stMaxPersisted) {
				return false
			}
		}
	}
	if item["kind"] != "mcp-elicitation" {
		return true
	}
	elicitation := stMap(item["elicitation"])
	if elicitation["mode"] == "url" {
		return stOnly(elicitation, "mode", "url") && stNonEmpty(elicitation["url"], stMaxPersisted) && len(stArray(item["questions"])) == 0
	}
	questions := stArray(item["questions"])
	return elicitation["mode"] == "form" && stOnly(elicitation, "mode", "requestedSchema", "questionId") && stMap(elicitation["requestedSchema"]) != nil && stNonEmpty(elicitation["questionId"], stMaxPersisted) && len(questions) == 1 && stMap(questions[0])["id"] == elicitation["questionId"]
}
