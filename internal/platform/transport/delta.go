package transport

import (
	"reflect"
	"sort"
	"unicode/utf8"
)

// CreateJSONDelta uses the public protocol's object/array operations. Text
// offsets count UTF-16 code units; patch boundaries never split a surrogate pair
// so Go's UTF-8 representation can preserve the inserted text losslessly.
func CreateJSONDelta(previous, next any) []map[string]any {
	operations := make([]map[string]any, 0)
	var diff func(any, any, []any)
	diff = func(before, after any, path []any) {
		if reflect.DeepEqual(before, after) {
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
					operations = append(operations, map[string]any{"op": "text", "path": path, "index": startUnits, "deleteCount": utf16Length(left) - startUnits - endUnits, "text": right[start:rightEnd]})
				} else {
					operations = append(operations, map[string]any{"op": "replace", "path": path, "value": after})
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
				for offset := 0; offset < overlap; offset++ {
					diff(left[start+offset], right[start+offset], appendPath(path, start+offset))
				}
				if leftEnd-start != rightEnd-start {
					values := right[start+overlap : rightEnd]
					if values == nil {
						values = []any{}
					}
					operations = append(operations, map[string]any{"op": "splice", "path": path, "index": start + overlap, "deleteCount": leftEnd - start - overlap, "values": values})
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
						operations = append(operations, map[string]any{"op": "remove", "path": appendPath(path, key)})
					}
				}
				rightKeys := make([]string, 0, len(right))
				for key := range right {
					rightKeys = append(rightKeys, key)
				}
				sort.Strings(rightKeys)
				for _, key := range rightKeys {
					if value, exists := left[key]; exists {
						diff(value, right[key], appendPath(path, key))
					} else {
						operations = append(operations, map[string]any{"op": "add", "path": appendPath(path, key), "value": right[key]})
					}
				}
				return
			}
		}
		operations = append(operations, map[string]any{"op": "replace", "path": path, "value": after})
	}
	diff(previous, next, []any{})
	return operations
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
