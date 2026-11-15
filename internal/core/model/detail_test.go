package model

import (
	"math"
	"testing"
)

func TestDetailChunkTextBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name, text    string
		offset, limit int
		chunk         string
		next          int
		invalid       bool
	}{
		{"end", "abc", 3, 1024, "", 3, false},
		{"empty", "", 0, 1024, "", 0, false},
		{"unicode-end", "猫", 3, 1024, "", 3, false},
		{"split-offset", "猫", 1, 1024, "", 0, true},
		{"negative", "abc", -1, 1024, "", 0, true},
		{"past-end", "abc", 4, 1024, "", 0, true},
		{"zero-budget", "abc", 3, 0, "", 0, true},
		{"rune-budget", "猫a", 0, 1, "猫", 3, false},
		{"partial", "abc", 1, 1, "b", 2, false},
		{"overflow-budget", "abc", 1, math.MaxInt, "bc", 3, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			chunk, next, err := DetailChunkText(tc.text, tc.offset, tc.limit)
			if (err != nil) != tc.invalid || chunk != tc.chunk || next != tc.next {
				t.Fatalf("got %q, %d, %v; want %q, %d invalid=%v", chunk, next, err, tc.chunk, tc.next, tc.invalid)
			}
		})
	}
}
