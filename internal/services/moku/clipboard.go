package moku

import (
	"context"
	"errors"
	"os/exec"
	"time"
	"unicode/utf8"
)

const (
	clipboardDefaultCharacters = 4000
	clipboardMaxCharacters     = 20000
	clipboardTimeout           = 2 * time.Second
)

var (
	errClipboardIndeterminate = errors.New("clipboard access indeterminate: cannot distinguish unavailable plain text, empty clipboard, or denied permission; do not retry automatically")
	errClipboardUnsupported   = errors.New("read_clipboard is unsupported on this platform (requires macOS)")
)

type clipboardText struct {
	data      []byte
	truncated bool
}

// A reader returns at most maxBytes bytes of UTF-8 plain text. It must honor
// cancellation and report ambiguous access as errClipboardIndeterminate.
// Injection belongs to one Coordinator, avoiding shared mutable test globals.
type clipboardReader func(ctx context.Context, maxBytes int) (clipboardText, error)

type clipboardResult struct {
	OK         bool   `json:"ok"`
	Text       string `json:"text"`
	Empty      bool   `json:"empty"`
	Truncated  bool   `json:"truncated"`
	Characters int    `json:"characters"`
}

func readClipboard(ctx context.Context, maxCharacters int, reader clipboardReader) (clipboardResult, error) {
	ctx, cancel := context.WithTimeout(ctx, clipboardTimeout)
	defer cancel()
	value, err := reader(ctx, maxCharacters*utf8.UTFMax)
	if ctx.Err() != nil {
		return clipboardResult{}, ctx.Err()
	}
	if err != nil {
		// Do not propagate process stderr or reader errors that may contain text.
		for _, safe := range []error{errClipboardIndeterminate, errClipboardUnsupported, context.Canceled, context.DeadlineExceeded} {
			if errors.Is(err, safe) {
				return clipboardResult{}, safe
			}
		}
		return clipboardResult{}, errors.New("clipboard plain-text read failed")
	}
	end, characters := 0, 0
	for end < len(value.data) && characters < maxCharacters {
		// A bounded byte prefix may end inside a code point. Drop only that
		// incomplete suffix; malformed UTF-8 elsewhere is never rewritten.
		if value.truncated && !utf8.FullRune(value.data[end:]) {
			break
		}
		r, size := utf8.DecodeRune(value.data[end:])
		if r == utf8.RuneError && size == 1 {
			return clipboardResult{}, errors.New("clipboard plain text is not valid UTF-8")
		}
		end += size
		characters++
	}
	return clipboardResult{OK: true, Text: string(value.data[:end]), Empty: len(value.data) == 0,
		Truncated: value.truncated || end < len(value.data), Characters: characters}, nil
}

// The subprocess emits one ASCII truncation flag followed by at most maxBytes
// raw UTF-8 bytes. The writer bounds retained output even if the helper is faulty.
func runClipboardCommand(ctx context.Context, command *exec.Cmd, maxBytes int) (clipboardText, error) {
	output := clipboardOutput{limit: maxBytes + 1}
	command.Stdout = &output
	// A nil Stderr discards diagnostics instead of buffering sensitive data.
	command.WaitDelay = 100 * time.Millisecond
	if err := command.Run(); err != nil {
		if ctx.Err() != nil {
			return clipboardText{}, ctx.Err()
		}
		return clipboardText{}, errClipboardIndeterminate
	}
	if len(output.data) == 0 || (output.data[0] != '0' && output.data[0] != '1') {
		return clipboardText{}, errClipboardIndeterminate
	}
	return clipboardText{data: output.data[1:], truncated: output.data[0] == '1'}, nil
}

type clipboardOutput struct {
	data  []byte
	limit int
}

func (w *clipboardOutput) Write(p []byte) (int, error) {
	n := min(len(p), w.limit-len(w.data))
	w.data = append(w.data, p[:n]...)
	if n != len(p) {
		return n, errors.New("clipboard helper output exceeds byte limit")
	}
	return n, nil
}
