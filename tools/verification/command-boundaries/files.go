package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
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
	tools, closeTools, err := threadvoice.ProjectReadTools(root)
	must(err)
	defer func() { must(closeTools()) }()
	var read plugin.ToolBinding
	for _, tool := range tools {
		if tool.Name == "read_project_file" {
			read = tool
		}
	}
	for _, suffix := range []string{"中b", "🚀b", "e\u0301b"} {
		text := strings.Repeat("a", 32767) + suffix
		must(os.WriteFile(filepath.Join(root, "page.txt"), []byte(text), 0600))
		var joined strings.Builder
		var offset int64
		for page := 0; ; page++ {
			if page > 2 {
				panic("file pagination did not terminate")
			}
			args, err := json.Marshal(map[string]any{"path": "page.txt", "offset": offset})
			must(err)
			result, err := read.Execute(ctx, plugin.ToolCall{Arguments: args})
			must(err)
			var value struct {
				Text       string `json:"text"`
				NextOffset int64  `json:"nextOffset"`
				End        bool   `json:"end"`
			}
			must(json.Unmarshal(result, &value))
			joined.WriteString(value.Text)
			if value.NextOffset <= offset || len(value.Text) > 32768 {
				panic("file tool did not advance a bounded byte cursor")
			}
			offset = value.NextOffset
			if value.End {
				break
			}
		}
		if joined.String() != text || offset != int64(len(text)) {
			panic("sequential project-file pages corrupted UTF-8 text")
		}
	}
	must(os.WriteFile(filepath.Join(root, "page.txt"), []byte("中"), 0600))
	if _, err := read.Execute(ctx, plugin.ToolCall{Arguments: json.RawMessage(`{"path":"page.txt","offset":1}`)}); err == nil {
		panic("file tool accepted an offset inside a UTF-8 character")
	}
	fmt.Println("PASS public annotation normalization through attachment ownership boundary; UTF-8 project-file pagination and byte-offset validation")
}
