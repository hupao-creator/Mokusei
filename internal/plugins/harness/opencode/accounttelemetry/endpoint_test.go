package accounttelemetry

import "testing"

func TestOfficialEndpointAuthority(t *testing.T) {
	for _, c := range []struct {
		url            string
		messages, want bool
	}{
		{"https://opencode.ai/zen/go/v1", false, true},
		{"https://opencode.ai:443/inference/go/openai/v1/", false, true},
		{"https://opencode.ai/zen/go", false, false}, {"https://opencode.ai/zen/go", true, true},
		{"http://opencode.ai/zen/go/v1", true, false}, {"https://opencode.ai.evil.test/zen/go/v1", true, false},
		{"https://user@opencode.ai/zen/go/v1", true, false}, {"https://opencode.ai:444/zen/go/v1", true, false},
		{"https://opencode.ai/zen/go/v1?", true, false}, {"https://opencode.ai/zen/go/v1#fragment", true, false},
		{"https://opencode.ai/zen/%67o/v1", true, false},
	} {
		t.Run(c.url, func(t *testing.T) {
			if got := OfficialOpenCodeGoEndpoint(c.url, c.messages); got != c.want {
				t.Fatalf("got %v want %v", got, c.want)
			}
		})
	}
}
