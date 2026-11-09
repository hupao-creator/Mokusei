package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

// Exercise the advertised contract and the parser independently, including
// clients that bypass tool-schema validation.
func runCreationContractReplay() error {
	targets := []moku.TargetDescription{
		{HarnessID: "native", NativeSchema: json.RawMessage(`{"type":"object","properties":{"model":{"type":"string"}},"required":["model"],"additionalProperties":false}`)},
		{HarnessID: "deferred", DeferredNative: true},
	}
	description, err := moku.DescribeThreadCreation(targets, "/moku")
	mokuReplayMust(err)
	var definition map[string]any
	mokuReplayMust(json.Unmarshal(description.InputSchema, &definition))
	properties := definition["properties"].(map[string]any)
	targetSchema, ok := properties["target"].(map[string]any)
	mokuReplayCheck(ok, "creation schema omitted target selection")
	targetProperties, ok := targetSchema["properties"].(map[string]any)
	mokuReplayCheck(ok, "creation schema omitted harness-specific target properties")
	for _, target := range targets {
		_, present := targetProperties[target.HarnessID]
		mokuReplayCheck(present, "creation schema omitted target settings for "+target.HarnessID)
	}
	required := definition["required"].([]any)
	worktreeRequired, targetRequired := false, false
	for _, key := range required {
		worktreeRequired = worktreeRequired || key == "worktree"
		targetRequired = targetRequired || key == "target"
	}
	mokuReplayCheck(worktreeRequired && targetRequired, "creation schema omitted required target or worktree")
	mokuReplayCheck(required[len(required)-1] == "prompt", "creation schema should generate prompt last")
	prompt, ok := properties["prompt"].(map[string]any)
	mokuReplayCheck(ok, "creation schema omitted prompt")
	_, patterned := prompt["pattern"]
	mokuReplayCheck(!patterned, "free-text prompt schema must not carry pattern: constrained decoders stop at its first match and truncate the value")
	mokuReplayCheck(prompt["minLength"] == float64(1) && prompt["maxLength"] == float64(moku.ThreadCreationPromptMaxCharacters), "prompt schema lost its length bounds")
	name, ok := properties["worktreeName"].(map[string]any)
	mokuReplayCheck(ok, "creation schema omitted worktreeName")
	mokuReplayCheck(name["type"] == "string" && name["maxLength"] == float64(moku.ThreadCreationWorktreeNameMaxCharacters), "creation schema worktreeName lost its rune bound")
	compiled, claudeCompiled := compileCreationReplaySchemas(description.InputSchema)
	cases := targets
	for _, target := range cases {
		for _, choice := range []struct {
			name  string
			value any
			cwd   string
			valid bool
		}{
			{"missing", nil, "", false}, {"false", false, "", true}, {"false-existing", false, "/project", true},
			{"true", true, "/project", true}, {"true-no-cwd", true, "", false}, {"null", nil, "", false},
			{"string", "false", "", false}, {"number", 0, "", false},
		} {
			request := map[string]any{"prompt": "fixture", "target": map[string]any{target.HarnessID: map[string]any{"model": "model"}}}
			if choice.name != "missing" {
				request["worktree"] = choice.value
			}
			if choice.cwd != "" {
				request["cwd"] = choice.cwd
			}
			mokuReplayCheck((claudeCompiled.Validate(request) == nil) == choice.valid, target.HarnessID+" "+choice.name+" Claude schema disagrees")
			parsed, parseErr := moku.ParseCreateRequest(mokuReplayRaw(request))
			mokuReplayCheck((parseErr == nil) == choice.valid, fmt.Sprintf("%s %s parser: %v", target.HarnessID, choice.name, parseErr))
			mokuReplayCheck((compiled.Validate(request) == nil) == choice.valid, target.HarnessID+" "+choice.name+" schema disagrees")
			if choice.valid {
				mokuReplayCheck(parsed.Worktree != nil && *parsed.Worktree == choice.value, "parser lost explicit boolean")
				mokuReplayCheck(parsed.HarnessID == target.HarnessID && string(parsed.Options) == `{"model":"model"}`, "parser lost selected harness or native settings")
			}
			if choice.name == "missing" {
				mokuReplayCheck(strings.Contains(parseErr.Error(), "worktree") && strings.Contains(parseErr.Error(), "缺少"), "parser missing-parameter error unclear")
			}
		}
	}
	// Optional worktreeName is shared by every represented schema and the
	// parser. Blank is treated as absent with either boolean; a non-blank value
	// requires worktree:true. Length counts Unicode runes.
	namedTarget := targets[0]
	namedRequest := func(worktree any, name any) map[string]any {
		return map[string]any{"prompt": "fixture", "target": map[string]any{namedTarget.HarnessID: map[string]any{"model": "model"}}, "worktree": worktree, "cwd": "/project", "worktreeName": name}
	}
	for name, request := range map[string]map[string]any{
		"custom":      namedRequest(true, "fix auth"),
		"blank":       namedRequest(true, "   "),
		"blank-false": namedRequest(false, "   "),
		"unicode":     namedRequest(true, "修复登录 fix"),
		"64-runes":    namedRequest(true, strings.Repeat("汉", moku.ThreadCreationWorktreeNameMaxCharacters)),
	} {
		mokuReplayCheck(compiled.Validate(request) == nil, "creation schema rejected worktreeName "+name)
		mokuReplayCheck(claudeCompiled.Validate(request) == nil, "Claude wire schema rejected worktreeName "+name)
		parsed, parseErr := moku.ParseCreateRequest(mokuReplayRaw(request))
		mokuReplayMust(parseErr)
		switch name {
		case "blank", "blank-false":
			mokuReplayCheck(parsed.WorktreeName == "", "blank worktreeName did not become absent")
		case "custom":
			mokuReplayCheck(parsed.WorktreeName == "fix auth", "custom worktreeName was lost")
		case "unicode":
			mokuReplayCheck(parsed.WorktreeName == "修复登录 fix", "Unicode worktreeName was lost")
		case "64-runes":
			mokuReplayCheck(parsed.WorktreeName == strings.Repeat("汉", moku.ThreadCreationWorktreeNameMaxCharacters), "64-rune worktreeName was lost")
		}
	}
	for name, request := range map[string]map[string]any{
		"with-false":    namedRequest(false, "fix-auth"),
		"unicode-false": namedRequest(false, "修复登录"),
		"oversized":     namedRequest(true, strings.Repeat("a", moku.ThreadCreationWorktreeNameMaxCharacters+1)),
		"65-runes":      namedRequest(true, strings.Repeat("汉", moku.ThreadCreationWorktreeNameMaxCharacters+1)),
		"without-bool":  {"prompt": "fixture", "target": map[string]any{namedTarget.HarnessID: map[string]any{"model": "model"}}, "cwd": "/project", "worktreeName": "fix-auth"},
	} {
		mokuReplayCheck(compiled.Validate(request) != nil, "creation schema accepted invalid worktreeName "+name)
		mokuReplayCheck(claudeCompiled.Validate(request) != nil, "Claude wire schema accepted invalid worktreeName "+name)
		_, parseErr := moku.ParseCreateRequest(mokuReplayRaw(request))
		mokuReplayCheck(parseErr != nil, "parser accepted invalid worktreeName "+name)
	}
	nulRequest := namedRequest(true, "fix\x00auth")
	mokuReplayCheck(compiled.Validate(nulRequest) != nil, "creation schema accepted a NUL in worktreeName")
	mokuReplayCheck(claudeCompiled.Validate(nulRequest) != nil, "Claude wire schema accepted a NUL in worktreeName")
	_, nulErr := moku.ParseCreateRequest(mokuReplayRaw(nulRequest))
	mokuReplayCheck(nulErr != nil, "parser accepted a NUL in worktreeName")
	// Free text must survive intact: no schema pattern may shorten a prompt, and
	// the parser keeps rejecting blank input and length overflow.
	target := targets[0]
	makeRequest := func(prompt any) map[string]any {
		return map[string]any{"prompt": prompt, "target": map[string]any{target.HarnessID: map[string]any{"model": "model"}}, "worktree": false}
	}
	for _, prompt := range []any{"", "   ", "\t\r\n\ufeff", strings.Repeat("x", moku.ThreadCreationPromptMaxCharacters+1)} {
		_, parseErr := moku.ParseCreateRequest(mokuReplayRaw(makeRequest(prompt)))
		mokuReplayCheck(parseErr != nil, fmt.Sprintf("parser accepted blank or oversized prompt %q", prompt))
	}
	mokuReplayCheck(compiled.Validate(makeRequest("")) != nil, "creation schema accepted an empty prompt")
	longPrompt := strings.Repeat("完整的任务说明 with punctuation, \"quotes\" and\n newlines.\n", 200) + "END"
	longRequest := makeRequest(longPrompt)
	mokuReplayCheck(compiled.Validate(longRequest) == nil, "creation schema rejected a long valid prompt")
	mokuReplayCheck(claudeCompiled.Validate(longRequest) == nil, "Claude wire schema rejected a long valid prompt")
	longParsed, parseErr := moku.ParseCreateRequest(mokuReplayRaw(longRequest))
	mokuReplayMust(parseErr)
	mokuReplayCheck(longParsed.Prompt == longPrompt, "parser truncated or altered a long prompt")
	freeText := map[string]string{"create_thread": "prompt", "send_to_thread": "prompt", "read_thread": "question", "talk": "text"}
	for _, binding := range moku.ToolSchemas(description) {
		field, ok := freeText[binding.Name]
		if !ok {
			continue
		}
		delete(freeText, binding.Name)
		var input map[string]any
		mokuReplayMust(json.Unmarshal(binding.InputSchema, &input))
		properties, _ := input["properties"].(map[string]any)
		property, _ := properties[field].(map[string]any)
		_, patterned := property["pattern"]
		mokuReplayCheck(property != nil && !patterned, binding.Name+"."+field+" must not carry a pattern")
	}
	mokuReplayCheck(len(freeText) == 0, "missing free-text tool bindings")
	worktreeGuidance := fmt.Sprint(definition["properties"].(map[string]any)["worktree"])
	mokuReplayCheck(strings.Contains(worktreeGuidance, "worktree:true by default") && strings.Contains(worktreeGuidance, "even without parallel tasks") && strings.Contains(worktreeGuidance, "Use false only when no eligible Git workspace exists, the user requests the existing checkout, or the task requires its uncommitted changes or live state") && strings.Contains(worktreeGuidance, "Use create_thread's managed worktree rather than asking the Agent to create one"), "creation guidance lost worktree default, exceptions or managed creation")
	for _, binding := range moku.ToolSchemas(description) {
		if binding.Name == "create_thread" {
			mokuReplayCheck(strings.Contains(binding.Description, "worktree:true by default"), "tool worktree default missing")
		}
	}
	runCreationTargetContractReplay()
	fmt.Println("PASS create_thread free-text prompt has no pattern, keeps length bounds, rejects blank/oversized input and preserves a long prompt; worktreeName is optional, rune-bounded, Unicode-preserving, accepts blank as absent, requires worktree:true for a non-blank value and is advertised by native/deferred and Claude schemas; required worktree and selected target survive native/deferred schemas, Claude wire schema and parser")
	return nil
}

