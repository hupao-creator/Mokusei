package report

import (
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

// PBT-REPORT-PREVIEW: README.md
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
			source = source[:8192]
		}
		// Generate a body with known counts independent of the parser. Inline
		// markup splits a word while head, template and cover-style ink add none.
		han, words := len(source)%601, utf8.RuneCountInString(source)%503
		body := fmt.Sprintf("<head><title>Hidden title</title></head><body>%s%s<p hidden>hidden text</p><template>hidden words</template><style>p{color:red}</style></body>",
			strings.Repeat("讀", han), strings.Repeat("re<b>ad</b> ", words))
		_, seconds := projectReaderText(body, "")
		if 20*seconds < 4*han+5*words || 20*seconds >= 4*han+5*words+20 {
			t.Fatalf("incorrect estimate for %d characters and %d words: %d", han, words, seconds)
		}
		preview, _ := projectReaderText(source, "")
		if utf8.RuneCountInString(preview) > MaxPreviewLength {
			t.Fatal("oversized preview")
		}
	})
}
