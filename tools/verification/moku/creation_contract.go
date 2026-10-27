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
	// Both the root and every creation variant must expose the required field.
	schemas := append([]any{definition}, definition["oneOf"].([]any)...)
	for _, raw := range schemas {
		schema := raw.(map[string]any)
		required := schema["required"].([]any)
		found := false
		for _, key := range required {
			found = found || key == "worktree"
		}
		mokuReplayCheck(found, "creation schema branch omitted required worktree")
		mokuReplayCheck(required[len(required)-1] == "prompt", "creation schema branch should generate prompt last")
		properties, ok := schema["properties"].(map[string]any)
		mokuReplayCheck(ok, "creation schema branch omitted properties")
		prompt, ok := properties["prompt"].(map[string]any)
		mokuReplayCheck(ok, "creation schema branch omitted prompt")
		_, patterned := prompt["pattern"]
		mokuReplayCheck(!patterned, "free-text prompt schema must not carry pattern: constrained decoders stop at its first match and truncate the value")
		mokuReplayCheck(prompt["minLength"] == float64(1) && prompt["maxLength"] == float64(moku.ThreadCreationPromptMaxCharacters), "prompt schema lost its length bounds")
		name, ok := properties["worktreeName"].(map[string]any)
		mokuReplayCheck(ok, "creation schema branch omitted worktreeName")
		mokuReplayCheck(name["type"] == "string" && name["maxLength"] == float64(moku.ThreadCreationWorktreeNameMaxCharacters), "creation schema branch worktreeName lost its rune bound")
	}
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
	mokuReplayMust(compiler.AddResource("urn:creation", definition))
	compiled, err := compiler.Compile("urn:creation")
	mokuReplayMust(err)
	rewritten, err := claude.ToolSchema(description.InputSchema)
	mokuReplayMust(err)
	var claudeDefinition any
	mokuReplayMust(json.Unmarshal(rewritten, &claudeDefinition))
	mokuReplayMust(compiler.AddResource("urn:creation-claude", claudeDefinition))
	claudeCompiled, err := compiler.Compile("urn:creation-claude")
	mokuReplayMust(err)
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
			request := map[string]any{"prompt": "fixture", "harnessId": target.HarnessID, "options": map[string]any{"model": "model"}}
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
		return map[string]any{"prompt": "fixture", "harnessId": namedTarget.HarnessID, "options": map[string]any{"model": "model"}, "worktree": worktree, "cwd": "/project", "worktreeName": name}
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
		"without-bool":  {"prompt": "fixture", "harnessId": namedTarget.HarnessID, "options": map[string]any{"model": "model"}, "cwd": "/project", "worktreeName": "fix-auth"},
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
		return map[string]any{"prompt": prompt, "harnessId": target.HarnessID, "options": map[string]any{"model": "model"}, "worktree": false}
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
	for _, text := range []string{description.Instructions, fmt.Sprint(definition["properties"].(map[string]any)["worktree"])} {
		mokuReplayCheck(strings.Contains(text, "Recommend worktree:true") && strings.Contains(text, "parallel code changes") && strings.Contains(text, "Choose false"), "creation guidance lost recommendation or false choice")
	}
	for _, binding := range moku.ToolSchemas(description) {
		if binding.Name == "create_thread" {
			mokuReplayCheck(strings.Contains(binding.Description, "Recommend worktree:true"), "tool recommendation missing")
		}
	}
	fmt.Println("PASS create_thread free-text prompt has no pattern, keeps length bounds, rejects blank/oversized input and preserves a long prompt; worktreeName is optional, rune-bounded, Unicode-preserving, accepts blank as absent, requires worktree:true for a non-blank value and is advertised by native/deferred and Claude schemas; required worktree still validated across native/deferred schemas, Claude wire schema and parser")
	return nil
}

type creationReplayRegexp struct{ *regexp2.Regexp }

func (r creationReplayRegexp) MatchString(value string) bool {
	matched, err := r.Regexp.MatchString(value)
	return err == nil && matched
}
