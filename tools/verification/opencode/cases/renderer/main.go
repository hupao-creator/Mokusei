package main

import (
	"bytes"
	"compress/gzip"
	_ "embed"
	"encoding/json"
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
