package background

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type ToolHandler func(context.Context, model.Object, string) (any, error)

func UUID() string {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		panic(err)
	}
	data[6] = (data[6] & 15) | 64
	data[8] = (data[8] & 63) | 128
	return hex.EncodeToString(data[:4]) + "-" + hex.EncodeToString(data[4:6]) + "-" + hex.EncodeToString(data[6:8]) + "-" + hex.EncodeToString(data[8:10]) + "-" + hex.EncodeToString(data[10:])
}
func String(args model.Object, key string) (string, error) {
	value, ok := args[key].(string)
	if !ok || strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("Missing %s", key)
	}
	return value, nil
}
func Integer(args model.Object, key string, fallback int) (int, error) {
	value, ok := args[key]
	if !ok {
		return fallback, nil
	}
	number, ok := value.(json.Number)
	if !ok {
		return 0, fmt.Errorf("Invalid %s", key)
	}
	n, err := strconv.ParseInt(string(number), 10, 64)
	if err != nil || n < 0 || n > 9007199254740991 {
		return 0, fmt.Errorf("Invalid %s", key)
	}
	return int(n), nil
}
func Tool(lifetime context.Context, name, description string, properties model.Object, required []string, run ToolHandler) plugin.ToolBinding {
	if required == nil {
		required = []string{}
	}
	schema, _ := json.Marshal(model.Object{"type": "object", "properties": properties, "required": required, "additionalProperties": false})
	return plugin.ToolBinding{Name: name, Description: description, InputSchema: schema, Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		ctx, cancel := context.WithCancel(ctx)
		stop := context.AfterFunc(lifetime, cancel)
		defer func() { stop(); cancel() }()
		if err := lifetime.Err(); err != nil {
			return nil, err
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		args, err := model.DecodeObject(call.Arguments)
		if err != nil {
			return nil, err
		}
		for key := range args {
			if _, ok := properties[key]; !ok {
				return nil, fmt.Errorf("Invalid arguments for %s", name)
			}
		}
		for _, key := range required {
			if _, ok := args[key]; !ok {
				return nil, fmt.Errorf("Invalid arguments for %s", name)
			}
		}
		result, err := run(ctx, args, call.CallID)
		if err != nil {
			return nil, err
		}
		if err = ctx.Err(); err != nil {
			return nil, err
		}
		return json.Marshal(result)
	}}
}

type pageEntry struct {
	key   string
	text  []uint16
	ready chan struct{}
	err   error
}
type snapshots struct {
	mu         sync.Mutex
	entries    map[string]*pageEntry
	order      []string
	characters int
}

func JSONPage(lifetime context.Context, name, description string, properties model.Object, required []string, load ToolHandler) plugin.ToolBinding {
	cache := &snapshots{entries: map[string]*pageEntry{}}
	context.AfterFunc(lifetime, func() {
		cache.mu.Lock()
		defer cache.mu.Unlock()
		cache.entries = map[string]*pageEntry{}
		cache.order = nil
		cache.characters = 0
	})
	props := model.Object{}
	for k, v := range properties {
		props[k] = v
	}
	props["offset"] = model.Object{"type": "integer", "minimum": 0}
	props["limit"] = model.Object{"type": "integer", "minimum": 1, "maximum": 64000}
	return Tool(lifetime, name, description+" Start at offset 0 to capture or refresh a snapshot, then follow nextOffset. If a snapshot expires, restart at offset 0.", props, required, func(ctx context.Context, args model.Object, callID string) (any, error) {
		offset, err := Integer(args, "offset", 0)
		if err != nil {
			return nil, err
		}
		limit, err := Integer(args, "limit", 24000)
		if err != nil || limit < 1 || limit > 64000 {
			return nil, errors.New("Invalid limit")
		}
		query := model.Object{}
		for key, value := range args {
			if key != "offset" && key != "limit" {
				query[key] = value
			}
		}
		encoded, err := json.Marshal(query)
		if err != nil {
			return nil, err
		}
		key := string(encoded)
		cache.mu.Lock()
		entry := cache.entries[key]
		fresh := offset == 0
		if fresh {
			cache.remove(key)
			entry = &pageEntry{key: key, ready: make(chan struct{})}
			cache.entries[key] = entry
			cache.touch(key)
			cache.trim()
		} else if entry != nil {
			cache.touch(key)
		}
		cache.mu.Unlock()
		if entry == nil {
			return nil, errors.New("Background evidence snapshot expired or unavailable; restart at offset 0")
		}
		if fresh {
			value, loadErr := load(ctx, query, callID)
			var text string
			if loadErr == nil {
				data, encodeErr := json.Marshal(value)
				loadErr = encodeErr
				text = string(data)
			}
			if loadErr == nil {
				loadErr = ctx.Err()
			}
			if loadErr == nil {
				loadErr = lifetime.Err()
			}
			cache.mu.Lock()
			entry.err = loadErr
			if loadErr == nil {
				entry.text = utf16.Encode([]rune(text))
			}
			if cache.entries[key] == entry {
				if loadErr != nil {
					cache.remove(key)
				} else {
					cache.characters += len(entry.text)
					cache.touch(key)
					cache.trim()
				}
			}
			close(entry.ready)
			cache.mu.Unlock()
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-entry.ready:
		}
		if entry.err != nil {
			return nil, entry.err
		}
		length := len(entry.text)
		start := offset
		if start > length {
			start = length
		}
		end := start + limit
		if end > length {
			end = length
		}
		if end < length && end > start && entry.text[end-1] >= 0xD800 && entry.text[end-1] <= 0xDBFF {
			end++
		}
		if start > 0 && start < length && entry.text[start] >= 0xDC00 && entry.text[start] <= 0xDFFF {
			start--
		}
		var next any
		if end < length {
			next = end
		}
		return model.Object{"text": string(utf16.Decode(entry.text[start:end])), "nextOffset": next, "totalCharacters": length}, nil
	})
}
func (c *snapshots) remove(key string) {
	if entry := c.entries[key]; entry != nil {
		c.characters -= len(entry.text)
		delete(c.entries, key)
	}
	for i, v := range c.order {
		if v == key {
			c.order = append(c.order[:i], c.order[i+1:]...)
			break
		}
	}
}
func (c *snapshots) touch(key string) {
	for i, v := range c.order {
		if v == key {
			c.order = append(c.order[:i], c.order[i+1:]...)
			break
		}
	}
	c.order = append(c.order, key)
}
func (c *snapshots) trim() {
	for len(c.order) > 8 || (len(c.order) > 1 && c.characters > 8*1024*1024) {
		c.remove(c.order[0])
	}
}

var ThreadProperty = model.Object{"type": "object", "properties": model.Object{"threadId": model.Object{"type": "string", "minLength": 1}, "typeId": model.Object{"type": "string", "minLength": 1}}, "required": []string{"threadId", "typeId"}, "additionalProperties": false}
