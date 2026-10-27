package taglabel

import (
	"os"
	"slices"
	"strings"
	"testing"
)

func TestNativeEmojiAllowlistMatchesRuntime(t *testing.T) {
	data, err := os.ReadFile("../../../app/macos/Sources/Shared/PluginAPI/SemanticTagEmojiData.swift")
	if err != nil {
		t.Fatal(err)
	}
	_, contents, found := strings.Cut(string(data), "static let sequences = \"\"\"\n")
	contents, _, closed := strings.Cut(contents, "\n    \"\"\"")
	if !found || !closed || !slices.Equal(strings.Fields(contents), strings.Fields(emojiData)) {
		t.Fatal("native/runtime emoji data differ; run python3 scripts/generate-tag-emoji.py")
	}
}

func TestCompleteEmojiSequences(t *testing.T) {
	for _, value := range []string{"🔧", "🏷️", "❤", "❤️", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇨🇳", "1️⃣", "🏳️‍🌈", "🏴\U000e0067\U000e0062\U000e0065\U000e006e\U000e0067\U000e007f"} {
		if got := Emoji(" " + value + " "); got != value {
			t.Errorf("Emoji(%q) = %q", value, got)
		}
		if !HasEmojiPrefix(value + " Backend") {
			t.Errorf("missed %q prefix", value)
		}
	}
	for _, value := range []string{"", "not emoji", "🔧🔧", "1", "🏽", "🇨", "👩‍", "👩‍A", "🔧\x00", "<script>", "\ufe0f"} {
		if got := Emoji(value); got != Fallback {
			t.Errorf("invalid Emoji(%q) = %q", value, got)
		}
	}
	if HasEmojiPrefix("Backend 🔧 tooling") {
		t.Fatal("emoji inside text is not a prefix")
	}
}
