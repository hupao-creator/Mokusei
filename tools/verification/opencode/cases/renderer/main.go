package main

import (
	"bytes"
	"compress/gzip"
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/tools/verification/firstresponse"
	"io"
	"os"
	"reflect"
	"sort"
	"strings"
)

//go:embed expected.json.gz
var compressedFixture []byte

type fixture struct {
	Name     string              `json:"name"`
	State    json.RawMessage     `json:"state"`
	Scope    model.RendererScope `json:"scope"`
	Expected json.RawMessage     `json:"expected"`
}

func main() {
	formsOutput := flag.String("forms-output", "", "write production public/native form fixtures for the mounted Swift Harness replay")
	write := flag.String("write", "", "regenerate expected.json.gz from the embedded fixture states at this path")
	flag.Parse()
	if *formsOutput != "" {
		if err := writeFormFixtures(*formsOutput); err != nil {
			panic(err)
		}
		return
	}
	if _, err := firstresponse.Verify("opencode"); err != nil {
		panic(err)
	}
	reader, err := gzip.NewReader(bytes.NewReader(compressedFixture))
	if err != nil {
		panic(err)
	}
	defer reader.Close()
	input, err := io.ReadAll(io.LimitReader(reader, 2<<20))
	if err != nil {
		panic(err)
	}

	var fixtures []fixture
	if err = json.Unmarshal(input, &fixtures); err != nil {
		panic(err)
	}
	if *write != "" {
		if err = writeExpected(*write, fixtures); err != nil {
			panic(err)
		}
		fmt.Printf("PASS wrote regenerated renderer expectations: %s\n", *write)
		return
	}
	for _, fixture := range fixtures {
		actual, err := (oc.StateAdapter{}).ProjectRenderer(fixture.State, fixture.Scope)
		if err != nil {
			panic(fixture.Name + ": " + err.Error())
		}
		var a, b any
		if err = json.Unmarshal(actual, &a); err != nil {
			panic(err)
		}
		if err = json.Unmarshal(fixture.Expected, &b); err != nil {
			panic(err)
		}
		if object, ok := a.(map[string]any); ok {
			delete(object, "initialResponseScope")
		}
		if !reflect.DeepEqual(a, b) {
			fmt.Fprintln(os.Stderr, "renderer projection mismatch:", fixture.Name, projectionDifference(a, b, "$"))
			panic("renderer projection contract failed")
		}
		if strings.Contains(string(fixture.Expected), `\ud83d"`) && !strings.Contains(string(actual), `\ud83d"`) {
			panic(fixture.Name + ": UTF16 slice surrogate changed")
		}
	}
	fmt.Printf("PASS renderer projection replay: %d fixed scope/projection fixtures\n", len(fixtures))
	replayNativeErrors()
}

// writeExpected reapplies the production renderer to the embedded input states.
// It deliberately rewrites only the expectation side: callers inspect the
// decompressed semantic diff before replacing the embedded fixture.
func writeExpected(path string, fixtures []fixture) error {
	for index := range fixtures {
		actual, err := (oc.StateAdapter{}).ProjectRenderer(fixtures[index].State, fixtures[index].Scope)
		if err != nil {
			return fmt.Errorf("%s: %w", fixtures[index].Name, err)
		}
		// Keep each value as RawMessage so a deliberate lone-surrogate UTF-16
		// boundary stays escaped in the expectation instead of becoming U+FFFD.
		var value map[string]json.RawMessage
		if err = json.Unmarshal(actual, &value); err != nil {
			return err
		}
		delete(value, "initialResponseScope")
		if fixtures[index].Expected, err = json.Marshal(value); err != nil {
			return err
		}
	}
	encoded, err := json.Marshal(fixtures)
	if err != nil {
		return err
	}
	var buffer bytes.Buffer
	writer := gzip.NewWriter(&buffer)
	if _, err = writer.Write(encoded); err != nil {
		return err
	}
	if err = writer.Close(); err != nil {
		return err
	}
	return os.WriteFile(path, buffer.Bytes(), 0o600)
}

func projectionDifference(actual, expected any, path string) string {
	if reflect.DeepEqual(actual, expected) {
		return ""
	}
	if a, ok := actual.(map[string]any); ok {
		if b, ok := expected.(map[string]any); ok {
			keys := make([]string, 0, len(a)+len(b))
			for key := range a {
				keys = append(keys, key)
			}
			for key := range b {
				if _, exists := a[key]; !exists {
					keys = append(keys, key)
				}
			}
			sort.Strings(keys)
			for _, key := range keys {
				av, aok := a[key]
				bv, bok := b[key]
				field := fmt.Sprintf("%s[%q]", path, key)
				if aok != bok {
					return fmt.Sprintf("%s: actual present=%t, expected present=%t", field, aok, bok)
				}
				if difference := projectionDifference(av, bv, field); difference != "" {
					return difference
				}
			}
		}
	}
	if a, ok := actual.([]any); ok {
		if b, ok := expected.([]any); ok {
			if len(a) != len(b) {
				return fmt.Sprintf("%s: actual length=%d, expected length=%d", path, len(a), len(b))
			}
			for i := range a {
				if difference := projectionDifference(a[i], b[i], fmt.Sprintf("%s[%d]", path, i)); difference != "" {
					return difference
				}
			}
		}
	}
	a, _ := json.Marshal(actual)
	b, _ := json.Marshal(expected)
	return fmt.Sprintf("%s: actual=%.240s, expected=%.240s", path, a, b)
}

