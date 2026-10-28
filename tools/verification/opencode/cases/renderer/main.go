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
	"strings"
)

//go:embed expected.json.gz
var compressedFixture []byte

func main() {
	formsOutput := flag.String("forms-output", "", "write production public/native form fixtures for the mounted Swift Harness replay")
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

	var fixtures []struct {
		Name     string              `json:"name"`
		State    json.RawMessage     `json:"state"`
		Scope    model.RendererScope `json:"scope"`
		Expected json.RawMessage     `json:"expected"`
	}
	if err = json.Unmarshal(input, &fixtures); err != nil {
		panic(err)
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
			fmt.Fprintln(os.Stderr, "renderer projection mismatch:", fixture.Name)
			panic("renderer migration parity failed")
		}
		if strings.Contains(string(fixture.Expected), `\ud83d"`) && !strings.Contains(string(actual), `\ud83d"`) {
			panic(fixture.Name + ": UTF16 slice surrogate changed")
		}
	}
	fmt.Printf("PASS renderer migration replay: %d original TS scope/projection fixtures\n", len(fixtures))
	replayNativeErrors()
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
		state := oc.State{}
		state.MergeMessages([]any{oc.Object{"id": "assistant", "type": "assistant", "content": []any{
			oc.Object{"type": "tool", "id": "tool", "name": "read", "state": oc.Object{"status": "error", "error": fixture.err}},
		}}}, "session", "execution", false)
		found := false
		for _, message := range state.Messages {
			if message.ToolCallID == "tool" {
				found = true
				if message.Text != fixture.want || !message.IsError || message.Status != "failed" {
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
