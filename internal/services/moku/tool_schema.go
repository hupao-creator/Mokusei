package moku

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

const ThreadCreationSchemaMaxBytes = 64 * 1024
const ThreadCreationOptionsMaxBytes = 64 * 1024
const ThreadCreationPromptMaxCharacters = 1_000_000
const ThreadCreationCwdMaxCharacters = 4096
const ThreadCreationWorktreeNameMaxCharacters = 64

type TargetDescription struct {
	HarnessID   string
	DisplayName string
	// Nil requires on-demand native discovery when DeferredNative is true.
	DeferredNative bool
	NativeSchema   json.RawMessage
}
type ThreadCreationDescription struct {
	Instructions            string
	InputSchema             json.RawMessage
	TargetHarnessIDs        []string
	NativeDescriptionSchema json.RawMessage
}
type CreateRequest struct {
	Prompt       string          `json:"prompt"`
	Cwd          string          `json:"cwd,omitempty"`
	Worktree     *bool           `json:"worktree"`
	WorktreeName string          `json:"worktreeName,omitempty"`
	HarnessID    string          `json:"harnessId"`
	Options      json.RawMessage `json:"options"`
}

// DescribeThreadCreation composes already-acquired schemas. Acquisition and
// availability failures remain owned by the coordinator, outside this pure API.
func DescribeThreadCreation(targets []TargetDescription, cwd string) (ThreadCreationDescription, error) {
	var result ThreadCreationDescription
	if len(targets) == 0 {
		return result, errors.New("Moku 至少需要一个 Target Harness")
	}
	seen := map[string]bool{}
	for _, target := range targets {
		if target.HarnessID == "" {
			return result, errors.New("Moku Target Harness 不能为空")
		}
		if seen[target.HarnessID] {
			return result, errors.New("Moku Target Harness 不能重复")
		}
		seen[target.HarnessID] = true
		result.TargetHarnessIDs = append(result.TargetHarnessIDs, target.HarnessID)
	}
	// Free-text fields must not carry a pattern. Constrained decoders can treat
	// an unanchored pattern as a whole-value assertion and stop at the first
	// match; xAI grok-4.7 did so for grok tool-call arguments, truncating a
	// prompt to its first character. Length bounds stay, and ParseCreateRequest
	// still rejects a trimmed-empty prompt.
	promptSchema := map[string]any{"type": "string", "minLength": 1, "maxLength": ThreadCreationPromptMaxCharacters, "description": "A self-contained first task with all necessary context and expected results."}
	cwdSchema := map[string]any{"type": "string", "minLength": 1, "maxLength": ThreadCreationCwdMaxCharacters, "description": fmt.Sprintf("An existing absolute directory only when the task requires that workspace. Otherwise use worktree:false and omit this field: Mokusei creates a unique temporary directory and returns its absolute path as workspace.cwd. Do not choose /tmp, /private/tmp, or invent a scratch path as a substitute for omission. Do not use the Moku workspace %s.", cwd)}
	worktreeSchema := map[string]any{"type": "boolean", "description": threadCreationWorktreeGuidance}
	worktreeNameSchema := map[string]any{"type": "string", "maxLength": ThreadCreationWorktreeNameMaxCharacters, "not": map[string]any{"pattern": "\u0000"}, "description": "Optional human-readable name for the managed Git worktree directory when worktree:true. Unicode letters and digits are kept; path separators, control characters and every other character become '-'. Leading/trailing '.' and '-' are trimmed and the result is capped at 48 runes before any collision suffix. Blank is treated as absent and keeps the generated task-<id>-<random> name. Existing names get -2..-8, then a short random suffix, then the generated name. The result reports worktreeName, worktreeNameAdjusted and notice when the effective name differs, so adjustments are never silent. Do not use this as a Thread title."}
	variants := []any{}
	deferred := []string{}
	instructions := []string{}
	for _, target := range targets {
		if target.DeferredNative {
			deferred = append(deferred, target.HarnessID)
			variants = append(variants, mokuObjectSchema(map[string]any{
				"prompt": promptSchema, "cwd": cwdSchema, "worktree": worktreeSchema, "worktreeName": worktreeNameSchema,
				"harnessId": map[string]any{"type": "string", "const": target.HarnessID},
				"options":   map[string]any{"type": "object", "minProperties": 1, "description": "First call describe_native_harness for this target and supply its exact required options. Empty/default options are not accepted."},
			}, "harnessId", "options", "worktree", "prompt"))
			instructions = append(instructions, fmt.Sprintf("## %s (%s)\nInstalled native target; model/account capabilities are discovered on demand. Call describe_native_harness before choosing native model options. Then pass every required option from its returned schema to create_thread. Availability is checked again at execution.", target.DisplayName, target.HarnessID))
			continue
		}
		if len(target.NativeSchema) == 0 {
			continue
		}
		schema, err := mokuBoundedObject(target.NativeSchema, target.HarnessID+" settings schema", ThreadCreationSchemaMaxBytes)
		if err != nil {
			return result, err
		}
		if schema["type"] != "object" {
			return result, errors.New("Harness settings schema must describe an object")
		}
		variants = append(variants, mokuObjectSchema(map[string]any{
			"prompt": promptSchema, "cwd": cwdSchema, "worktree": worktreeSchema, "worktreeName": worktreeNameSchema,
			"harnessId": map[string]any{"type": "string", "const": target.HarnessID}, "options": schema,
		}, "harnessId", "options", "worktree", "prompt"))
		instructions = append(instructions, fmt.Sprintf("## %s (%s)\nUse the creation options in this Harness options schema. Supply every required field explicitly; required fields cannot inherit defaults. Omitted optional fields use the configured Thread defaults.", target.DisplayName, target.HarnessID))
	}
	if len(deferred) > 0 {
		result.NativeDescriptionSchema = mokuRaw(mokuObjectSchema(map[string]any{"harnessId": map[string]any{"type": "string", "enum": deferred}}, "harnessId"))
	}
	properties := map[string]any{
		"prompt": promptSchema, "cwd": cwdSchema, "worktree": worktreeSchema, "worktreeName": worktreeNameSchema,
		"harnessId": map[string]any{"type": "string", "enum": result.TargetHarnessIDs},
		"options":   map[string]any{"type": "object", "description": "Settings for the selected harnessId. Match its model-specific branch below; candidate values across branches are not interchangeable. Supply all fields required by that branch explicitly."},
	}
	schema := mokuObjectSchema(properties, "harnessId", "options", "worktree", "prompt")
	// Keep the true/cwd dependency visible to schema clients as well as the parser.
	schema["allOf"] = []any{
		map[string]any{
			"if":   map[string]any{"properties": map[string]any{"worktree": map[string]any{"const": true}}, "required": []string{"worktree"}},
			"then": map[string]any{"required": []string{"cwd"}},
		},
		map[string]any{
			"if":   map[string]any{"properties": map[string]any{"worktree": map[string]any{"const": false}}, "required": []string{"worktree"}},
			"then": map[string]any{"properties": map[string]any{"worktreeName": map[string]any{"pattern": `^\s*$`}}},
		},
	}
	schema["oneOf"] = variants
	result.InputSchema = mokuRaw(mokuVisibleUnionProperties(schema))
	result.Instructions = threadCreationWorktreeGuidance + "\n\n" + strings.Join(instructions, "\n\n")
	return result, nil
}

