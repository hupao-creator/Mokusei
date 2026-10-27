// Package taglabel handles semantic tag decoration independently of tag identity.
package taglabel

import (
	_ "embed"
	"strings"
)

const Fallback = "🏷️"

// emoji.txt contains the non-component sequences from Unicode Emoji 16.0:
// https://www.unicode.org/Public/emoji/16.0/emoji-test.txt
// Data © 2024 Unicode, Inc.; see UNICODE-LICENSE.txt.
// All qualification variants are accepted; isolated modifiers are not.
//
//go:embed emoji.txt
var emojiData string

var emojis = func() map[string]bool {
	result := map[string]bool{}
	for _, value := range strings.Fields(emojiData) {
		result[value] = true
	}
	return result
}()

// Emoji accepts exactly one complete Unicode emoji sequence. Failed generation
// must not prevent classification or turn arbitrary model output into a label.
func Emoji(value string) string {
	value = strings.TrimSpace(value)
	if ValidEmoji(value) {
		return value
	}
	return Fallback
}

// ValidEmoji checks the current data contract without repairing stored values.
func ValidEmoji(value string) bool { return emojis[value] }

// HasEmojiPrefix rejects decoration embedded in newly generated text identities.
func HasEmojiPrefix(value string) bool {
	value = strings.TrimSpace(value)
	for i := range value {
		if i > 128 {
			break
		}
		if i > 0 && emojis[value[:i]] {
			return true
		}
	}
	return emojis[value]
}
