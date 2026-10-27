package moku

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func TestCreateRequestRejectsProviderBinding(t *testing.T) {
	raw := json.RawMessage(`{"prompt":"inspect the repo","harnessId":"pi","worktree":false,"provider":{"connectionId":"local:opencode-go","model":"grok-4.7"},"options":{"provider":"opencode-go","model":"grok-4.7"}}`)
	if _, err := ParseCreateRequest(raw); err == nil {
		t.Fatal("removed top-level Provider binding was accepted")
	}
}

func TestCreateRequestKeepsNativeProviderOption(t *testing.T) {
	raw := json.RawMessage(`{"prompt":"inspect the repo","harnessId":"pi","worktree":false,"options":{"provider":"opencode-go","model":"grok-4.7"}}`)
	request, err := ParseCreateRequest(raw)
	if err != nil {
		t.Fatal(err)
	}
	var options map[string]any
	if err := json.Unmarshal(request.Options, &options); err != nil || options["provider"] != "opencode-go" {
		t.Fatalf("native Harness provider option was lost: %s, %v", request.Options, err)
	}
}

func TestCreateRequestWorktreeName(t *testing.T) {
	request := func(worktree any, name any) json.RawMessage {
		value := map[string]any{"prompt": "inspect the repo", "harnessId": "pi", "options": map[string]any{"model": "m"}, "cwd": "/project"}
		if worktree != nil {
			value["worktree"] = worktree
		}
		if name != nil {
			value["worktreeName"] = name
		}
		raw, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	for name, raw := range map[string]json.RawMessage{
		"absent":             request(true, nil),
		"blank":              request(true, "   "),
		"custom":             request(true, "fix auth"),
		"unicode":            request(true, "修复登录"),
		"unicode-ascii":      request(true, "修复登录 fix"),
		"leading-dot":        request(true, ".hidden"),
		"blank-no-worktree":  request(false, "   "),
		"absent-no-worktree": request(false, nil),
		"64-ascii":           request(true, strings.Repeat("a", ThreadCreationWorktreeNameMaxCharacters)),
		"64-runes":           request(true, strings.Repeat("汉", ThreadCreationWorktreeNameMaxCharacters)),
	} {
		t.Run(name, func(t *testing.T) {
			target, err := ParseCreateRequest(raw)
			if err != nil {
				t.Fatalf("valid worktreeName was rejected: %v", err)
			}
			switch name {
			case "custom":
				if target.WorktreeName != "fix auth" {
					t.Fatalf("worktreeName = %q", target.WorktreeName)
				}
			case "unicode":
				if target.WorktreeName != "修复登录" {
					t.Fatalf("Unicode worktreeName was lost: %q", target.WorktreeName)
				}
			case "unicode-ascii":
				if target.WorktreeName != "修复登录 fix" {
					t.Fatalf("mixed worktreeName was lost: %q", target.WorktreeName)
				}
			case "blank", "blank-no-worktree":
				if target.WorktreeName != "" {
					t.Fatalf("blank worktreeName did not become absent: %q", target.WorktreeName)
				}
			}
		})
	}
	for name, raw := range map[string]json.RawMessage{
		"nonblank-false":   request(false, "fix-auth"),
		"unicode-false":    request(false, "修复登录"),
		"65-ascii":         request(true, strings.Repeat("a", ThreadCreationWorktreeNameMaxCharacters+1)),
		"65-runes":         request(true, strings.Repeat("汉", ThreadCreationWorktreeNameMaxCharacters+1)),
		"nul":              request(true, "fix\x00auth"),
		"non-string":       request(true, 12),
		"null":             request(true, nil),
		"without-worktree": request(nil, "fix-auth"),
	} {
		t.Run(name, func(t *testing.T) {
			if name == "null" {
				raw = json.RawMessage(`{"prompt":"inspect the repo","harnessId":"pi","options":{"model":"m"},"cwd":"/project","worktree":true,"worktreeName":null}`)
			}
			if _, err := ParseCreateRequest(raw); err == nil {
				t.Fatalf("invalid worktreeName was accepted: %s", raw)
			}
		})
	}
}

func TestCreationSchemaAdvertisesWorktreeName(t *testing.T) {
	description, err := DescribeThreadCreation([]TargetDescription{
		{HarnessID: "native", NativeSchema: json.RawMessage(`{"type":"object","properties":{"model":{"type":"string"}},"required":["model"]}`)},
		{HarnessID: "deferred", DeferredNative: true},
	}, "/moku")
	if err != nil {
		t.Fatal(err)
	}
	if err := checkWorktreeNameSchema(description.InputSchema); err != nil {
		t.Fatal(err)
	}
}

// The check itself must fail when a single variant stops advertising the field,
// so this test cannot silently pass after a partial schema regression.
func TestCreationSchemaCheckRejectsVariantWithoutWorktreeName(t *testing.T) {
	description, err := DescribeThreadCreation([]TargetDescription{
		{HarnessID: "native", NativeSchema: json.RawMessage(`{"type":"object","properties":{"model":{"type":"string"}},"required":["model"]}`)},
		{HarnessID: "deferred", DeferredNative: true},
	}, "/moku")
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal(description.InputSchema, &root); err != nil {
		t.Fatal(err)
	}
	variants := root["oneOf"].([]any)
	delete(variants[1].(map[string]any)["properties"].(map[string]any), "worktreeName")
	mutated, err := json.Marshal(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := checkWorktreeNameSchema(mutated); err == nil {
		t.Fatal("schema check accepted a variant without worktreeName")
	}
}

func TestCreationSchemaAndParserRejectNULWorktreeName(t *testing.T) {
	description, err := DescribeThreadCreation([]TargetDescription{{
		HarnessID:    "native",
		NativeSchema: json.RawMessage(`{"type":"object","properties":{"model":{"type":"string"}},"required":["model"]}`),
	}}, "/moku")
	if err != nil {
		t.Fatal(err)
	}
	var definition map[string]any
	if err := json.Unmarshal(description.InputSchema, &definition); err != nil {
		t.Fatal(err)
	}
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft7)
	if err := compiler.AddResource("urn:creation", definition); err != nil {
		t.Fatal(err)
	}
	compiled, err := compiler.Compile("urn:creation")
	if err != nil {
		t.Fatal(err)
	}
	request := map[string]any{
		"prompt": "inspect the repo", "harnessId": "native", "options": map[string]any{"model": "m"},
		"worktree": true, "cwd": "/project", "worktreeName": "fix\x00auth",
	}
	if compiled.Validate(request) == nil {
		t.Fatal("creation schema accepted a NUL in worktreeName")
	}
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseCreateRequest(raw); err == nil {
		t.Fatal("parser accepted a NUL in worktreeName")
	}
}

func checkWorktreeNameSchema(raw json.RawMessage) error {
	var root map[string]any
	if err := json.Unmarshal(raw, &root); err != nil {
		return err
	}
	variants, ok := root["oneOf"].([]any)
	if !ok || len(variants) < 2 {
		return fmt.Errorf("creation schema variants = %d, want native and deferred", len(variants))
	}
	schemas := append([]any{root}, variants...)
	for index, raw := range schemas {
		properties, ok := raw.(map[string]any)["properties"].(map[string]any)
		if !ok {
			return fmt.Errorf("schema branch %d omitted properties", index)
		}
		field, ok := properties["worktreeName"].(map[string]any)
		if !ok {
			return fmt.Errorf("schema branch %d omitted worktreeName", index)
		}
		if field["type"] != "string" || field["maxLength"] != float64(ThreadCreationWorktreeNameMaxCharacters) {
			return fmt.Errorf("schema branch %d worktreeName = %#v", index, field)
		}
		not, _ := field["not"].(map[string]any)
		if not["pattern"] != "\u0000" {
			return fmt.Errorf("schema branch %d worktreeName does not reject NUL: %#v", index, field)
		}
	}
	blankRule := false
	for _, raw := range root["allOf"].([]any) {
		branch := raw.(map[string]any)
		condition, _ := branch["if"].(map[string]any)
		properties, _ := condition["properties"].(map[string]any)
		worktree, _ := properties["worktree"].(map[string]any)
		if worktree["const"] != false {
			continue
		}
		then, _ := branch["then"].(map[string]any)
		thenProperties, _ := then["properties"].(map[string]any)
		name, _ := thenProperties["worktreeName"].(map[string]any)
		blankRule = name["pattern"] == `^\s*$`
	}
	if !blankRule {
		return fmt.Errorf("schema does not allow blank worktreeName with worktree:false")
	}
	return nil
}
