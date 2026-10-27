package opencode

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
)

type rendererRecord struct {
	value  Object
	fields map[string]json.RawMessage
}
type rendererSource struct {
	fields  map[string]json.RawMessage
	records map[string]map[string]rendererRecord
}

func newRendererSource(raw json.RawMessage) rendererSource {
	source := rendererSource{fields: make(map[string]json.RawMessage), records: make(map[string]map[string]rendererRecord)}
	_ = json.Unmarshal(raw, &source.fields)
	for _, collection := range []string{"messages", "executions", "interactions", "auxiliaryUsage"} {
		source.records[collection] = make(map[string]rendererRecord)
		var items []json.RawMessage
		_ = json.Unmarshal(source.fields[collection], &items)
		for _, item := range items {
			record := rendererRecord{}
			_ = json.Unmarshal(item, &record.value)
			_ = json.Unmarshal(item, &record.fields)
			key := str(record.value["id"])
			if collection == "executions" {
				key = str(record.value["executionId"])
			}
			if collection == "interactions" || collection == "auxiliaryUsage" {
				key = str(record.value["executionId"]) + "\x00" + key
			}
			source.records[collection][key] = record
		}
	}
	return source
}
func (source rendererSource) has(key string) bool { _, exists := source.fields[key]; return exists }
func (source rendererSource) field(collection, id, field string) json.RawMessage {
	return source.records[collection][id].fields[field]
}
func (source rendererSource) object(collection, id string, fallback any) Object {
	if record, exists := source.records[collection][id]; exists {
		return clone(record.value)
	}
	return rendererObject(fallback)
}
func (source rendererSource) messageHas(message *Message, field string) bool {
	if record, exists := source.records["messages"][message.ID]; exists {
		_, present := record.fields[field]
		return present
	}
	return field == "todos" && message.Todos != nil
}

// JS previews slice UTF-16 units. Preserve a boundary's lone high surrogate in
// the JSON wire representation rather than silently replacing it with U+FFFD.
func rendererClip(text string, limit int) any {
	var result strings.Builder
	units := 0
	for _, point := range text {
		width := 1
		if point > 0xffff {
			width = 2
		}
		if units+width > limit {
			if units < limit {
				prefix := rendererQuote(result.String())
				high, _ := utf16.EncodeRune(point)
				return json.RawMessage(prefix[:len(prefix)-1] + fmt.Sprintf(`\u%04x"`, high))
			}
			break
		}
		result.WriteRune(point)
		units += width
		if units == limit {
			break
		}
	}
	return result.String()
}

type rendererPair struct {
	key   string
	value any
}
type rendererOrdered []rendererPair

func rendererToolDisplay(raw json.RawMessage, fallback any) string {
	if raw == nil {
		raw, _ = json.Marshal(fallback)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	value, err := rendererDecodeOrdered(decoder)
	if err != nil {
		return display(fallback)
	}
	if text, ok := value.(string); ok {
		return text
	}
	return rendererPretty(value, 0)
}

func rendererDecodeOrdered(decoder *json.Decoder) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return token, nil
	}
	if delimiter == '[' {
		values := make([]any, 0)
		for decoder.More() {
			value, err := rendererDecodeOrdered(decoder)
			if err != nil {
				return nil, err
			}
			values = append(values, value)
		}
		_, err = decoder.Token()
		return values, err
	}
	if delimiter != '{' {
		return nil, io.ErrUnexpectedEOF
	}
	pairs := make(rendererOrdered, 0)
	indices := make(map[string]int)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		key, ok := token.(string)
		if !ok {
			return nil, io.ErrUnexpectedEOF
		}
		value, err := rendererDecodeOrdered(decoder)
		if err != nil {
			return nil, err
		}
		if index, exists := indices[key]; exists {
			pairs[index].value = value
		} else {
			indices[key] = len(pairs)
			pairs = append(pairs, rendererPair{key, value})
		}
	}
	if _, err = decoder.Token(); err != nil {
		return nil, err
	}
	// JSON.stringify enumerates canonical array-index keys before other keys.
	indexKey := func(key string) (uint64, bool) {
		value, err := strconv.ParseUint(key, 10, 32)
		return value, err == nil && value < 4294967295 && strconv.FormatUint(value, 10) == key
	}
	sort.SliceStable(pairs, func(i, j int) bool {
		a, aok := indexKey(pairs[i].key)
		b, bok := indexKey(pairs[j].key)
		if aok && bok {
			return a < b
		}
		return aok && !bok
	})
	return pairs, nil
}
func rendererPretty(value any, level int) string {
	pad := strings.Repeat("  ", level)
	next := pad + "  "
	switch typed := value.(type) {
	case rendererOrdered:
		if len(typed) == 0 {
			return "{}"
		}
		items := make([]string, 0, len(typed))
		for _, pair := range typed {
			items = append(items, next+rendererQuote(pair.key)+": "+rendererPretty(pair.value, level+1))
		}
		return "{\n" + strings.Join(items, ",\n") + "\n" + pad + "}"
	case []any:
		if len(typed) == 0 {
			return "[]"
		}
		items := make([]string, 0, len(typed))
		for _, item := range typed {
			items = append(items, next+rendererPretty(item, level+1))
		}
		return "[\n" + strings.Join(items, ",\n") + "\n" + pad + "]"
	case string:
		return rendererQuote(typed)
	case float64:
		if typed == 0 {
			return "0"
		}
		encoded, _ := json.Marshal(typed)
		return string(encoded)
	default:
		encoded, _ := json.Marshal(typed)
		return string(encoded)
	}
}
func rendererQuote(text string) string {
	var result strings.Builder
	result.WriteByte('"')
	for _, point := range text {
		switch point {
		case '"', '\\':
			result.WriteByte('\\')
			result.WriteRune(point)
		case '\b':
			result.WriteString(`\b`)
		case '\f':
			result.WriteString(`\f`)
		case '\n':
			result.WriteString(`\n`)
		case '\r':
			result.WriteString(`\r`)
		case '\t':
			result.WriteString(`\t`)
		default:
			if point < 0x20 {
				fmt.Fprintf(&result, `\u%04x`, point)
			} else {
				result.WriteRune(point)
			}
		}
	}
	result.WriteByte('"')
	return result.String()
}