// ParseCreateRequest validates the protocol boundary. The coordinator must
// additionally resolve HarnessID against its advertised target registry and
// validate Options with the chosen native creation schema.
func ParseCreateRequest(raw json.RawMessage) (CreateRequest, error) {
	var result CreateRequest
	o, err := model.DecodeObject(raw)
	invalid := errors.New("create_thread 参数无效")
	if err != nil || !mokuAllowedKeys(o, "prompt", "cwd", "worktree", "worktreeName", "harnessId", "options") {
		return result, invalid
	}
	prompt, ok := o["prompt"].(string)
	if !ok {
		return result, invalid
	}
	result.Prompt = strings.TrimFunc(prompt, mokuWhitespace)
	if result.Prompt == "" || model.UTF16Length(result.Prompt) > ThreadCreationPromptMaxCharacters {
		return result, invalid
	}
	if value, present := o["cwd"]; present {
		cwd, ok := value.(string)
		if !ok {
			return result, invalid
		}
		result.Cwd = strings.TrimFunc(cwd, mokuWhitespace)
		if result.Cwd == "" || model.UTF16Length(result.Cwd) > ThreadCreationCwdMaxCharacters {
			return result, invalid
		}
	}
	value, present := o["worktree"]
	if !present {
		return result, errors.New("create_thread 缺少必选参数 worktree：必须显式传 true 或 false")
	}
	worktree, ok := value.(bool)
	if !ok || worktree && result.Cwd == "" {
		return result, invalid
	}
	result.Worktree = &worktree
	if value, present := o["worktreeName"]; present {
		name, ok := value.(string)
		// Code points are deliberate: JSON Schema maxLength counts runes, so the
		// parser must count the same unit. prompt/cwd/harnessId keep their
		// historical UTF-16 bounds.
		if !ok || utf8.RuneCountInString(name) > ThreadCreationWorktreeNameMaxCharacters || strings.ContainsRune(name, 0) {
			return result, invalid
		}
		result.WorktreeName = strings.TrimFunc(name, mokuWhitespace)
		if result.WorktreeName != "" && !worktree {
			return result, errors.New("create_thread worktreeName 仅用于 worktree:true；请删除 worktreeName 或改为 worktree:true")
		}
	}
	harnessID, ok := o["harnessId"].(string)
	if !ok || harnessID == "" || strings.TrimFunc(harnessID, mokuWhitespace) != harnessID || model.UTF16Length(harnessID) > 128 || strings.ContainsRune(harnessID, 0) {
		return result, invalid
	}
	result.HarnessID = harnessID
	options, ok := o["options"].(map[string]any)
	if !ok || !mokuFiniteJSON(options) {
		return result, invalid
	}
	result.Options = mokuRaw(options)
	if len(result.Options) > ThreadCreationOptionsMaxBytes {
		return result, invalid
	}
	return result, nil
}

