package moku

import (
	"encoding/json"
	"errors"
	"github.com/dlclark/regexp2"
	"sync"
	"time"

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
