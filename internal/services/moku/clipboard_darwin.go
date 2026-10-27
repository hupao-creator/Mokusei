//go:build darwin

package moku

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
)

// pbpaste -Prefer txt still falls back to RTF/EPS (see man pbpaste, BUGS).
// Use the system JXA/AppKit bridge to request only public.utf8-plain-text.
// A nil result is ambiguous, including permission denial; never retry it.
const clipboardScript = `ObjC.import('AppKit');
function readPlainText(pasteboard, maxBytes) {
    var data = pasteboard.dataForType('public.utf8-plain-text');
    if (!data || data.isNil()) throw new Error('clipboard access indeterminate');
    var length = Number(data.length);
    var output = $.NSFileHandle.fileHandleWithStandardOutput;
    var flag = length > maxBytes ? '1' : '0';
    output.writeData($(flag).dataUsingEncoding($.NSUTF8StringEncoding));
    output.writeData(data.subdataWithRange($.NSMakeRange(0, Math.min(length, maxBytes))));
}
function run(argv) {
    readPlainText($.NSPasteboard.generalPasteboard, Number(argv[0]));
}`

func readSystemClipboardText(ctx context.Context, maxBytes int) (clipboardText, error) {
	command := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-", strconv.Itoa(maxBytes))
	command.Stdin = strings.NewReader(clipboardScript)
	return runClipboardCommand(ctx, command, maxBytes)
}
