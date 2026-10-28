package report

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	htmlnode "golang.org/x/net/html"
)

// Capture the registered production callbacks, not a copy of their projection.
type projectionRegistry struct {
	plugin.Registry
	thread plugin.ThreadTypeDefinition
}

func (*projectionRegistry) Collection(plugin.CollectionDefinition) error { return nil }
func (*projectionRegistry) Query(plugin.QueryDefinition) error           { return nil }
func (*projectionRegistry) Command(plugin.CommandDefinition) error       { return nil }
func (r *projectionRegistry) ThreadType(d plugin.ThreadTypeDefinition) error {
	r.thread = d
	return nil
}

func TestReportProjectionParserDepthBoundary(t *testing.T) {
	registry := &projectionRegistry{}
	if err := RegisterDomain(registry); err != nil {
		t.Fatal(err)
	}
	for _, depth := range []int{509, 510, 511, 512, 600} {
		t.Run(fmt.Sprint(depth), func(t *testing.T) {
			source := "<p>BEFORE α &amp; 文本</p>" + strings.Repeat("<div>", depth) + "DEEP" + strings.Repeat("</div>", depth) + "<p>AFTER</p>"
			if _, err := ParseHTML(source); err != nil {
				t.Fatal(err)
			}
			_, parseErr := htmlnode.Parse(strings.NewReader(source))
			if (parseErr != nil) != (depth > 510) {
				t.Fatalf("unexpected parser boundary: %v", parseErr)
			}
			want := "BEFORE α & 文本"
			if parseErr == nil {
				want += " DEEP AFTER"
			}

			data := Data{Scope: "inbox", Title: "Report", HTML: source, ContentRevision: "v1", RelatedExecutions: []model.ExecutionRef{}, TagSources: map[string]TagSource{}}
			raw, err := json.Marshal(data)
			if err != nil {
				t.Fatal(err)
			}
			record := model.ApplicationThreadRecord{Value: raw}
			projection, err := registry.thread.Project(record)
			if err != nil {
				t.Fatal(err)
			}
			var view View
			if err := json.Unmarshal(projection.View, &view); err != nil {
				t.Fatal(err)
			}
			search, err := registry.thread.SearchText(record)
			if err != nil {
				t.Fatal(err)
			}
			if view.PreviewText != want || search != want {
				t.Fatalf("preview=%q search=%q want=%q", view.PreviewText, search, want)
			}
		})
	}
}

func TestReportParserRecoveryKeepsHiddenContentHidden(t *testing.T) {
	deep := strings.Repeat("<div>", 600)
	for _, prefix := range []string{
		"<template>SECRET",
		"<template><svg><style/></svg><template>SECRET",
		"<svg><foreignObject>SECRET",
	} {
		source := "<p>可见 &alpha;</p>" + prefix + deep + "SECRET_AFTER"
		if _, err := htmlnode.Parse(strings.NewReader(source)); err == nil {
			t.Fatal("fixture must exercise parser recovery")
		}
		if got := HTMLSearchText(source); got != "可见 α" {
			t.Fatalf("search = %q", got)
		}
		if got := HTMLPreview(source, ""); got != "可见 α" {
			t.Fatalf("preview = %q", got)
		}
	}
	// No trustworthy visible prefix: leave the projection empty, never expose
	// raw markup or guess the namespace/hidden state after the rejected region.
	if got := HTMLSearchText(deep + "SECRET"); got != "" {
		t.Fatalf("search = %q", got)
	}
}

func TestReportParserRecoveryPreviewAndInputLimits(t *testing.T) {
	prefix := strings.Repeat("文", 300)
	source := "<p>" + prefix + "</p>" + strings.Repeat("<div>", 600)
	if got := HTMLPreview(source, ""); got != strings.Repeat("文", MaxPreviewLength-1)+"…" {
		t.Fatalf("preview = %q", got)
	}
	if got := HTMLSearchText(source); got != prefix {
		t.Fatalf("search length = %d", utf8.RuneCountInString(got))
	}
	if got := HTMLPreview(source, prefix); got != "" {
		t.Fatalf("title stripping = %q", got)
	}

	// A near-limit document must stay usable even when the failure is late.
	source = strings.Repeat("x", MaxHTMLCharacters-3000) + strings.Repeat("<div>", 600)
	if _, err := ParseHTML(source); err != nil {
		t.Fatal(err)
	}
	if got := HTMLSearchText(source); got != strings.Repeat("x", MaxHTMLCharacters-3000) {
		t.Fatalf("search length = %d", len(got))
	}
	if _, err := ParseHTML(source + "x"); err == nil {
		t.Fatal("accepted oversized source")
	}
}

func FuzzReportHTMLProjections(f *testing.F) {
	for _, source := range []string{
		"<p>BEFORE</p>" + strings.Repeat("<div>", 600) + "DEEP",
		"<template><svg><style/></svg>" + strings.Repeat("<div>", 600),
		"<table><tbody><svg><td><desc><select></select></tbody>",
		"<svg><foreignObject><textarea><b>&alpha;</textarea></foreignObject></svg>",
		"<frameset><frame></frameset><body>BODY</body>",
		"<head><noscript><template></noscript></head><p>AFTER</p>",
		"<p>\x00\xff&amp;&#0;&#x110000;</p>",
		"",
	} {
		f.Add(source)
	}
	f.Fuzz(func(t *testing.T, source string) {
		if len(source) > 8192 {
			t.Skip()
		}
		preview := HTMLPreview(source, "")
		search := HTMLSearchText(source)
		if utf8.RuneCountInString(preview) > MaxPreviewLength {
			t.Fatal("oversized preview")
		}
		if utf8.RuneCountInString(search) <= MaxPreviewLength && preview != search {
			t.Fatal("short projections disagree")
		}
	})
}