func runCreationTargetContractReplay() {
	pi := moku.TargetDescription{HarnessID: "pi", NativeSchema: json.RawMessage(`{
		"type": "object",
		"oneOf": [{
			"type": "object", "additionalProperties": false,
			"required": ["provider", "model", "thinking"],
			"properties": {
				"provider": {"const": "deepseek"},
				"model": {"type": "string", "enum": ["deepseek-flash"]},
				"thinking": {
					"type": "object", "additionalProperties": false, "required": ["mode", "effort"],
					"properties": {"mode": {"const": "effort"}, "effort": {"enum": ["high"]}}
				}
			}
		}, {
			"type": "object", "additionalProperties": false,
			"required": ["provider", "model", "thinking"],
			"properties": {
				"provider": {"const": "openai"},
				"model": {"type": "string", "enum": ["pi-other-model"]},
				"thinking": {
					"type": "object", "additionalProperties": false, "required": ["mode"],
					"properties": {"mode": {"const": "off"}}
				}
			}
		}]
	}`)}
	opencode := moku.TargetDescription{HarnessID: "opencode", NativeSchema: json.RawMessage(`{
		"type": "object", "additionalProperties": false,
		"required": ["provider", "model", "thinking", "permissionMode"],
		"properties": {
			"agent": {"type": "string", "enum": ["build"]},
			"permissionMode": {"type": "string", "enum": ["auto"]},
			"provider": {"const": "opencode"},
			"model": {"type": "string", "enum": ["opencode-model"]},
			"thinking": {
				"type": "object", "additionalProperties": false, "required": ["mode"],
				"properties": {"mode": {"const": "fixed"}}
			}
		}
	}`)}
	piOptions := func(extra map[string]any) map[string]any {
		options := map[string]any{
			"provider": "deepseek", "model": "deepseek-flash",
			"thinking": map[string]any{"mode": "effort", "effort": "high"},
		}
		for key, value := range extra {
			options[key] = value
		}
		return options
	}
	opencodeOptions := map[string]any{
		"provider": "opencode", "model": "opencode-model", "agent": "build", "permissionMode": "auto",
		"thinking": map[string]any{"mode": "fixed"},
	}
	request := func(target any) map[string]any {
		return map[string]any{"prompt": "fixture", "worktree": false, "target": target}
	}
	extraRoot := request(map[string]any{"pi": piOptions(nil)})
	extraRoot["agent"] = "build"
	oldFields := request(map[string]any{"pi": piOptions(nil)})
	oldFields["harnessId"], oldFields["options"] = "pi", piOptions(nil)
	// The parser owns the envelope and preserves native settings without interpreting them.
	// Advertised-target membership and native fields belong to schema/admission.
	cases := []struct {
		name        string
		request     map[string]any
		schemaValid bool
		parserValid bool
	}{
		{"pi", request(map[string]any{"pi": piOptions(nil)}), true, true},
		{"pi-other-native-branch", request(map[string]any{"pi": map[string]any{"provider": "openai", "model": "pi-other-model", "thinking": map[string]any{"mode": "off"}}}), true, true},
		{"pi-mismatched-native-choice", request(map[string]any{"pi": piOptions(map[string]any{"thinking": map[string]any{"mode": "off"}})}), false, true},
		{"opencode", request(map[string]any{"opencode": opencodeOptions}), true, true},
		{"pi-agent", request(map[string]any{"pi": piOptions(map[string]any{"agent": "build"})}), false, true},
		{"pi-permission", request(map[string]any{"pi": piOptions(map[string]any{"permissionMode": "auto"})}), false, true},
		{"pi-copied-opencode-fields", request(map[string]any{"pi": piOptions(map[string]any{"agent": "build", "permissionMode": "auto"})}), false, true},
		{"pi-opencode-settings", request(map[string]any{"pi": opencodeOptions}), false, true},
		{"opencode-pi-settings", request(map[string]any{"opencode": piOptions(nil)}), false, true},
		{"pi-empty-settings", request(map[string]any{"pi": map[string]any{}}), false, true},
		{"empty-target", request(map[string]any{}), false, false},
		{"multiple-targets", request(map[string]any{"pi": piOptions(nil), "opencode": opencodeOptions}), false, false},
		{"unknown-target", request(map[string]any{"unknown": piOptions(nil)}), false, true},
		{"null-target", request(nil), false, false},
		{"array-target", request([]any{}), false, false},
		{"string-target", request("pi"), false, false},
		{"null-native-settings", request(map[string]any{"pi": nil}), false, false},
		{"array-native-settings", request(map[string]any{"pi": []any{}}), false, false},
		{"padded-harness-key", request(map[string]any{" pi ": piOptions(nil)}), false, false},
		{"missing-target", map[string]any{"prompt": "fixture", "worktree": false}, false, false},
		{"removed-envelope", map[string]any{"prompt": "fixture", "worktree": false, "harnessId": "pi", "options": piOptions(nil)}, false, false},
		{"mixed-envelopes", oldFields, false, false},
		{"extra-root-field", extraRoot, false, false},
	}
	for _, targets := range [][]moku.TargetDescription{{opencode, pi}, {pi, opencode}} {
		description, err := moku.DescribeThreadCreation(targets, "/moku")
		mokuReplayMust(err)
		var definition map[string]any
		mokuReplayMust(json.Unmarshal(description.InputSchema, &definition))
		properties := definition["properties"].(map[string]any)
		_, oldHarness := properties["harnessId"]
		_, oldOptions := properties["options"]
		_, rootUnion := definition["oneOf"]
		mokuReplayCheck(!oldHarness && !oldOptions && !rootUnion, "creation schema retained a shared harness/options envelope or root union")
		targetSchema, ok := properties["target"].(map[string]any)
		mokuReplayCheck(ok, "creation schema omitted target properties")
		targetProperties, ok := targetSchema["properties"].(map[string]any)
		mokuReplayCheck(ok && len(targetProperties) == len(targets), "creation schema did not expose one property per target")
		for id, expectedFields := range map[string][]string{
			"pi":       {"provider", "model", "thinking"},
			"opencode": {"provider", "model", "thinking", "agent", "permissionMode"},
		} {
			native := targetProperties[id].(map[string]any)
			fields, ok := native["properties"].(map[string]any)
			mokuReplayCheck(ok && len(fields) == len(expectedFields), id+" advertised fields were missing or mixed with another harness")
			for _, key := range expectedFields {
				_, present := fields[key]
				mokuReplayCheck(present, id+" did not directly advertise "+key+" to schema clients")
			}
		}
		selectors, ok := targetSchema["oneOf"].([]any)
		mokuReplayCheck(ok && len(selectors) == len(targets), "target schema omitted its single-selection rule")
		for i, raw := range selectors {
			selector := raw.(map[string]any)
			required, ok := selector["required"].([]any)
			_, fields := selector["properties"]
			mokuReplayCheck(ok && len(required) == 1 && required[0] == targets[i].HarnessID && !fields, "target selector must preserve configured order without repeating native fields")
		}
		compiled, claudeCompiled := compileCreationReplaySchemas(description.InputSchema)
		order := targets[0].HarnessID + "/" + targets[1].HarnessID
		for _, choice := range cases {
			for _, wire := range []struct {
				name   string
				schema *jsonschema.Schema
			}{{"native", compiled}, {"Claude", claudeCompiled}} {
				validationErr := wire.schema.Validate(choice.request)
				mokuReplayCheck((validationErr == nil) == choice.schemaValid, order+" "+wire.name+" "+choice.name+" schema disagrees")
				if choice.name == "pi-copied-opencode-fields" {
					message := validationErr.Error()
					mokuReplayCheck(strings.Contains(message, "agent") && strings.Contains(message, "permissionMode"), wire.name+" omitted the selected Pi field errors")
					mokuReplayCheck(!strings.Contains(message, "opencode"), wire.name+" attributed an unselected harness's errors to Pi")
				}
			}
			parsed, parseErr := moku.ParseCreateRequest(mokuReplayRaw(choice.request))
			mokuReplayCheck((parseErr == nil) == choice.parserValid, fmt.Sprintf("%s %s parser: %v", order, choice.name, parseErr))
			if choice.parserValid {
				for id, options := range choice.request["target"].(map[string]any) {
					mokuReplayCheck(parsed.HarnessID == id && string(parsed.Options) == string(mokuReplayRaw(options)), choice.name+" parser changed selected harness or native settings")
				}
			}
		}
	}
	fmt.Println("PASS create_thread target properties keep Pi/OpenCode fields separate, reject copied settings and removed envelopes, enforce one advertised target, preserve native settings through the parser, and report only selected-harness errors in either order through native/Claude schemas")
}

