package moku

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// openCodeNativeSchema mirrors the shape OpenCode advertises: the top-level
// thinking property is an untyped object hint, while each model branch adds
// thinkingSchema's bare {"oneOf": [...]} (see
// internal/plugins/harness/opencode/thinking.go) whose branches are the
// containers that must accept a stringified value.
func openCodeNativeSchema() json.RawMessage {
	thinking := map[string]any{
		"oneOf": []any{
			map[string]any{"type": "object", "additionalProperties": false, "required": []string{"mode"},
				"properties": map[string]any{"mode": map[string]any{"type": "string", "const": "off"}}},
			map[string]any{"type": "object", "additionalProperties": false, "required": []string{"mode", "effort"},
				"properties": map[string]any{
					"mode":   map[string]any{"type": "string", "const": "effort"},
					"effort": map[string]any{"type": "string", "enum": []string{"low", "high"}},
				}},
		},
	}
	modelBranch := map[string]any{
		"type": "object", "additionalProperties": false,
		"required": []string{"provider", "model", "thinking"},
		"properties": map[string]any{
			"provider":       map[string]any{"type": "string", "const": "opencode-go"},
			"model":          map[string]any{"type": "string", "enum": []string{"deepseek-v4.1-flash"}},
			"agent":          map[string]any{"type": "string", "enum": []string{"build"}},
			"permissionMode": map[string]any{"type": "string", "enum": []string{"auto", "default"}},
			"thinking":       thinking,
		},
	}
	return mokuRaw(map[string]any{
		"type": "object", "additionalProperties": false,
		"required": []string{"provider", "model", "thinking"},
		"properties": map[string]any{
			"provider":       map[string]any{"type": "string", "minLength": 1},
			"model":          map[string]any{"type": "string", "minLength": 1},
			"agent":          map[string]any{"type": "string", "minLength": 1},
			"permissionMode": map[string]any{"type": "string", "enum": []string{"auto", "default"}},
			"thinking":       map[string]any{"type": "object"},
		},
		"oneOf": []any{modelBranch},
	})
}

func threadCreationSchema(t *testing.T) json.RawMessage {
	t.Helper()
	description, err := DescribeThreadCreation([]TargetDescription{{
		HarnessID:    "opencode",
		NativeSchema: openCodeNativeSchema(),
	}}, "/moku")
	if err != nil {
		t.Fatal(err)
	}
	return description.InputSchema
}

// The payload below is the byte-for-byte shape captured in
// runtime/tool-calls/tools-2026-11-10-0000.jsonl: target is a JSON string
// while target.opencode.thinking is an ordinary object.
func TestToolArgumentsNormalizeLoggedStringifiedTarget(t *testing.T) {
	schema := threadCreationSchema(t)
	raw := json.RawMessage(`{"prompt":"诊断用最小任务：请只回复「ok」两个字，不要做其他事。","target":"{\"opencode\":{\"agent\":\"build\",\"model\":\"deepseek-v4.1-flash\",\"provider\":\"opencode-go\",\"thinking\":{\"effort\":\"low\",\"mode\":\"effort\"}}}","worktree":false}`)
	validate := newToolJSONValidator(schema)
	err := validate(raw)
	if err == nil || !strings.Contains(err.Error(), "/target") || !strings.Contains(err.Error(), "want object") {
		t.Fatalf("stringified target validation error = %v", err)
	}
	normalized, err := normalizeToolArguments(schema, raw)
	if err != nil {
		t.Fatal(err)
	}
	if err = validate(normalized); err != nil {
		t.Fatalf("normalized target was rejected: %v", err)
	}
	request, err := ParseCreateRequest(normalized)
	if err != nil {
		t.Fatal(err)
	}
	if request.HarnessID != "opencode" {
		t.Fatalf("target was not decoded: %s", normalized)
	}
	var options map[string]any
	if err := json.Unmarshal(request.Options, &options); err != nil {
		t.Fatal(err)
	}
	thinking, ok := options["thinking"].(map[string]any)
	if !ok || thinking["mode"] != "effort" || thinking["effort"] != "low" {
		t.Fatalf("logged target was not preserved: %s", request.Options)
	}
}

