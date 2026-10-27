package opencode

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

type noSchemaLoader struct{}

func (noSchemaLoader) Load(string) (any, error) {
	return nil, errors.New("completion schemas must contain their referenced resources")
}

type nativeRegexp struct{ *regexp2.Regexp }

func (r nativeRegexp) MatchString(text string) bool {
	ok, err := r.Regexp.MatchString(text)
	return err == nil && ok
}
func compileNativeRegexp(pattern string) (jsonschema.Regexp, error) {
	r, err := regexp2.Compile(pattern, regexp2.ECMAScript)
	if err != nil {
		return nil, err
	}
	r.MatchTimeout = time.Second
	return nativeRegexp{r}, nil
}

// Format assertions were disabled by the TS Ajv completion contract. Remove
// only schema-position format keywords, preserving literal data in const/enum.
func stripSchemaFormats(value any) {
	schema, ok := value.(map[string]any)
	if !ok {
		return
	}
	delete(schema, "format")
	for _, key := range []string{"additionalProperties", "unevaluatedProperties", "propertyNames", "additionalItems", "unevaluatedItems", "contains", "not", "if", "then", "else", "contentSchema"} {
		stripSchemaFormats(schema[key])
	}
	for _, key := range []string{"properties", "patternProperties", "$defs", "definitions", "dependentSchemas"} {
		for _, child := range object(schema[key]) {
			stripSchemaFormats(child)
		}
	}
	for _, key := range []string{"allOf", "anyOf", "oneOf", "prefixItems"} {
		for _, child := range array(schema[key]) {
			stripSchemaFormats(child)
		}
	}
	if items, ok := schema["items"].([]any); ok {
		for _, child := range items {
			stripSchemaFormats(child)
		}
	} else {
		stripSchemaFormats(schema["items"])
	}
	for _, child := range object(schema["dependencies"]) {
		stripSchemaFormats(child)
	}
}
func validateJSONSchema(raw json.RawMessage, value any) error {
	var schema any
	if err := json.Unmarshal(raw, &schema); err != nil {
		return err
	}
	stripSchemaFormats(schema)
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft7)
	compiler.UseLoader(noSchemaLoader{})
	compiler.UseRegexpEngine(compileNativeRegexp)
	const resource = "https://mokusei.invalid/completion.schema.json"
	if err := compiler.AddResource(resource, schema); err != nil {
		return err
	}
	compiled, err := compiler.Compile(resource)
	if err != nil {
		return fmt.Errorf("invalid OpenCode output schema: %w", err)
	}
	if err = compiled.Validate(value); err != nil {
		return fmt.Errorf("OpenCode JSON output did not match requested schema: %w", err)
	}
	return nil
}
