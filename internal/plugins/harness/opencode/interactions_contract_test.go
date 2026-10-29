package opencode

import (
	"encoding/json"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// These values were accepted/rejected by OpenCode 2.0.25's native Form API.
// Exercise admission, public preflight and native answer conversion together.
func TestFormStringContractAcrossAdmissionAndAnswers(t *testing.T) {
	cases := []struct {
		name   string
		schema Object
		text   string
		valid  bool
	}{
		{"emoji-min", Object{"minLength": float64(2)}, "😀", true},
		{"emoji-max", Object{"maxLength": float64(1)}, "😀", false},
		{"ascii-min", Object{"minLength": float64(2)}, "AB", true},
		{"dot-ls", Object{"pattern": "^.$"}, "\u2028", false},
		{"dot-ps", Object{"pattern": "^.$"}, "\u2029", false},
		{"dot-cr", Object{"pattern": "^.$"}, "\r", false},
		{"dot-lf", Object{"pattern": "^.$"}, "\n", false},
		{"dot-ascii", Object{"pattern": "^.$"}, "A", true},
		{"literal-dot", Object{"pattern": `^\.$`}, ".", true},
		{"class-dot", Object{"pattern": "^[.]$"}, ".", true},
		{"explicit-ls", Object{"pattern": `^[\s\S]$`}, "\u2028", true},
		{"datetime-js", Object{"format": "date-time"}, "Thu Oct 29 2026 09:00:00 GMT+0800 (China Standard Time)", true},
		{"datetime-legacy", Object{"format": "date-time"}, "Oct 29 2026 09:00:00 GMT+0800", true},
		{"datetime-zone", Object{"format": "date-time"}, "Thu, 29 Oct 2026 09:00:00 XYZ", false},
		{"datetime-iso", Object{"format": "date-time"}, "2026-10-29T09:00:00+08:00", true},
		{"datetime-expanded", Object{"format": "date-time"}, "+010000-01-01T00:00:00.000Z", true},
		{"email-dots", Object{"format": "email"}, "a..b@example.com", true},
		{"email-invalid", Object{"format": "email"}, "a b@example.com", false},
		{"uri-percent", Object{"format": "uri"}, "https://example.com/%zz", true},
		{"uri-relative", Object{"format": "uri"}, "/relative", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			field := Object{"key": "value", "type": "string", "required": true}
			for k, v := range tc.schema {
				field[k] = v
			}
			admit := func() (*State, error) {
				s, err := DecodeState(nil)
				if err != nil {
					t.Fatal(err)
				}
				if err = s.Begin("execution", 1); err != nil {
					t.Fatal(err)
				}
				err = s.Reduce(Event{Type: "form.created", Data: Object{"form": Object{"id": "form", "sessionID": "session", "title": "Contract", "fields": []any{field}}}}, "execution")
				return s, err
			}
			s, err := admit()
			if err != nil {
				t.Fatal(err)
			}
			interaction := s.Current().Interactions[0]
			q := interaction.Questions[0].ID
			raw, _ := json.Marshal(tc.text)
			checked := model.ValidatePublicInteractionAnswers(interaction, map[string]json.RawMessage{q: raw})
			if checked.Valid != tc.valid {
				t.Fatalf("answer valid=%v errors=%v", checked.Valid, checked.Errors)
			}
			if tc.valid {
				answers, err := formAnswers(s.Interactions[0], model.RespondRequest{ValidatedFormValues: checked.ValidatedFormValues})
				if err != nil || answers["value"] != tc.text {
					t.Fatalf("native answers=%v err=%v", answers, err)
				}
			}
			field["default"] = tc.text
			s, err = admit()
			if (err == nil) != tc.valid {
				t.Fatalf("default admission error=%v", err)
			}
			if tc.valid {
				checked = model.ValidatePublicInteractionAnswers(s.Current().Interactions[0], nil)
				if !checked.Valid || checked.ValidatedFormValues[q] != tc.text {
					t.Fatalf("default preflight=%+v", checked)
				}
			}
		})
	}
}

func TestFormEmptyTitleAndExternalURL(t *testing.T) {
	v, err := parseForm(Object{"id": "form", "sessionID": "session", "title": "", "fields": []any{Object{"key": "value", "type": "external", "url": "https://example.com/%zz"}}}, "execution")
	if err != nil {
		t.Fatal(err)
	}
	p := publicInteraction(v)
	if p.Title != "OpenCode request" || p.Questions[0].Prompt != "value\nhttps://example.com/%zz" {
		t.Fatalf("projection=%+v", p)
	}
	q := p.Questions[0]
	checked := model.ValidatePublicInteractionAnswers(p, map[string]json.RawMessage{q.ID: json.RawMessage(`"` + q.Options[0].Value + `"`)})
	if !checked.Valid {
		t.Fatalf("external reply=%+v", checked)
	}
	for _, field := range []string{"id", "sessionID", "title"} {
		form := Object{"id": "form", "sessionID": "session", "title": "", "fields": []any{Object{"key": "v", "type": "string"}}}
		delete(form, field)
		if _, err := parseForm(form, "execution"); err == nil {
			t.Fatalf("missing %s admitted", field)
		}
	}
	if err := ValidateFields([]Object{{"key": "v", "type": "external", "url": "/relative"}}); err == nil {
		t.Fatal("relative external URL admitted")
	}
}