// The logged payload keeps thinking an object, but a stringified nested object
// inside a stringified target must be repaired too.
func TestToolArgumentsNormalizeStringifiedThinkingInsideTarget(t *testing.T) {
	schema := threadCreationSchema(t)
	raw := json.RawMessage(`{
		"prompt": "inspect the repo",
		"worktree": false,
		"target": "{\"opencode\":{\"agent\":\"build\",\"model\":\"deepseek-v4.1-flash\",\"permissionMode\":\"auto\",\"provider\":\"opencode-go\",\"thinking\":\"{\\\"effort\\\":\\\"high\\\",\\\"mode\\\":\\\"effort\\\"}\"}}"
	}`)
	normalized, err := normalizeToolArguments(schema, raw)
	if err != nil {
		t.Fatal(err)
	}
	if err = newToolJSONValidator(schema)(normalized); err != nil {
		t.Fatalf("normalized target was rejected: %v", err)
	}
	request, err := ParseCreateRequest(normalized)
	if err != nil {
		t.Fatal(err)
	}
	var options map[string]any
	if err := json.Unmarshal(request.Options, &options); err != nil {
		t.Fatal(err)
	}
	thinking, ok := options["thinking"].(map[string]any)
	if !ok || thinking["mode"] != "effort" || thinking["effort"] != "high" {
		t.Fatalf("nested thinking was not normalized: %s", request.Options)
	}
}

func TestToolArgumentsNormalizeDoubleEncodedRequest(t *testing.T) {
	schema := threadCreationSchema(t)
	inner := json.RawMessage(`{
		"prompt": "inspect the repo",
		"worktree": false,
		"target": {"opencode":{"provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":{"mode":"effort","effort":"high"}}}
	}`)
	raw, err := json.Marshal(string(inner))
	if err != nil {
		t.Fatal(err)
	}
	normalized, err := normalizeToolArguments(schema, raw)
	if err != nil {
		t.Fatal(err)
	}
	if err = newToolJSONValidator(schema)(normalized); err != nil {
		t.Fatalf("double-encoded request was rejected: %v", err)
	}
	request, err := ParseCreateRequest(normalized)
	if err != nil {
		t.Fatal(err)
	}
	if request.HarnessID != "opencode" {
		t.Fatalf("target was not decoded: %s", normalized)
	}
}

func TestToolArgumentsLeaveValidPayloadUntouched(t *testing.T) {
	schema := threadCreationSchema(t)
	raw := json.RawMessage(`{"prompt":"<keep> & bytes","worktree":false,"target":{"opencode":{"provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":{"mode":"effort","effort":"high"}}}}`)
	normalized, err := normalizeToolArguments(schema, raw)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(normalized, raw) {
		t.Fatalf("valid payload was rewritten:\n%s\n%s", raw, normalized)
	}
}

func TestToolArgumentsNormalizeOnlySchemaDeclaredContainers(t *testing.T) {
	schema := json.RawMessage(`{
		"type": "object",
		"properties": {
			"text": {"type": "string"},
			"items": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}}}},
			"target": {"type": "object", "properties": {"model": {"type": "string"}}}
		}
	}`)
	raw := json.RawMessage(`{
		"text": "{\"looks\":\"like object\"}",
		"items": "[{\"name\":\"one\"}]",
		"target": "not json"
	}`)
	normalized, err := normalizeToolArguments(schema, raw)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(normalized, &value); err != nil {
		t.Fatal(err)
	}
	if value["text"] != `{"looks":"like object"}` {
		t.Fatalf("declared string field was parsed: %#v", value["text"])
	}
	items, ok := value["items"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("declared array field was not parsed: %#v", value["items"])
	}
	if value["target"] != "not json" {
		t.Fatalf("invalid JSON string was rewritten: %#v", value["target"])
	}
	err = newToolJSONValidator(schema)(normalized)
	if err == nil || !strings.Contains(err.Error(), "/target") {
		t.Fatalf("invalid target string was accepted: %v", err)
	}
}

func TestToolArgumentsKeepDeclaredStringAlternative(t *testing.T) {
	schema := json.RawMessage(`{
		"type": "object",
		"properties": {
			"note": {"type": ["string", "object"], "properties": {"a": {"type": "string"}}},
			"thinking": {"type": ["object", "null"], "properties": {"mode": {"type": "string"}}}
		}
	}`)
	raw := json.RawMessage(`{"note": "{\"a\":\"x\"}", "thinking": "{\"mode\":\"effort\"}"}`)
	normalized, err := normalizeToolArguments(schema, raw)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(normalized, &value); err != nil {
		t.Fatal(err)
	}
	if value["note"] != `{"a":"x"}` {
		t.Fatalf("legal string alternative was rewritten: %#v", value["note"])
	}
	thinking, ok := value["thinking"].(map[string]any)
	if !ok || thinking["mode"] != "effort" {
		t.Fatalf("nullable object alternative was not parsed: %#v", value["thinking"])
	}
}
