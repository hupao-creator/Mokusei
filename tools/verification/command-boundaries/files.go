package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
)

func verifyInputFileBoundaries(ctx context.Context, root string) {
	repository := attachments.New(filepath.Join(root, "attachments"))
	for _, fixture := range []struct{ raw, normalized string }{
		{"https:example.com/path?q=1#part", "https://example.com/path?q=1#part"},
		{`https:\example.com/path`, "https://example.com/path"},
		{"HTTPS://EXAMPLE.COM/path", "https://example.com/path"},
		{"https://bücher.example/path", "https://xn--bcher-kva.example/path"},
		{"https://example.com/%", "https://example.com/%"},
		{"https://example.com/#%", "https://example.com/#%"},
	} {
		payload, err := json.Marshal(map[string]any{
			"parts": []any{map[string]any{"kind": "text", "text": "annotation evidence"}},
			"annotations": []any{map[string]any{
				"id": "123e4567-e89b-42d3-a456-426614174000", "comment": "review", "url": fixture.raw,
				"title": "page", "kind": "region", "rect": map[string]any{"x": 0, "y": 0, "width": 1, "height": 1},
				"viewport": map[string]any{"width": 1, "height": 1, "scrollX": 0, "scrollY": 0},
			}},
		})
		must(err)
		input, err := model.ParsePublicAgentInput(payload)
		must(err)
		canonical, err := repository.CanonicalizeInput(ctx, input)
		must(err)
		var annotations []struct {
			URL string `json:"url"`
		}
		must(json.Unmarshal(canonical.Annotations, &annotations))
		if len(annotations) != 1 || annotations[0].URL != fixture.normalized {
			panic(fmt.Sprintf("annotation URL did not retain public normalization: %+v", annotations))
		}
	}
	fmt.Println("PASS public annotation normalization through attachment ownership boundary")
}