func compileCreationReplaySchemas(raw json.RawMessage) (*jsonschema.Schema, *jsonschema.Schema) {
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft7)
	compiler.UseRegexpEngine(func(pattern string) (jsonschema.Regexp, error) {
		r, err := regexp2.Compile(pattern, regexp2.ECMAScript)
		if err != nil {
			return nil, err
		}
		r.MatchTimeout = time.Second
		return creationReplayRegexp{r}, nil
	})
	var definition any
	mokuReplayMust(json.Unmarshal(raw, &definition))
	mokuReplayMust(compiler.AddResource("urn:creation", definition))
	compiled, err := compiler.Compile("urn:creation")
	mokuReplayMust(err)
	rewritten, err := claude.ToolSchema(raw)
	mokuReplayMust(err)
	var claudeDefinition any
	mokuReplayMust(json.Unmarshal(rewritten, &claudeDefinition))
	mokuReplayMust(compiler.AddResource("urn:creation-claude", claudeDefinition))
	claudeCompiled, err := compiler.Compile("urn:creation-claude")
	mokuReplayMust(err)
	return compiled, claudeCompiled
}

type creationReplayRegexp struct{ *regexp2.Regexp }

func (r creationReplayRegexp) MatchString(value string) bool {
	matched, err := r.Regexp.MatchString(value)
	return err == nil && matched
}
