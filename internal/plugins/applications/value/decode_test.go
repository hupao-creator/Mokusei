package value

import (
	"encoding/json"
	"testing"
)

func TestRequiredNullableAndOptionalFields(t *testing.T) {
	type value struct {
		Name     string   `json:"name"`
		Nullable *string  `json:"nullable"`
		Optional *string  `json:"optional,omitempty"`
		Items    []string `json:"items"`
	}
	for _, c := range []struct {
		raw   string
		valid bool
	}{
		{`{"name":"ok","nullable":null,"items":[]}`, true},
		{`{"name":"ok","nullable":"yes","optional":"yes","items":["item"]}`, true},
		{`{"nullable":null,"items":[]}`, false},
		{`{"name":null,"nullable":null,"items":[]}`, false},
		{`{"name":"ok","nullable":null,"optional":null,"items":[]}`, false},
		{`{"name":"ok","nullable":null,"items":null}`, false},
		{`{"name":"ok","nullable":null,"items":[null]}`, false},
		{`{"name":"ok","nullable":null,"items":[],"extra":0}`, false},
	} {
		t.Run(c.raw, func(t *testing.T) {
			var v value
			e := Decode(json.RawMessage(c.raw), &v)
			if (e == nil) != c.valid {
				t.Fatalf("valid=%v err=%v", c.valid, e)
			}
		})
	}
}
