// Package rapidcheck adds an explicit, witnessed replay to generated properties.
package rapidcheck

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"

	"pgregory.net/rapid"
)

// Check runs a requested counterexample independently, then retains Rapid's
// generated checks and automatic corpus. MakeFuzz reports exhausted/invalid
// input as a skip instead of silently falling back to random input.
func Check(t *testing.T, property func(*rapid.T)) {
	t.Helper()
	if path := os.Getenv("MOKUSEI_PBT_RAPID_REPLAY"); path != "" {
		completed := false
		passed := t.Run("explicit-replay", func(t *testing.T) {
			data, err := replayBytes(path)
			if err != nil {
				t.Skipf("PBT REPLAY INVALID: %v", err)
			}
			rapid.MakeFuzz(property)(t, data)
			completed = true
		})
		if !passed {
			return
		}
		if !completed {
			t.Skip("PBT REPLAY INVALID: explicit input did not complete")
		}
	}
	rapid.Check(t, property)
}

func replayBytes(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	header := false
	var data []byte
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !header {
			fields := strings.Split(line, "#")
			// Rapid v1.3.0 persist.go uses format v0.4.8. A library update
			// must review this adapter rather than accepting unknown formats.
			if len(fields) != 2 || fields[0] != "v0.4.8" {
				return nil, fmt.Errorf("unsupported Rapid version/seed header")
			}
			if _, err := strconv.ParseUint(fields[1], 10, 64); err != nil {
				return nil, fmt.Errorf("invalid Rapid seed: %w", err)
			}
			header = true
			continue
		}
		word, err := strconv.ParseUint(line, 0, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid Rapid word: %w", err)
		}
		data = binary.LittleEndian.AppendUint64(data, word)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if !header {
		return nil, fmt.Errorf("missing Rapid version/seed header")
	}
	return data, nil
}
