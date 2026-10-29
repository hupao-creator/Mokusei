package pi

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type editorStateStore struct{ raw json.RawMessage }

func (s *editorStateStore) Read() json.RawMessage { return append(json.RawMessage(nil), s.raw...) }
func (s *editorStateStore) Commit(_ context.Context, raw json.RawMessage) error {
	s.raw = append(json.RawMessage(nil), raw...)
	return nil
}

func TestEditorPrefillReachesCommittedPublicForm(t *testing.T) {
	for _, prefill := range []string{"PREFILL_KEEP_43E9\nsecond line 中文 🚀", "", "  literal\n\ttext  "} {
		t.Run(prefill, func(t *testing.T) {
			event, err := decodeEvent(map[string]any{"type": "extension_ui_request", "id": "editor", "method": "editor", "title": "Edit", "prefill": prefill})
			if err != nil {
				t.Fatal(err)
			}
			if event.Prefill == nil || *event.Prefill != prefill {
				t.Fatalf("event=%+v", event)
			}
			// Retain the field through the normalized event wire representation as well.
			raw, _ := json.Marshal(event)
			var normalized Event
			if err = json.Unmarshal(raw, &normalized); err != nil {
				t.Fatal(err)
			}
			store := &editorStateStore{}
			state, _ := decodeState(nil)
			state.Executions = []model.PublicExecution{{ExecutionID: "execution", Status: "running", Interactions: []model.PublicInteraction{}}}
			h := &threadHandle{ctx: context.Background(), state: state, open: plugin.OpenContext{SessionState: store}, interactions: map[string]pendingInteraction{}}
			if err = h.interactionLocked(normalized, &h.state.Executions[0]); err != nil {
				t.Fatal(err)
			}
			var committed State
			if err = json.Unmarshal(store.Read(), &committed); err != nil {
				t.Fatal(err)
			}
			interaction := committed.Executions[0].Interactions[0]
			form := interaction.Questions[0].Form
			if form == nil || form.Type != "string" {
				t.Fatalf("missing editor form: %+v", form)
			}
			var initial string
			if err = json.Unmarshal(form.Default, &initial); err != nil || initial != prefill {
				t.Fatalf("initial=%q err=%v", initial, err)
			}
			edited := prefill + " edited"
			answer, _ := json.Marshal(edited)
			checked := model.ValidatePublicInteractionAnswers(interaction, map[string]json.RawMessage{"answer": answer})
			if !checked.Valid || checked.ValidatedFormValues["answer"] != edited {
				t.Fatalf("edited answer=%+v", checked)
			}
		})
	}
}

func TestEditorPrefillBoundary(t *testing.T) {
	for _, value := range []any{false, float64(42), nil, []any{"text"}} {
		if _, err := decodeEvent(map[string]any{"type": "extension_ui_request", "id": "editor", "method": "editor", "prefill": value}); err == nil {
			t.Fatalf("accepted malformed prefill %v", value)
		}
	}
	event, err := decodeEvent(map[string]any{"type": "extension_ui_request", "id": "editor", "method": "editor"})
	if err != nil || event.Prefill != nil {
		t.Fatalf("absent prefill event=%+v err=%v", event, err)
	}
}