func mokuBoundedObject(raw json.RawMessage, label string, limit int) (map[string]any, error) {
	o, err := model.DecodeObject(raw)
	if err != nil {
		return nil, fmt.Errorf("%s must be a JSON object: %w", label, err)
	}
	if !mokuFiniteJSON(o) {
		return nil, fmt.Errorf("%s must contain finite JSON numbers", label)
	}
	if len(mokuRaw(o)) > limit {
		return nil, fmt.Errorf("%s exceeds %d bytes", label, limit)
	}
	return o, nil
}

func mokuFiniteJSON(value any) bool {
	switch item := value.(type) {
	case json.Number:
		_, ok := mokuNumber(item)
		return ok
	case map[string]any:
		for _, v := range item {
			if !mokuFiniteJSON(v) {
				return false
			}
		}
	case []any:
		for _, v := range item {
			if !mokuFiniteJSON(v) {
				return false
			}
		}
	}
	return true
}

func mokuObjectSchema(properties map[string]any, required ...string) map[string]any {
	keys := make([]any, len(required))
	for i, key := range required {
		keys[i] = key
	}
	return map[string]any{"type": "object", "properties": properties, "required": keys, "additionalProperties": false}
}

// ToolSchemas returns protocol descriptions; the coordinator assigns Execute
// functions by Name so no lifecycle authority is retained in the schema layer.
func ToolSchemas(description ThreadCreationDescription) []plugin.ToolBinding {
	idSchema := map[string]any{"type": "string", "minLength": 1, "maxLength": 128, "pattern": `^[^\s\u0000]+$`}
	// No pattern on free text, for the reason documented on promptSchema.
	textSchema := map[string]any{"type": "string", "minLength": 1, "maxLength": ToolInputMaxCharacters}
	bindings := []plugin.ToolBinding{}
	add := func(name, description string, schema json.RawMessage) {
		bindings = append(bindings, plugin.ToolBinding{Name: name, Description: description, InputSchema: model.CloneRaw(schema)})
	}
	if len(description.NativeDescriptionSchema) > 0 {
		add("describe_native_harness", "Read exact native model, thinking and creation options for an installed target. Call this before selecting options for a deferred native target, then supply the returned required fields to create_thread. This does not create a task.", description.NativeDescriptionSchema)
	}
	add("list_threads", "Discover a page of unarchived Agent Thread identities and task states, most recently updated first. Filter by tags and statuses (both groups must match) and follow nextCursor until null; count is this page and total is all matches. waiting-for-background means the latest execution completed but background work is still running. Pages read live state. Do not repeatedly refresh to report progress or decide whether delegated work is ready for review, validation, completion, or delivery; terminal events arrive automatically. Use get_thread_status for needed workspace and execution details, or read_thread for a specific content question.", ThreadListInputSchema())
	add("create_thread", "Create a normal Agent Thread using native Harness settings and dispatch its first task. Only prompt, harnessId, options, cwd, worktree and worktreeName are accepted. worktreeName is only valid with worktree:true and names the managed worktree directory; Unicode letters/digits are kept, other characters become '-', it is capped at 48 runes, collisions get numeric then random suffixes, and a blank value keeps the generated name. The result reports worktreeName, worktreeNameAdjusted and notice when the effective name differs. Do not send title or name: titles are generated automatically. "+threadCreationWorktreeGuidance+" Omit cwd with worktree:false for a unique temporary workspace. Returns workspace.cwd and, for a Git worktree, workspace.worktreeCwd; use worktreeCwd when present as the execution directory. Returns a hint about automatic execution terminal notifications. If only delegated work remains, end your current Moku turn; the runtime resumes coordination on a terminal event. Do not query repeatedly for progress reports or readiness for review, validation, completion, or delivery.", description.InputSchema)
	add("get_thread_status", "Read one committed Thread status snapshot for an explicit immediate progress request, blocked coordination, or fault diagnosis. Completion, failure, and interruption arrive automatically as terminal events. Do not repeatedly query to report progress or decide whether work is ready for review, validation, completion, or delivery; use facts already available.", mokuRaw(mokuObjectSchema(map[string]any{"threadId": idSchema}, "threadId")))
	add("read_clipboard", "Read only plain text from the local macOS clipboard. Call only when the user explicitly requests it; clipboard content may be sensitive and will be sent to the model. There is no per-tool UI confirmation. maxCharacters counts Unicode code points (default 4000, maximum 20000). Only metadata is stored in Moku's tool-result transcript; native model history may retain the text. An indeterminate access result is an error; do not retry to bypass the user's permission choice.", mokuRaw(mokuObjectSchema(map[string]any{
		"maxCharacters": map[string]any{"type": "integer", "minimum": 1, "maximum": clipboardMaxCharacters, "default": clipboardDefaultCharacters},
	})))
	add("send_to_thread", "Send a follow-up through the Thread Handle. Returns the same automatic terminal notification hint as create_thread, including when a new Execution starts. If only delegated work remains, end your current Moku turn and let the terminal event resume coordination; do not repeatedly query for progress reports or readiness for review, validation, completion, or delivery.", mokuRaw(mokuObjectSchema(map[string]any{"threadId": idSchema, "prompt": textSchema}, "threadId", "prompt")))
	questionSchema := mokuCopyObject(textSchema)
	questionSchema["description"] = "The specific content or diagnostic information needed now to answer the user, unblock a next action, diagnose a fault, or review finished results. Do not retrieve intermediate updates just to report progress or ask readiness questions to wait for delegated work."
	add("read_thread", "Ask a specific content question whose answer is needed now for an explicit user question, a next action otherwise blocked, fault diagnosis, or review of finished results. Specificity alone does not justify reading a running Thread or fetching an intermediate update for a progress report. This invokes an additional model request against a native history fork or captured snapshot; it is not a live status read, and the history may already be stale while the source runs. It does not create a source Execution or mutate the source Thread state. Do not repeatedly query readiness for review, validation, completion, or delivery; automatic terminal events handle waiting.", mokuRaw(mokuObjectSchema(map[string]any{"threadId": idSchema, "question": questionSchema}, "threadId", "question")))
	add("interrupt_thread", "Interrupt the current Executions of one or more ordinary Agent Threads. Attempts every requested thread even if another fails. Returns ordered results with threadId, ok and error on failure; top-level ok is true only if every interruption succeeds.", mokuRaw(mokuObjectSchema(map[string]any{"threadIds": map[string]any{"type": "array", "minItems": 1, "items": idSchema}}, "threadIds")))
	talkSchema := mokuCopyObject(textSchema)
	talkSchema["maxLength"] = TalkTextMaxCharacters
	talkSchema["description"] = TalkTextPolicy
	add("talk", "Show a short progress update or confirmation inside Moku's bar in the Overview. "+TalkTextPolicy+" It only informs the user: it does not end your turn or the task, does not require or wait for a user response, and must not be used to poll delegated Threads for updates. Base each update on facts already available.", mokuRaw(mokuObjectSchema(map[string]any{"text": talkSchema}, "text")))
	// The note text has no pattern on purpose: update_note replaces the whole
	// note, and a constrained decoder that stops at a pattern match would
	// silently drop most of it. minLength stays absent because "" clears.
	noteSchema := map[string]any{"type": "string", "maxLength": NoteTextMaxCharacters, "description": NoteTextPolicy}
	basisSchema := mokuObjectSchema(map[string]any{
		"noteId":          map[string]any{"type": "string", "pattern": `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`},
		"revision":        map[string]any{"type": "integer", "minimum": 1, "maximum": model.MaximumSafeInteger},
		"readingRevision": map[string]any{"type": "integer", "minimum": 0, "maximum": model.MaximumSafeInteger},
	}, "noteId", "revision", "readingRevision")
	add("update_note", "Replace Moku's persistent milestone note. "+NoteTextPolicy+" "+NoteContentGuidance+" Pass the exact context basis as expected (null only before first creation). Returns the committed state, or note_state_changed with the latest state; reconsider before retrying.", mokuRaw(mokuObjectSchema(map[string]any{"text": noteSchema, "expected": map[string]any{"oneOf": []any{map[string]any{"type": "null"}, basisSchema}}}, "text", "expected")))
	return bindings
}

