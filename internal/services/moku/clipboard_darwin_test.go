//go:build darwin

package moku

import (
	"context"
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// Exercise the real JXA/AppKit bridge with synthetic NSData, never the user's
// clipboard. Override only the script's entry point, retaining readPlainText.
func TestClipboardDarwinBridge(t *testing.T) {
	for _, tc := range []struct {
		name, fixture, want string
		max                 int
		truncated, failure  bool
	}{
		{"plain", `$('中文🙂').dataUsingEncoding($.NSUTF8StringEncoding)`, "中文🙂", 10, false, false},
		{"empty", `$('').dataUsingEncoding($.NSUTF8StringEncoding)`, "", 4, false, false},
		{"bounded", `$('中文🙂').dataUsingEncoding($.NSUTF8StringEncoding)`, "中", 3, true, false},
		{"nil-data", `null`, "", 4, false, true},
		{"objc-nil", `$.NSData.alloc.initWithBase64EncodedStringOptions($('!'), 0)`, "", 4, false, true},
		{"invalid-object", `$.NSNull.alloc.init`, "", 4, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), clipboardTimeout)
			defer cancel()
			// Reject any request for a type other than UTF-8 plain text. This
			// also guards against adding implicit rich-text/file fallbacks.
			fixture := `
function run(argv) {
    readPlainText({dataForType: function(type) {
        if (type !== 'public.utf8-plain-text') throw new Error('wrong type');
        return ` + tc.fixture + `;
    }}, ` + strconv.Itoa(tc.max) + `);
}`
			command := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-")
			command.Stdin = strings.NewReader(clipboardScript + fixture)
			value, err := runClipboardCommand(ctx, command, tc.max)
			if tc.failure {
				if !errors.Is(err, errClipboardIndeterminate) {
					t.Fatalf("indeterminate = %v", err)
				}
			} else if err != nil || string(value.data) != tc.want || value.truncated != tc.truncated {
				t.Fatalf("result = %q, clipped = %t, err = %v", value.data, value.truncated, err)
			}
		})
	}
}
