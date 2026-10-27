//go:build !darwin

package moku

import "context"

func readSystemClipboardText(context.Context, int) (clipboardText, error) {
	return clipboardText{}, errClipboardUnsupported
}
