package model

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var contributionPattern = regexp.MustCompile(`^[a-z][a-z0-9_.-]*$`)
var commandUUID = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// CommandJSONSize enforces serialized UTF-8 bytes, independently of the UTF-16
// string-field limits. Whitespace and HTML escaping on the incoming wire cannot
// change the admitted payload size. Numbers remain lossless json.Number values.
func CommandJSONSize(value any, maximum int) error {
	var data bytes.Buffer
	encoder := json.NewEncoder(&data)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return err
	}
	if data.Len()-1 > maximum {
		return errors.New("serialized JSON exceeds limit")
	}
	return nil
}

// ValidateCommandArguments validates the common wire envelope before any
// business/native I/O. Owning modules still validate their opaque inner values.
func ValidateCommandArguments(channel string, args []json.RawMessage) (failure error) {
	defer func() {
		if failure != nil {
			failure = fmt.Errorf("Invalid command argument (%s): %w", channel, failure)
		}
	}()
	arity := 1
	switch channel {
	case "search:status", "state:load", "history:clear", "moku:clear", "moku:deliveries", "harness:detect-installations", "workspace:list-known-directories":
		arity = 0
	case "attachment:preview", "thread:set-archived", "application:archive":
		arity = 2
	}
	if len(args) != arity {
		return errors.New("incorrect argument count")
	}
	if arity == 0 {
		return nil
	}
	value, err := Decode(args[0])
	if err != nil {
		return err
	}
	text := func(value any, limit int) error {
		if err := checkText(value, limit, false); err != nil {
			return err
		}
		if value.(string) == "" {
			return errors.New("empty text")
		}
		return nil
	}
	contribution := func(value any) error {
		if err := text(value, 128); err != nil {
			return err
		}
		if !contributionPattern.MatchString(value.(string)) {
			return errors.New("invalid contribution ID")
		}
		return nil
	}
	uuid := func(value any) error {
		if err := text(value, 36); err != nil {
			return err
		}
		if !commandUUID.MatchString(value.(string)) {
			return errors.New("invalid UUID")
		}
		return nil
	}
	if arity == 2 && channel != "attachment:preview" {
		second, err := Decode(args[1])
		if err != nil {
			return err
		}
		if err = checkBoolean(second); err != nil {
			return err
		}
	}
	switch channel {
	case "moku:record-note-exposure":
		object, err := objectKeys(value, []string{"noteId", "revision", "signal"}, []string{"noteId", "revision", "signal"})
		if err != nil {
			return err
		}
		if err := uuid(object["noteId"]); err != nil {
			return err
		}
		n, ok := object["revision"].(json.Number)
		if !ok {
			return errors.New("invalid note revision")
		}
		revision, err := n.Int64()
		if err != nil || revision < 1 || revision > MaximumSafeInteger {
			return errors.New("invalid note revision")
		}
		if object["signal"] != NoteExposureSignal {
			return errors.New("invalid note exposure signal")
		}
		return nil
	case "attachment:preview":
		if err = text(value, 128); err != nil {
			return err
		}
		id, err := Decode(args[1])
		if err != nil {
			return err
		}
		return uuid(id)
	case "thread:set-archived":
		return text(value, 128)
	case "harness:detect-installation":
		return text(value, 128)
	case "harness:install":
		_, ok := value.(string)
		if !ok {
			return errors.New("expected Harness ID")
		}
		return nil
	case "attachment:discard":
		array, ok := value.([]any)
		if !ok || len(array) > 20 {
			return errors.New("expected up to 20 attachment IDs")
		}
		for _, id := range array {
			if err = uuid(id); err != nil {
				return err
			}
		}
		return nil
	case "moku:stage-attachments":
		if value == nil {
			return nil
		}
		array, ok := value.([]any)
		if !ok || len(array) > 20 {
			return errors.New("expected up to 20 attachments")
		}
		for _, entry := range array {
			object, ok := entry.(map[string]any)
			if !ok {
				return errors.New("attachment must be an object")
			}
			keys := []string{"source", "displayName", "bytes"}
			required := []string{"source", "bytes"}
			if object["source"] == "path" {
				keys = []string{"source", "displayName", "path"}
				required = []string{"source", "path"}
			} else if object["source"] != "bytes" {
				return errors.New("unknown attachment source")
			}
			if _, err = objectKeys(object, keys, required); err != nil {
				return err
			}
			if display, exists := object["displayName"]; exists && display != nil {
				if err = checkText(display, 1024, false); err != nil {
					return err
				}
			}
			if object["source"] == "path" {
				if err = text(object["path"], 4096); err != nil {
					return err
				}
			}
		}
		return nil
	case "application:archive", "application:initialize-conversation":
		object, err := objectKeys(value, []string{"threadId", "typeId"}, []string{"threadId", "typeId"})
		if err != nil {
			return err
		}
		if err = text(object["threadId"], 128); err != nil {
			return err
		}
		return contribution(object["typeId"])
	case "application:command", "application:query":
		keys := []string{"pluginId", "operationId", "input"}
		limit := 2_000_000
		if channel == "application:command" {
			keys = append(keys, "requestId")
			limit = 50_000_000
		}
		object, err := objectKeys(value, keys, keys)
		if err != nil {
			return err
		}
		if err = contribution(object["pluginId"]); err != nil {
			return err
		}
		if err = contribution(object["operationId"]); err != nil {
			return err
		}
		if channel == "application:command" {
			if err = text(object["requestId"], 256); err != nil {
				return err
			}
		}
		return CommandJSONSize(value, limit)
	case "app:update-settings":
		return CommandJSONSize(value, 2_000_000)
	case "search:query", "search:configure", "search:model", "search:index":
		return CommandJSONSize(value, 2_000_000)
	case "settings:diagnostics", "moku:voice", "moku:voice-events":
		return nil // Strict typed validators are owned by these modules.
	}
	var allowed, required []string
	switch channel {
	case "thread:interrupt", "moku:cancel":
		allowed = []string{"threadId", "expectedCancellationId"}
		required = allowed
	case "thread:follow-up":
		allowed = []string{"threadId", "input"}
		required = allowed
	case "thread:fork":
		allowed = []string{"threadId", "request"}
		required = allowed
	case "thread:read":
		allowed = []string{"threadId", "question"}
		required = allowed
	case "thread:update-settings":
		allowed = []string{"threadId", "harnessId", "change", "expectedSettingsRevision"}
		required = allowed
	case "thread:interaction-respond":
		allowed = []string{"threadId", "executionId", "interactionId", "actionId", "answers", "message"}
		required = []string{"threadId", "executionId", "interactionId", "actionId"}
	case "thread:voice", "thread:voice-events":
		allowed = []string{"threadId", "request"}
		required = allowed
	case "harness:extension":
		allowed = []string{"harnessId", "method", "payload"}
		required = allowed
	case "moku:resolve-delivery":
		allowed = []string{"id", "decision"}
		required = allowed
	case "moku:submit":
		allowed = []string{"input", "directoryTag", "directoryScopeId", "voiceInput"}
		required = []string{"input"}
	case "harness:settings-presentation":
		object, ok := value.(map[string]any)
		if !ok {
			return errors.New("expected presentation object")
		}
		switch object["scope"] {
		case "global":
			allowed = []string{"scope", "harnessId", "refresh", "executionOwner", "applicationSettings"}
			required = []string{"scope", "harnessId"}
		case "thread":
			allowed = []string{"scope", "threadId", "refresh"}
			required = []string{"scope", "threadId"}
		default:
			return errors.New("invalid settings scope")
		}
	default:
		return errors.New("unregistered command validation")
	}
	object, err := objectKeys(value, allowed, required)
	if err != nil {
		return err
	}
	for _, key := range []string{"threadId", "executionId", "expectedCancellationId", "interactionId", "actionId", "method", "applicationSettings"} {
		if entry, exists := object[key]; exists {
			if err = text(entry, 128); err != nil {
				return err
			}
		}
	}
	if value, exists := object["expectedSettingsRevision"]; exists {
		if n, ok := value.(json.Number); !ok {
			return errors.New("invalid settings revision")
		} else if v, e := n.Int64(); e != nil || v < 0 || v > MaximumSafeInteger {
			return errors.New("invalid settings revision")
		}
	}
	if id, exists := object["harnessId"]; exists {
		if _, ok := id.(string); !ok {
			return errors.New("expected Harness ID")
		}
	}
	if channel == "thread:read" {
		return text(object["question"], 1_000_000)
	}
	for key, limit := range map[string]int{"request": 8 * 1024 * 1024, "payload": 8 * 1024 * 1024, "change": 1_000_000, "answers": 1_000_000} {
		if item, exists := object[key]; exists {
			if key == "change" || key == "answers" {
				if _, ok := item.(map[string]any); !ok {
					return errors.New("expected object for " + key)
				}
			}
			if err = CommandJSONSize(item, limit); err != nil {
				return err
			}
		}
	}
	if channel == "harness:extension" && strings.TrimSpace(object["method"].(string)) != object["method"] {
		return errors.New("invalid method whitespace")
	}
	if refresh, exists := object["refresh"]; exists {
		if err = checkBoolean(refresh); err != nil {
			return err
		}
	}
	if owner, exists := object["executionOwner"]; exists && owner != "moku" {
		return errors.New("invalid execution owner")
	}
	if directory, exists := object["directoryTag"]; exists {
		if err = text(directory, 256); err != nil {
			return err
		}
	}
	// Moku requires the host-derived scope to resolve a selected directory;
	// the display tag alone is not an identity.
	if scope, exists := object["directoryScopeId"]; exists {
		return text(scope, 4096)
	}
	return nil
}
