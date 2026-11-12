package moku

import (
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

type localSchemaLoader struct{}

func (localSchemaLoader) Load(string) (any, error) {
	return nil, errors.New("Moku schemas cannot load external resources")
}

// The validator belongs to one immutable tool binding. Compile lazily so schema
// failures still pass through the invocation's audit and caller-error handling.
func newToolJSONValidator(schema json.RawMessage) func(json.RawMessage) error {
	var once sync.Once
	var compiled *jsonschema.Schema
	var compileErr error
	return func(jsonValue json.RawMessage) error {
		once.Do(func() {
			definition, err := model.Decode(schema)
			if err != nil {
				compileErr = err
				return
			}
			compiled, compileErr = compileToolSchema(definition)
		})
		if compileErr != nil {
			return compileErr
		}
		value, err := model.Decode(jsonValue)
		if err != nil {
			return err
		}
		return compiled.Validate(value)
	}
}

func validateToolJSON(schema, jsonValue json.RawMessage) error {
	definition, err := model.Decode(schema)
	if err != nil {
		return err
	}
	value, err := model.Decode(jsonValue)
	if err != nil {
		return err
	}
	compiled, err := compileToolSchema(definition)
	if err != nil {
		return err
	}
	return compiled.Validate(value)
}

// normalizeToolArguments repairs one narrow serialization fault before schema
// validation: some Harnesses stringify an object or array argument even though
// the published schema declares a container. Only values whose schema declares
// object/array are decoded, so genuine string fields stay strings and invalid
// JSON still reaches the validator unchanged and reports the original error.
// A declared string alternative also wins: mixed unions keep the literal
// string instead of silently changing its meaning.
//
// Traversal follows properties, items, additionalProperties and the
// allOf/anyOf/oneOf branches. It deliberately does not resolve $ref/$defs and
// does not follow patternProperties, prefixItems or if/then/else; resolving
// references would need a real schema resolver at this boundary. A schema that
// hides a stringified container behind one of those keywords still reaches the
// validator unchanged, so the fault surfaces as the original schema error.
func normalizeToolArguments(schema, raw json.RawMessage) (json.RawMessage, error) {
	definition, err := model.Decode(schema)
	if err != nil {
		return nil, err
	}
	value, err := model.Decode(raw)
	if err != nil {
		return nil, err
	}
	changed := false
	if text, ok := value.(string); ok {
		if decoded, ok := decodeJSONContainer(text); ok {
			value, changed = decoded, true
		}
	}
	value, nested := normalizeJSONContainers(definition, value)
	if !changed && !nested {
		return raw, nil
	}
	return json.Marshal(value)
}

func normalizeJSONContainers(schema, value any) (any, bool) {
	object, ok := schema.(map[string]any)
	if !ok {
		return value, false
	}
	changed := false
	if text, ok := value.(string); ok && schemaDeclaresContainer(object) {
		if decoded, ok := decodeJSONContainer(text); ok {
			value, changed = decoded, true
		}
	}
	switch item := value.(type) {
	case map[string]any:
		properties, _ := object["properties"].(map[string]any)
		for key, property := range properties {
			if child, present := item[key]; present {
				normalized, childChanged := normalizeJSONContainers(property, child)
				item[key], changed = normalized, changed || childChanged
			}
		}
		if additional, ok := object["additionalProperties"].(map[string]any); ok {
			for key, child := range item {
				if _, declared := properties[key]; !declared {
					normalized, childChanged := normalizeJSONContainers(additional, child)
					item[key], changed = normalized, changed || childChanged
				}
			}
		}
	case []any:
		if items, present := object["items"]; present {
			for index, child := range item {
				normalized, childChanged := normalizeJSONContainers(items, child)
				item[index], changed = normalized, changed || childChanged
			}
		}
	}
	for _, keyword := range []string{"allOf", "anyOf", "oneOf"} {
		branches, _ := object[keyword].([]any)
		for _, branch := range branches {
			normalized, branchChanged := normalizeJSONContainers(branch, value)
			value, changed = normalized, changed || branchChanged
		}
	}
	return value, changed
}

// schemaDeclaresContainer reports whether a string at this node may stand in for
// a container. A declared string alternative is authoritative: decoding there
// could rewrite a payload the caller meant literally, so a mixed union such as
// ["string","object"] keeps its string.
func schemaDeclaresContainer(schema map[string]any) bool {
	types := schemaTypes(schema["type"])
	if len(types) > 0 {
		container := false
		for _, name := range types {
			if name == "string" {
				return false
			}
			if name == "object" || name == "array" {
				container = true
			}
		}
		return container
	}
	_, hasProperties := schema["properties"]
	_, hasItems := schema["items"]
	return hasProperties || hasItems
}

func schemaTypes(value any) []string {
	switch item := value.(type) {
	case string:
		return []string{item}
	case []any:
		result := make([]string, 0, len(item))
		for _, entry := range item {
			if name, ok := entry.(string); ok {
				result = append(result, name)
			}
		}
		return result
	case []string:
		return item
	}
	return nil
}

func decodeJSONContainer(text string) (any, bool) {
	trimmed := strings.TrimSpace(text)
	if len(trimmed) == 0 || (trimmed[0] != '{' && trimmed[0] != '[') {
		return nil, false
	}
	value, err := model.Decode([]byte(trimmed))
	if err != nil {
		return nil, false
	}
	switch value.(type) {
	case map[string]any, []any:
		return value, true
	}
	return nil, false
}

func compileToolSchema(definition any) (*jsonschema.Schema, error) {
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft7)
	compiler.UseLoader(localSchemaLoader{})
	compiler.UseRegexpEngine(compileMokuRegexp)
	if err := compiler.AddResource("urn:mokusei:moku-tool", definition); err != nil {
		return nil, err
	}
	return compiler.Compile("urn:mokusei:moku-tool")
}

type mokuRegexp struct{ *regexp2.Regexp }

func (r mokuRegexp) MatchString(text string) bool {
	ok, err := r.Regexp.MatchString(text)
	return err == nil && ok
}
func compileMokuRegexp(pattern string) (jsonschema.Regexp, error) {
	compiled, err := regexp2.Compile(pattern, regexp2.ECMAScript)
	if err != nil {
		return nil, err
	}
	compiled.MatchTimeout = time.Second
	return mokuRegexp{compiled}, nil
}
