package main

import (
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

func verifyConditionalSchemas() {
	inputs := []string{
		`{"type":"object","oneOf":[{"type":"object","required":["harnessId","options"],"properties":{"harnessId":{"const":"claude"},"options":{"type":"object"}},"additionalProperties":false},{"type":"object","required":["harnessId","worktree","options"],"properties":{"harnessId":{"const":"claude"},"worktree":{"type":"object"},"options":{"type":"object"}},"additionalProperties":false}]}`,
		`{"type":"object","oneOf":[{"required":["a"]},{"required":["b"]}]}`,
		`{"type":"object","oneOf":[{"required":["a"]}]}`,
		`{"type":"object","if":{"required":["a"]},"then":{"required":["guard"]},"oneOf":[{"required":["a"]},{"required":["b"]}]}`,
	}
	values := []string{`{}`, `{"harnessId":"claude","options":{}}`, `{"harnessId":"claude","worktree":{"name":"branch"},"options":{}}`, `{"a":1}`, `{"b":2}`, `{"a":1,"b":2}`, `{"a":1,"guard":true}`, `{"a":1,"b":2,"guard":true}`, `{"harnessId":"pi","options":{}}`}
	for _, input := range inputs {
		rewritten, err := claude.ToolSchema(json.RawMessage(input))
		must(err)
		var before, after any
		must(json.Unmarshal([]byte(input), &before))
		must(json.Unmarshal(rewritten, &after))
		if _, ok := after.(map[string]any)["oneOf"]; ok {
			panic("Claude tool still has a rejected root oneOf")
		}
		compiler := jsonschema.NewCompiler()
		must(compiler.AddResource("https://fixture.test/before", before))
		must(compiler.AddResource("https://fixture.test/after", after))
		original, err := compiler.Compile("https://fixture.test/before")
		must(err)
		actual, err := compiler.Compile("https://fixture.test/after")
		must(err)
		for _, value := range values {
			var instance any
			must(json.Unmarshal([]byte(value), &instance))
			if (original.Validate(instance) == nil) != (actual.Validate(instance) == nil) {
				panic("Claude conditional schema changed exactly-one acceptance: " + value)
			}
		}
	}
	fmt.Println("PASS Claude tool schemas: nested Harness creation branches, overlapping and singleton unions retain exactly-one validation without root oneOf")
}
