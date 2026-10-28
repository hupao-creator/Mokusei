// forms checks installed-native contracts without model requests or thread/read lifecycles.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func main() {
	native := os.Getenv("MOKUSEI_OPENCODE_NATIVE_CLI")
	check(native != "", "forms requires explicit native CLI")
	root, err := os.MkdirTemp("", "mokusei-native-forms-")
	must(err)
	defer os.RemoveAll(root)
	cwd := filepath.Join(root, "workspace")
	must(os.Mkdir(cwd, 0700))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "form replay must not invoke a model", 500)
	}))
	defer server.Close()
	env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": root, "OPENCODE_TEST_HOME": root, "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1"}
	for _, name := range []string{"DATA", "CONFIG", "CACHE", "STATE"} {
		env["XDG_"+name+"_HOME"] = filepath.Join(root, name)
	}
	config := oc.Object{"model": oc.Object{"providerID": "fixture", "model": "fixture-model"}, "providers": oc.Object{"fixture": oc.Object{"name": "Fixture", "package": "@opencode/ai/providers/openai-compatible", "settings": oc.Object{"baseURL": server.URL + "/v1", "apiKey": "synthetic-only"}, "models": oc.Object{"fixture-model": oc.Object{"name": "Fixture", "modelID": "fixture-model", "limit": oc.Object{"context": 32000, "output": 1024}}}}}}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	runtime, err := oc.NewRuntime(ctx, oc.Options{CWD: cwd, ExecutablePath: native, Environment: env, Config: config, IsolateConfig: true})
	must(err)
	defer runtime.Close()
	session := oc.NewSessionID()
	must(runtime.ConfigureSession(ctx, session, oc.BridgeConfiguration{}))
	must(runtime.Request(ctx, "POST", "/api/session", oc.Object{"id": session, "location": oc.Object{"directory": cwd}}, nil))
	events := make(chan oc.Event, 64)
	unsubscribe := runtime.Subscribe(func(event oc.Event) error {
		if event.Type == "form.created" {
			select {
			case events <- event:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		return nil
	}, nil)
	defer unsubscribe()
	must(runtime.EventsReady(ctx))
	cases := []struct {
		name   string
		field  oc.Object
		answer any
		valid  bool
	}{
		{"emoji", oc.Object{"type": "string", "minLength": 2, "default": "😀"}, "😀", true},
		{"email", oc.Object{"type": "string", "format": "email", "default": "a..b@example.com"}, "a..b@example.com", true},
		{"uri", oc.Object{"type": "string", "format": "uri", "default": "https://example.com/%zz"}, "https://example.com/%zz", true},
		{"external", oc.Object{"type": "external", "url": "https://example.com/%zz"}, true, true},
		{"expanded", oc.Object{"type": "string", "format": "date-time", "default": "+010000-01-01T00:00:00.000Z"}, "+010000-01-01T00:00:00.000Z", true},
		{"date-js", oc.Object{"type": "string", "format": "date-time"}, "Thu Oct 29 2026 09:00:00 GMT+0800 (China Standard Time)", true},
		{"date-legacy", oc.Object{"type": "string", "format": "date-time"}, "Oct 29 2026 09:00:00 GMT+0800", true},
		{"date-zone", oc.Object{"type": "string", "format": "date-time"}, "Thu, 29 Oct 2026 09:00:00 XYZ", false},
		{"dot-ls", oc.Object{"type": "string", "pattern": "^.$"}, "\u2028", false},
		{"dot-ps", oc.Object{"type": "string", "pattern": "^.$"}, "\u2029", false},
		{"dot-ascii", oc.Object{"type": "string", "pattern": "^.$"}, "A", true},
	}
	for i, tc := range cases {
		id := fmt.Sprintf("frm_contract_%d", i)
		tc.field["key"] = "value"
		must(runtime.Request(ctx, "POST", "/api/session/"+session+"/form", oc.Object{"id": id, "title": "", "fields": []oc.Object{tc.field}}, nil))
		var event oc.Event
		select {
		case event = <-events:
		case <-ctx.Done():
			panic(ctx.Err())
		}
		state, err := oc.DecodeState(nil)
		must(err)
		must(state.Begin("execution", 1))
		must(state.Reduce(event, "execution"))
		interaction := state.Current().Interactions[0]
		check(interaction.Title == "OpenCode request", tc.name+": empty title fallback")
		question := interaction.Questions[0]
		value := tc.answer
		if tc.field["type"] == "external" {
			value = question.Options[0].Value
		}
		raw, err := json.Marshal(value)
		must(err)
		checked := model.ValidatePublicInteractionAnswers(interaction, map[string]json.RawMessage{question.ID: raw})
		check(checked.Valid == tc.valid, fmt.Sprintf("%s public validation: %+v", tc.name, checked))
		if _, hasDefault := tc.field["default"]; hasDefault {
			initial := model.ValidatePublicInteractionAnswers(interaction, nil)
			check(initial.Valid && initial.ValidatedFormValues[question.ID] == tc.answer, tc.name+": initial default differs")
		}
		answer := tc.answer
		if checked.Valid {
			answer = checked.ValidatedFormValues[question.ID]
		}
		err = runtime.Request(ctx, "POST", "/api/session/"+session+"/form/"+id+"/reply", oc.Object{"answer": oc.Object{"value": answer}}, nil)
		if tc.valid {
			must(err)
		} else {
			var failure *oc.RequestError
			check(errors.As(err, &failure) && failure.Status == http.StatusBadRequest, tc.name+": expected native rejection")
		}
		var detail oc.Object
		must(runtime.Request(ctx, "GET", "/api/session/"+session+"/form/"+id, nil, &detail))
		status := detail["state"].(map[string]any)["status"]
		if tc.valid {
			check(status == "answered", tc.name+": native form not answered")
		} else {
			check(status == "pending", tc.name+": rejected form not pending")
		}
		fmt.Printf("PASS native form %s: public/native valid=%v, status=%s\n", tc.name, tc.valid, status)
	}
	must(runtime.Close())
}
