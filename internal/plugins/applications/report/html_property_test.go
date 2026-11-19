package report

import (
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
		preview := HTMLPreview(source, "")
		if utf8.RuneCountInString(preview) > MaxPreviewLength {
			t.Fatal("oversized preview")
		}
	})
}
