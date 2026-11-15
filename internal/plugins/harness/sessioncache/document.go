// Package sessioncache owns bounded, concurrency-safe reader projections shared
// by the Harness adapters. It never interprets Harness-specific session state;
// each adapter supplies its own index and projection function.
package sessioncache

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
)

// Document is a shallow JSON object view. Field values are spans of the original
// bytes, so a caller that retains a Document must keep the source immutable.
// Splitting an object or array does not copy value bodies.
type Document struct {
	Fields map[string]json.RawMessage
}

// ParseDocument splits one JSON object without decoding its values. A null or
// empty state becomes an empty document; adapters treat that as their zero state.
func ParseDocument(raw json.RawMessage) (*Document, error) {
	return ParseDocumentContext(context.Background(), raw)
}

// ParseDocumentContext splits one object while observing cancellation during
// field and nested-value scans.
func ParseDocumentContext(ctx context.Context, raw json.RawMessage) (*Document, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	fields := map[string]json.RawMessage{}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return &Document{Fields: fields}, nil
	}
	if trimmed[0] != '{' {
		return nil, errors.New("session state is not a JSON object")
	}
	index := 1
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		index = skipSpace(trimmed, index)
		if index >= len(trimmed) {
			return nil, errors.New("unterminated session object")
		}
		if trimmed[index] == '}' {
			index++
			break
		}
		keyStart := index
		end, err := skipStringContext(ctx, trimmed, index)
		if err != nil {
			return nil, err
		}
		var key string
		if err := json.Unmarshal(trimmed[keyStart:end], &key); err != nil {
			return nil, err
		}
		index = skipSpace(trimmed, end)
		if index >= len(trimmed) || trimmed[index] != ':' {
			return nil, errors.New("session object field has no value")
		}
		index = skipSpace(trimmed, index+1)
		valueStart := index
		valueEnd, err := skipValueContext(ctx, trimmed, index)
		if err != nil {
			return nil, err
		}
		fields[key] = trimmed[valueStart:valueEnd]
		index = skipSpace(trimmed, valueEnd)
		if index >= len(trimmed) {
			return nil, errors.New("unterminated session object")
		}
		if trimmed[index] == ',' {
			index++
			continue
		}
		if trimmed[index] == '}' {
			index++
			break
		}
		return nil, errors.New("invalid session object separator")
	}
	if skipSpace(trimmed, index) != len(trimmed) {
		return nil, errors.New("trailing session object data")
	}
	return &Document{Fields: fields}, nil
}

func (d *Document) Field(name string) (json.RawMessage, bool) {
	if d == nil {
		return nil, false
	}
	value, ok := d.Fields[name]
	return value, ok
}

// Array splits only the immediate array elements. Elements remain spans of the
// source bytes; no unrelated body is decoded into an interface value.
func (d *Document) Array(name string) ([]json.RawMessage, error) {
	return d.ArrayContext(context.Background(), name)
}

func (d *Document) ArrayContext(ctx context.Context, name string) ([]json.RawMessage, error) {
	value, ok := d.Field(name)
	if !ok {
		return nil, nil
	}
	trimmed := bytes.TrimSpace(value)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, nil
	}
	if trimmed[0] != '[' {
		return nil, fmt.Errorf("session field %q is not an array", name)
	}
	items := []json.RawMessage{}
	index := 1
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		index = skipSpace(trimmed, index)
		if index >= len(trimmed) {
			return nil, fmt.Errorf("unterminated session array %q", name)
		}
		if trimmed[index] == ']' {
			index++
			break
		}
		start := index
		end, err := skipValueContext(ctx, trimmed, index)
		if err != nil {
			return nil, err
		}
		items = append(items, trimmed[start:end])
		index = skipSpace(trimmed, end)
		if index >= len(trimmed) {
			return nil, fmt.Errorf("unterminated session array %q", name)
		}
		if trimmed[index] == ',' {
			index++
			continue
		}
		if trimmed[index] == ']' {
			index++
			break
		}
		return nil, fmt.Errorf("invalid session array separator %q", name)
	}
	if skipSpace(trimmed, index) != len(trimmed) {
		return nil, fmt.Errorf("trailing session array data %q", name)
	}
	return items, nil
}

// Encode assembles a partial object from borrowed field bytes.
func Encode(fields map[string]json.RawMessage) (json.RawMessage, error) {
	value, err := json.Marshal(fields)
	if err != nil {
		return nil, err
	}
	return value, nil
}

func EncodeArray(items []json.RawMessage) (json.RawMessage, error) {
	if items == nil {
		items = []json.RawMessage{}
	}
	return json.Marshal(items)
}

func EncodeObject(fields map[string]json.RawMessage) (json.RawMessage, error) {
	if fields == nil {
		fields = map[string]json.RawMessage{}
	}
	return json.Marshal(fields)
}

func skipSpace(value []byte, index int) int {
	for index < len(value) {
		switch value[index] {
		case ' ', '\t', '\n', '\r':
			index++
		default:
			return index
		}
	}
	return index
}

func skipStringContext(ctx context.Context, value []byte, index int) (int, error) {
	if index >= len(value) || value[index] != '"' {
		return 0, errors.New("expected JSON string")
	}
	index++
	for index < len(value) {
		if index&0xfff == 0 {
			if err := ctx.Err(); err != nil {
				return 0, err
			}
		}
		switch value[index] {
		case '\\':
			index += 2
		case '"':
			return index + 1, nil
		default:
			index++
		}
	}
	return 0, errors.New("unterminated JSON string")
}

func skipValueContext(ctx context.Context, value []byte, index int) (int, error) {
	if index >= len(value) {
		return 0, errors.New("missing JSON value")
	}
	switch value[index] {
	case '"':
		return skipStringContext(ctx, value, index)
	case '{', '[':
		open := value[index]
		close := byte('}')
		if open == '[' {
			close = ']'
		}
		depth := 0
		for index < len(value) {
			if index&0xfff == 0 {
				if err := ctx.Err(); err != nil {
					return 0, err
				}
			}
			switch value[index] {
			case '"':
				end, err := skipStringContext(ctx, value, index)
				if err != nil {
					return 0, err
				}
				index = end
				continue
			case open:
				depth++
			case close:
				depth--
				if depth == 0 {
					return index + 1, nil
				}
			}
			index++
		}
		return 0, errors.New("unterminated JSON container")
	case 't':
		if bytes.HasPrefix(value[index:], []byte("true")) {
			return index + 4, nil
		}
	case 'f':
		if bytes.HasPrefix(value[index:], []byte("false")) {
			return index + 5, nil
		}
	case 'n':
		if bytes.HasPrefix(value[index:], []byte("null")) {
			return index + 4, nil
		}
	default:
		start := index
		for index < len(value) {
			if index&0xfff == 0 {
				if err := ctx.Err(); err != nil {
					return 0, err
				}
			}
			switch value[index] {
			case ' ', '\t', '\n', '\r', ',', '}', ']':
				if index == start {
					return 0, errors.New("missing JSON value")
				}
				return index, nil
			}
			index++
		}
		return index, nil
	}
	return 0, errors.New("invalid JSON value")
}

var ErrClosed = errors.New("session cache is closed")