func replayNativeErrors() {
	const networkError = "OpenCode's free models aren't available from your current network because we've detected abusive traffic from this IP address. This isn't related to your account."
	body, _ := json.Marshal(oc.Object{"type": "error", "error": oc.Object{"type": "FreeTierError", "message": networkError}})
	for _, fixture := range []struct {
		name string
		err  oc.Object
		want string
	}{
		{"network restriction", oc.Object{"type": "provider.auth", "message": networkError, "response": oc.Object{"body": string(body)}}, networkError},
		{"message precedence", oc.Object{"message": "Native tool failure", "response": oc.Object{"body": string(body)}}, "Native tool failure"},
		{"response message fallback", oc.Object{"type": "provider.auth", "response": oc.Object{"body": string(body)}}, networkError},
		{"malformed response fallback", oc.Object{"type": "provider.auth", "response": oc.Object{"body": "invalid JSON"}}, "provider.auth"},
	} {
		state, err := oc.DecodeState(nil)
		if err != nil {
			panic(err)
		}
		state.MergeMessages([]any{oc.Object{"id": "assistant", "type": "assistant", "content": []any{
			oc.Object{"type": "tool", "id": "tool", "name": "read", "state": oc.Object{"status": "error", "error": fixture.err}},
		}}}, "session", "execution", false)
		projected, err := (oc.StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "execution"})
		if err != nil {
			panic(err)
		}
		var value struct {
			Messages []struct {
				ToolCallID    string `json:"toolCallId"`
				ResultDisplay string `json:"resultDisplay"`
				IsError       bool   `json:"isError"`
				Status        string `json:"status"`
			} `json:"messages"`
		}
		if err = json.Unmarshal(projected, &value); err != nil {
			panic(err)
		}
		found := false
		for _, message := range value.Messages {
			if message.ToolCallID == "tool" {
				found = true
				if message.ResultDisplay != fixture.want || !message.IsError || message.Status != "failed" {
					panic(fixture.name + ": native error message lost")
				}
			}
		}
		if !found {
			panic(fixture.name + ": missing failed tool")
		}
	}
	fmt.Println("PASS native errors preserve upstream messages and response fallback")
}

// The Swift replay consumes these exact production projections; it never
// synthesizes public option/question identities or copies their hash algorithm.
func writeFormFixtures(path string) error {
	fixtures := []map[string]any{}
	for _, modeDefault := range []bool{false, true} {
		var form oc.Object
		if err := json.Unmarshal([]byte(`{"id":"frm_metadata<&-\u2028-tail","sessionID":"fixture-session","title":"Native form metadata","fields":[{"key":"default_note","type":"string","title":"Default note","required":true,"default":"DEFAULT_FROM_NATIVE"},{"key":"optional_note","type":"string","title":"Optional note","required":false},{"key":"hidden_note","type":"string","title":"HIDDEN_FIELD_MUST_NOT_APPEAR","hidden":true,"default":"NATIVE_HIDDEN_DEFAULT"},{"key":"mode","type":"string","title":"Select mode","required":true,"options":[{"value":"a","label":"Mode A"},{"value":"b","label":"Mode B"}]},{"key":"only_mode_b","type":"string","title":"ONLY_MODE_B_MUST_NOT_APPEAR_FOR_A","required":true,"when":[{"key":"mode","op":"eq","value":"b"}]}]}`), &form); err != nil {
			return err
		}
		if modeDefault {
			form["fields"].([]any)[3].(map[string]any)["default"] = "a"
		}
		state, err := oc.DecodeState(nil)
		if err != nil {
			return err
		}
		state.NativeSessionID = "fixture-session"
		if err = state.Begin("fixture-execution", 1); err != nil {
			return err
		}
		if err = state.Reduce(oc.Event{Type: "form.created", Data: oc.Object{"form": form}, Created: 2}, "fixture-execution"); err != nil {
			return err
		}
		observation, err := (oc.StateAdapter{}).Project(state.Encode())
		if err != nil {
			return err
		}
		native, err := (oc.StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "full"})
		if err != nil {
			return err
		}
		if observation.LatestExecution == nil || len(observation.LatestExecution.Interactions) != 1 {
			return fmt.Errorf("missing projected form")
		}
		fixtures = append(fixtures, map[string]any{"modeDefault": modeDefault, "interaction": observation.LatestExecution.Interactions[0], "nativeState": json.RawMessage(native)})
	}
	encoded, err := json.Marshal(fixtures)
	if err != nil {
		return err
	}
	if err = os.WriteFile(path, encoded, 0600); err != nil {
		return err
	}
	fmt.Printf("PASS exported %d production OpenCode form projections for mounted Swift Harness replay\n", len(fixtures))
	return nil
}
