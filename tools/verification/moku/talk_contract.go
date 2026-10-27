package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

func runTalkSchemaReplay() error {
	for _, binding := range moku.ToolSchemas(moku.ThreadCreationDescription{}) {
		if binding.Name != "talk" {
			continue
		}
		var definition map[string]any
		mokuReplayMust(json.Unmarshal(binding.InputSchema, &definition))
		properties, ok := definition["properties"].(map[string]any)
		mokuReplayCheck(ok, "talk schema omitted properties")
		text, ok := properties["text"].(map[string]any)
		mokuReplayCheck(ok, "talk schema omitted text")
		_, patterned := text["pattern"]
		mokuReplayCheck(!patterned, "talk text must not carry a pattern: constrained decoders may truncate at its first match")
		mokuReplayCheck(text["minLength"] == float64(1) && text["maxLength"] == float64(moku.TalkTextMaxCharacters), "talk schema lost its length bounds")
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
		mokuReplayMust(compiler.AddResource("urn:talk", definition))
		schema, err := compiler.Compile("urn:talk")
		mokuReplayMust(err)
		mokuReplayCheck(schema.Validate(map[string]any{"text": ""}) != nil, "talk schema accepted empty text")
		mokuReplayCheck(schema.Validate(map[string]any{"text": strings.Repeat("界", moku.TalkTextMaxCharacters+1)}) != nil, "talk schema accepted over-limit text")
		mokuReplayCheck(schema.Validate(map[string]any{"text": "\u0085visible\u0085"}) == nil, "talk schema rejected visible content")
		// Whitespace-only text is now rejected by the coordinator binding, not
		// by a schema pattern; the orchestrator replay covers that rejection.
		fmt.Println("PASS talk schema has no pattern, keeps code-point bounds and accepts visible text")
		return nil
	}
	return fmt.Errorf("missing talk binding")
}