func mokuVisibleUnionProperties(schema map[string]any) map[string]any {
	if _, present := schema["unevaluatedProperties"]; present {
		return schema
	}
	result := mokuCopyObject(schema)
	if properties, ok := schema["properties"].(map[string]any); ok {
		out := mokuCopyObject(properties)
		for key, value := range properties {
			if object, ok := value.(map[string]any); ok {
				out[key] = mokuVisibleUnionProperties(object)
			}
		}
		result["properties"] = out
	}
	for _, keyword := range []string{"oneOf", "anyOf", "allOf"} {
		if branches, ok := schema[keyword].([]any); ok {
			expanded := make([]any, len(branches))
			for i, branch := range branches {
				expanded[i] = branch
				if object, ok := branch.(map[string]any); ok {
					expanded[i] = mokuVisibleUnionProperties(object)
				}
			}
			result[keyword] = expanded
			if keyword != "allOf" {
				result = mokuAddHints(result, mokuUnionHints(expanded))
			}
		}
	}
	if items, ok := schema["items"].(map[string]any); ok {
		result["items"] = mokuVisibleUnionProperties(items)
	}
	return result
}
func mokuUnionHints(values []any) map[string]any {
	result := map[string]any{}
	if len(values) == 0 {
		return result
	}
	schemas := make([]map[string]any, len(values))
	for i, value := range values {
		object, ok := value.(map[string]any)
		if !ok {
			return result
		}
		schemas[i] = object
	}
	types := []any{}
	allTypes := true
	for _, schema := range schemas {
		switch value := schema["type"].(type) {
		case string:
			types = mokuUniqueAppend(types, value)
		case []any:
			for _, v := range value {
				if _, ok := v.(string); !ok {
					allTypes = false
				}
				types = mokuUniqueAppend(types, v)
			}
		case []string:
			for _, v := range value {
				types = mokuUniqueAppend(types, v)
			}
		default:
			allTypes = false
		}
	}
	if allTypes {
		if len(types) == 1 {
			result["type"] = types[0]
		} else {
			result["type"] = types
		}
	}
	allEnum := true
	candidates := []any{}
	for _, schema := range schemas {
		if value, exists := schema["const"]; exists {
			candidates = mokuUniqueAppend(candidates, value)
		} else if values, ok := mokuJSONArray(schema["enum"]); ok {
			for _, v := range values {
				candidates = mokuUniqueAppend(candidates, v)
			}
		} else {
			allEnum = false
		}
	}
	for _, value := range candidates {
		switch value.(type) {
		case nil, string, bool, json.Number, float64, int, int64:
		default:
			allEnum = false
		}
	}
	if allEnum {
		result["enum"] = candidates
	}
	descriptions := []string{}
	keys := []string{}
	for _, schema := range schemas {
		if description, ok := schema["description"].(string); ok && !mokuIncludes(descriptions, description) {
			descriptions = append(descriptions, description)
		}
		if properties, ok := schema["properties"].(map[string]any); ok {
			for key := range properties {
				if !mokuIncludes(keys, key) {
					keys = append(keys, key)
				}
			}
		}
	}
	if len(descriptions) > 0 {
		result["description"] = strings.Join(descriptions, "\n")
	}
	if len(keys) > 0 {
		properties := map[string]any{}
		for _, key := range keys {
			alternatives := []any{}
			for _, schema := range schemas {
				alternatives = append(alternatives, mokuPropertyAlternatives(schema, key)...)
			}
			properties[key] = mokuUnionHints(alternatives)
		}
		result["properties"] = properties
	}
	required := []any{}
	if initial, ok := mokuJSONArray(schemas[0]["required"]); ok {
		for _, key := range initial {
			text, ok := key.(string)
			if !ok {
				continue
			}
			every := true
			for _, schema := range schemas {
				keys, ok := mokuJSONArray(schema["required"])
				if !ok || !mokuValueIncludes(keys, text) {
					every = false
				}
			}
			if every {
				required = append(required, text)
			}
		}
	}
	if len(required) > 0 {
		result["required"] = required
	}
	return result
}
func mokuPropertyAlternatives(value any, key string) []any {
	schema, ok := value.(map[string]any)
	if !ok {
		if value == false {
			return nil
		}
		return []any{map[string]any{}}
	}
	if properties, ok := schema["properties"].(map[string]any); ok {
		if property, present := properties[key]; present {
			return []any{property}
		}
	}
	if patterns, ok := schema["patternProperties"].(map[string]any); ok && len(patterns) > 0 {
		return []any{map[string]any{}}
	}
	if schema["additionalProperties"] == false {
		return nil
	}
	for _, keyword := range []string{"oneOf", "anyOf"} {
		if branches, ok := schema[keyword].([]any); ok {
			alternatives := []any{}
			for _, branch := range branches {
				alternatives = append(alternatives, mokuPropertyAlternatives(branch, key)...)
			}
			return alternatives
		}
	}
	if additional, ok := schema["additionalProperties"].(map[string]any); ok {
		return []any{additional}
	}
	return []any{map[string]any{}}
}
func mokuAddHints(schema, hints map[string]any) map[string]any {
	result := mokuCopyObject(hints)
	for key, value := range schema {
		result[key] = value
	}
	properties, propertiesOK := schema["properties"].(map[string]any)
	hinted, hintedOK := hints["properties"].(map[string]any)
	if propertiesOK || hintedOK {
		out := mokuCopyObject(properties)
		for key, hint := range hinted {
			existing, present := properties[key]
			existingObject, existingOK := existing.(map[string]any)
			hintObject, hintOK := hint.(map[string]any)
			if existingOK && hintOK {
				out[key] = mokuAddHints(existingObject, hintObject)
			} else if !present {
				additional, exists := schema["additionalProperties"]
				if !exists || additional == true {
					out[key] = hint
				}
			}
		}
		result["properties"] = out
	}
	left, leftOK := mokuJSONArray(schema["required"])
	right, rightOK := mokuJSONArray(hints["required"])
	if leftOK || rightOK {
		combined := append([]any{}, left...)
		for _, value := range right {
			combined = mokuUniqueAppend(combined, value)
		}
		result["required"] = combined
	}
	return result
}
func mokuCopyObject(value map[string]any) map[string]any {
	result := make(map[string]any, len(value))
	for k, v := range value {
		result[k] = v
	}
	return result
}
func mokuJSONArray(value any) ([]any, bool) {
	switch array := value.(type) {
	case []any:
		return array, true
	case []string:
		result := make([]any, len(array))
		for i, v := range array {
			result[i] = v
		}
		return result, true
	default:
		return nil, false
	}
}
func mokuValueIncludes(values []any, value any) bool {
	needle := string(mokuRaw(value))
	for _, candidate := range values {
		if string(mokuRaw(candidate)) == needle {
			return true
		}
	}
	return false
}
func mokuUniqueAppend(values []any, value any) []any {
	if !mokuValueIncludes(values, value) {
		return append(values, value)
	}
	return values
}
