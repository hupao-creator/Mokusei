package model

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	DetailBodyText     = "text"
	DetailBodyMarkdown = "markdown"
)

// DetailRequest selects stable reader detail identities within one execution.
// Items are opaque Harness-owned row identities; the shared layer never parses
// their native schema.
type DetailRequest struct {
	ExecutionID string
	Items       []string
}

// DetailProjection is the Harness-owned content for the selected identities.
// Bodies are values, not preformatted transport envelopes, so the shared layer
// owns chunk budgets and version cursors.
type DetailProjection struct {
	ExecutionID string
	Items       []DetailItem
}

type DetailItem struct {
	ID       string
	Kind     string
	Label    string
	Status   string
	ToolName string
	Bodies   []DetailBody
}

type DetailBody struct {
	Slot   string
	Label  string
	Format string
	// Length may be zero when a Harness defers expensive body formatting to the
	// exact read. The first body page always names the authoritative length.
	Length int
	// Text is populated only for an exact body read. Directory projections set
	// Length without materializing the body into the transport value.
	Text string
}

type DetailBodyRequest struct {
	ExecutionID string
	ItemID      string
	Slot        string
}

// DetailDirectory is the bounded metadata page for selected reader rows.
// Body text is intentionally absent; each descriptor can be read independently.
type DetailDirectory struct {
	Kind        string                `json:"kind"`
	ExecutionID string                `json:"executionId"`
	ContentID   string                `json:"contentId"`
	Truncated   bool                  `json:"truncated,omitempty"`
	Items       []DetailDirectoryItem `json:"items"`
}

type DetailDirectoryItem struct {
	ID       string                 `json:"id"`
	Kind     string                 `json:"kind"`
	Label    string                 `json:"label,omitempty"`
	Status   string                 `json:"status,omitempty"`
	ToolName string                 `json:"toolName,omitempty"`
	Bodies   []DetailBodyDescriptor `json:"bodies,omitempty"`
}

type DetailBodyDescriptor struct {
	Slot   string `json:"slot"`
	Label  string `json:"label,omitempty"`
	Format string `json:"format"`
	Length int    `json:"length"`
}

// DetailChunk carries one bounded page of a single body. Offset and Length are
// UTF-8 byte positions into the exact version named by the cursor.
type DetailChunk struct {
	Kind        string `json:"kind"`
	ExecutionID string `json:"executionId"`
	ItemID      string `json:"itemId"`
	Slot        string `json:"slot"`
	Version     string `json:"version"`
	Offset      int    `json:"offset"`
	Length      int    `json:"length"`
	Text        string `json:"text"`
	Next        string `json:"next,omitempty"`
}

// DetailBodyVersion binds a cursor to the execution, item, slot and exact body
// bytes. Including identity prevents an equal body from satisfying another call.
func DetailBodyVersion(executionID, itemID, slot, text string) string {
	digest := sha256.New()
	for _, value := range []string{executionID, itemID, slot, text} {
		_, _ = fmt.Fprintf(digest, "%d:", len(value))
		_, _ = digest.Write([]byte(value))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func EncodeDetailCursor(version string, offset int) string {
	return "d1:" + version + ":" + strconv.Itoa(offset)
}

func DecodeDetailCursor(cursor string) (version string, offset int, ok bool) {
	if !strings.HasPrefix(cursor, "d1:") {
		return "", 0, false
	}
	rest := strings.TrimPrefix(cursor, "d1:")
	version, rawOffset, found := strings.Cut(rest, ":")
	if !found || len(version) != sha256.Size*2 || strings.ContainsAny(rawOffset, "+-") {
		return "", 0, false
	}
	if _, err := hex.DecodeString(version); err != nil {
		return "", 0, false
	}
	value, err := strconv.Atoi(rawOffset)
	if err != nil || value < 0 || strconv.Itoa(value) != rawOffset {
		return "", 0, false
	}
	return version, value, true
}

// DetailChunkText returns a bounded prefix without splitting a UTF-8 rune.
// Callers validate the complete body once when they build its version; pages do
// not rescan multi-megabyte text for validity.
func DetailChunkText(text string, offset, limit int) (chunk string, next int, err error) {
	if offset < 0 || offset > len(text) {
		return "", 0, fmt.Errorf("detail body offset is out of range")
	}
	if limit <= 0 {
		return "", 0, fmt.Errorf("detail body chunk budget must be positive")
	}
	if offset == len(text) {
		return "", offset, nil
	}
	if offset > 0 && !utf8.RuneStart(text[offset]) {
		return "", 0, fmt.Errorf("detail body offset splits a UTF-8 rune")
	}
	if limit >= len(text)-offset {
		return text[offset:], len(text), nil
	}
	next = offset + limit
	for next > offset && !utf8.RuneStart(text[next]) {
		next--
	}
	if next == offset {
		// A single rune exceeds the budget. Return it whole rather than an empty
		// page that can never advance.
		_, size := utf8.DecodeRuneInString(text[offset:])
		next = offset + size
	}
	return text[offset:next], next, nil
}
