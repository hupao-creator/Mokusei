package claude

import (
	"encoding/json"
	"strings"
)

// displayJSON renders a value with JavaScript's JSON.stringify(value, null, 2)
// spelling; object keys keep Go's canonical order, which the native reader
// accepts. Native displays are validated against that spelling, while
// encoding/json additionally escapes HTML characters, U+2028 and U+2029, and
// spells U+0008/U+000C with \u escapes. Shell commands routinely contain &, <
// and >, so those escapes must not reach inputDisplay.
func displayJSON(value any) string {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return ""
	}
	var result strings.Builder
	result.Grow(len(encoded))
	for index := 0; index < len(encoded); index++ {
		if encoded[index] != '\\' || index+1 >= len(encoded) {
			result.WriteByte(encoded[index])
			continue
		}
		if encoded[index+1] != 'u' || index+5 >= len(encoded) {
			// Copy escape pairs whole so a literal backslash followed by
			// "u003e" is not rewritten as an HTML escape.
			result.WriteByte(encoded[index])
			result.WriteByte(encoded[index+1])
			index++
			continue
		}
		if replacement, ok := javaScriptEscapes[string(encoded[index+2:index+6])]; ok {
			result.WriteString(replacement)
			index += 5
			continue
		}
		result.WriteByte(encoded[index])
	}
	return result.String()
}

var javaScriptEscapes = map[string]string{
	"0008": `\b`,
	"000c": `\f`,
	"0026": "&",
	"003c": "<",
	"003e": ">",
	"2028": string(rune(0x2028)),
	"2029": string(rune(0x2029)),
}
