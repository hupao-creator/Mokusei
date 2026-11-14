package transport

import (
	"encoding/json"
	"reflect"
	"sort"
	"unicode/utf8"
)

// maxDeltaOperations bounds diff work even when the encoded patch would still
// fit the wire limit. Above this size a complete snapshot is cheaper to build,
// apply and validate than thousands of small operations.
const maxDeltaOperations = 4096

// DeltaBudget bounds patch construction. MaxBytes counts the encoded operations
// array, including brackets and separators, but not the event envelope; callers
// compare complete encoded events before choosing a representation. A zero
// value allows no operations.
type DeltaBudget struct {
	MaxOperations int
	MaxBytes      int
}

// Delta is either a complete patch or an explicit failure to finish within its
// budget. Incomplete deltas contain no partial operations and must be replaced
// by a snapshot. Examined counts candidate operations inspected before
// completion or the first rejected operation, so tests can verify that dense
// inputs stop diff construction instead of building an unusable patch first.
type Delta struct {
	Operations []map[string]any
	Bytes      int
	Examined   int
	Complete   bool
}

// CreateJSONDelta returns a complete patch within the production operation and
// frame budgets, or nil when the values require a snapshot. Callers that need
// to distinguish an incomplete diff should use CreateBoundedJSONDelta.
func CreateJSONDelta(previous, next any) []map[string]any {
	return CreateBoundedJSONDelta(previous, next, DeltaBudget{MaxOperations: maxDeltaOperations, MaxBytes: contentWriteLimit}).Operations
}

// CreateBoundedJSONDelta stops before an operation would exceed either budget.
// It returns no partial operations when incomplete so callers must fall back to
// a complete snapshot rather than trying to salvage a prefix.
func CreateBoundedJSONDelta(previous, next any, budget DeltaBudget) Delta {
	builder := deltaBuilder{maxOperations: max(0, budget.MaxOperations), maxBytes: max(0, budget.MaxBytes), bytes: 2}
	builder.diff(previous, next, []any{})
	if builder.stopped {
		return Delta{Bytes: builder.bytes, Examined: builder.examined}
	}
	return Delta{Operations: builder.operations, Bytes: builder.bytes, Examined: builder.examined, Complete: true}
}

// deltaBuilder emits the public protocol's object/array operations. Text
// offsets count UTF-16 code units; patch boundaries never split a surrogate pair
// so Go's UTF-8 representation can preserve the inserted text losslessly.
type deltaBuilder struct {
	operations    []map[string]any
	bytes         int
	examined      int
	maxOperations int
	maxBytes      int
	stopped       bool
}

func (b *deltaBuilder) add(operation map[string]any) bool {
	if b.stopped {
		return false
	}
	b.examined++
	if len(b.operations) >= b.maxOperations {
		b.stopped = true
		return false
	}
	encoded, err := json.Marshal(operation)
	if err != nil {
		b.stopped = true
		return false
	}
	size := len(encoded)
	if len(b.operations) > 0 {
		size++
	}
	if b.bytes+size > b.maxBytes {
		b.stopped = true
		return false
	}
	b.operations = append(b.operations, operation)
	b.bytes += size
	return true
}
func (b *deltaBuilder) diff(before, after any, path []any) {
	if b.stopped || reflect.DeepEqual(before, after) {
		return
	}
	if left, ok := before.(string); ok {
		if right, ok := after.(string); ok {
			start := 0
			startUnits := 0
			for start < len(left) && start < len(right) {
				lr, ls := utf8.DecodeRuneInString(left[start:])
				rr, rs := utf8.DecodeRuneInString(right[start:])
				if lr != rr || ls != rs {
					break
				}
				start += ls
				startUnits += runeUnits(lr)
			}
			leftEnd := len(left)
			rightEnd := len(right)
			endUnits := 0
			for leftEnd > start && rightEnd > start {
				lr, ls := utf8.DecodeLastRuneInString(left[:leftEnd])
				rr, rs := utf8.DecodeLastRuneInString(right[:rightEnd])
				if lr != rr || ls != rs {
					break
				}
				leftEnd -= ls
				rightEnd -= rs
				endUnits += runeUnits(lr)
			}
			if start > 0 || endUnits > 0 {
				b.add(map[string]any{"op": "text", "path": path, "index": startUnits, "deleteCount": utf16Length(left) - startUnits - endUnits, "text": right[start:rightEnd]})
			} else {
				b.add(map[string]any{"op": "replace", "path": path, "value": after})
			}
			return
		}
	}
	if left, ok := before.([]any); ok {
		if right, ok := after.([]any); ok {
			start := 0
			for start < len(left) && start < len(right) && reflect.DeepEqual(left[start], right[start]) {
				start++
			}
			leftEnd := len(left)
			rightEnd := len(right)
			for leftEnd > start && rightEnd > start && reflect.DeepEqual(left[leftEnd-1], right[rightEnd-1]) {
				leftEnd--
				rightEnd--
			}
			overlap := min(leftEnd-start, rightEnd-start)
			for offset := 0; offset < overlap && !b.stopped; offset++ {
				b.diff(left[start+offset], right[start+offset], appendPath(path, start+offset))
			}
			if b.stopped {
				return
			}
			if leftEnd-start != rightEnd-start {
				values := right[start+overlap : rightEnd]
				if values == nil {
					values = []any{}
				}
				b.add(map[string]any{"op": "splice", "path": path, "index": start + overlap, "deleteCount": leftEnd - start - overlap, "values": values})
			}
			return
		}
	}
	if left, ok := before.(map[string]any); ok {
		if right, ok := after.(map[string]any); ok {
			leftKeys := make([]string, 0, len(left))
			for key := range left {
				leftKeys = append(leftKeys, key)
			}
			sort.Strings(leftKeys)
			for _, key := range leftKeys {
				if _, exists := right[key]; !exists {
					if !b.add(map[string]any{"op": "remove", "path": appendPath(path, key)}) {
						return
					}
				}
			}
			rightKeys := make([]string, 0, len(right))
			for key := range right {
				rightKeys = append(rightKeys, key)
			}
			sort.Strings(rightKeys)
			for _, key := range rightKeys {
				if value, exists := left[key]; exists {
					b.diff(value, right[key], appendPath(path, key))
					if b.stopped {
						return
					}
				} else if !b.add(map[string]any{"op": "add", "path": appendPath(path, key), "value": right[key]}) {
					return
				}
			}
			return
		}
	}
	b.add(map[string]any{"op": "replace", "path": path, "value": after})
}
func appendPath(path []any, value any) []any {
	next := make([]any, len(path)+1)
	copy(next, path)
	next[len(path)] = value
	return next
}
func runeUnits(value rune) int {
	if value > 0xffff {
		return 2
	}
	return 1
}
func utf16Length(value string) int {
	length := 0
	for _, r := range value {
		length += runeUnits(r)
	}
	return length
}
