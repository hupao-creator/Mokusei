// Package diagnostics writes bounded private service diagnostics. Logging never
// serializes native state, tool inputs, environment values or credential maps.
package diagnostics

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

const maxFileBytes int64 = 8 * 1024 * 1024
const retainedFiles = 4
const maxMessageBytes = 7 * 1024
const maxEntryBytes = 8 * 1024

var eventName = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)

type Logger struct {
	mu     sync.Mutex
	path   string
	file   *os.File
	size   int64
	closed bool
}

func New(directory string) (*Logger, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("runtime log directory must be a regular directory")
	}
	if err = os.Chmod(directory, 0700); err != nil {
		return nil, err
	}
	l := &Logger{path: filepath.Join(directory, "service.jsonl")}
	if err = l.open(); err != nil {
		return nil, err
	}
	return l, nil
}
func (l *Logger) open() error {
	if info, err := os.Lstat(l.path); err == nil && !info.Mode().IsRegular() {
		return errors.New("runtime log must be a regular file")
	}
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	if err = f.Chmod(0600); err != nil {
		f.Close()
		return err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	l.file = f
	l.size = info.Size()
	return nil
}
func (l *Logger) rotate() error {
	if err := l.file.Close(); err != nil {
		return err
	}
	l.file = nil
	if err := os.Remove(fmt.Sprintf("%s.%d", l.path, retainedFiles-1)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for i := retainedFiles - 2; i >= 1; i-- {
		if err := os.Rename(fmt.Sprintf("%s.%d", l.path, i), fmt.Sprintf("%s.%d", l.path, i+1)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := os.Rename(l.path, l.path+".1"); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return l.open()
}

// Event deliberately accepts an error, not an arbitrary field map. Callers own
// redaction at native API boundaries; the logger additionally bounds each line.
func (l *Logger) Event(kind string, cause error) {
	if l == nil {
		return
	}
	if !eventName.MatchString(kind) {
		kind = "runtime.event"
	}
	message := ""
	if cause != nil {
		message = cause.Error()
	}
	if len(message) > maxMessageBytes {
		message = message[:maxMessageBytes]
		for !utf8.ValidString(message) {
			message = message[:len(message)-1]
		}
		message += "…"
	}
	data, err := json.Marshal(struct {
		At      string `json:"at"`
		Event   string `json:"event"`
		Message string `json:"message,omitempty"`
	}{time.Now().UTC().Format(time.RFC3339Nano), kind, message})
	if err != nil {
		return
	}
	l.write(data)
}
func (l *Logger) write(data []byte) {
	if l == nil || len(data)+1 > maxEntryBytes {
		return
	}
	data = append(data, '\n')
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return
	}
	if l.file == nil {
		if l.open() != nil {
			return
		}
	}
	if l.size+int64(len(data)) > maxFileBytes {
		if l.rotate() != nil {
			return
		}
	}
	n, _ := l.file.Write(data)
	l.size += int64(n)
}
func (l *Logger) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	if l.file == nil {
		return nil
	}
	err := l.file.Sync()
	return errors.Join(err, l.file.Close())
}

// SettingsEvent accepts only the closed settings metadata vocabulary. Unknown
// fields, payloads, text values, native errors and user paths are never written.
// Strict request validation remains at the runtime command boundary.
func (l *Logger) SettingsEvent(event string, fields map[string]any) {
	if l == nil {
		return
	}
	event = strings.TrimPrefix(event, "settings.")
	allowed := map[string]bool{}
	for _, name := range strings.Fields("restored published applied.ordinary applied.moku applied.plugins apply.moku.deferred save.admitted save.conflict save.changed save.saved save.failed snapshot.saved snapshot.reused presentation.stale catalog.cache command.rejected") {
		allowed[name] = true
	}
	for _, name := range strings.Fields("save validate.plugins validate.profiles persist snapshot.persist snapshot.capture apply.moku command presentation") {
		for _, suffix := range []string{"started", "completed", "failed"} {
			allowed[name+"."+suffix] = true
		}
	}
	for _, name := range strings.Fields("page edit composition close retry conflict validation save command receive availability discard preferences presentation") {
		allowed["client."+name] = true
	}
	if !allowed[event] {
		return
	}
	out := map[string]any{"at": time.Now().UTC().Format(time.RFC3339Nano), "evt": "settings." + event, "module": "settings"}
	for key, value := range fields {
		switch key {
		case "flowId":
			if s, ok := value.(string); ok && settingsUUID.MatchString(s) {
				out[key] = s
			}
		case "traceId", "operationId", "spanId", "parentSpanId":
			if s, ok := value.(string); ok && settingsOperation.MatchString(s) {
				out[key] = s
			}
		case "revision", "expectedRevision", "stateRevision", "settingsRevision":
			if n, ok := settingsNumber(value); ok && n >= 0 && n == math.Trunc(n) {
				out[key] = n
			}
		case "durationMs", "queueMs":
			if n, ok := settingsNumber(value); ok && n >= 0 {
				out[key] = n
			}
		case "refresh", "changed", "initial", "normalized", "cancelled":
			if b, ok := value.(bool); ok {
				out[key] = b
			}
		case "fields":
			out[key] = settingsStrings(value, settingsFields, 10)
		case "stage":
			if s, ok := value.(string); ok && settingsIn(s, "schema normalize normalized plugins profiles persist persistence snapshot admission validation publication source") {
				out[key] = s
			}
		case "outcome":
			if s, ok := value.(string); ok && settingsIn(s, "started completed failed pending blocked saved conflict keep discard available unavailable opened closed hit miss joined invalidated reused refresh") {
				out[key] = s
			}
		case "scope":
			if s, ok := value.(string); ok && settingsIn(s, "global thread") {
				out[key] = s
			}
		case "harnessId":
			if s, ok := value.(string); ok && settingsIn(s, "codex claude pi opencode") {
				out[key] = s
			}
		case "owner", "applicationSettings":
			if s, ok := value.(string); ok && settingsIn(s, "moku report.settings tag.settings") {
				out[key] = s
			}
		case "channel":
			if s, ok := value.(string); ok && settingsIn(s, "app:update-settings thread:update-settings harness:settings-presentation settings:diagnostics") {
				out[key] = s
			}
		case "reason":
			if s, ok := value.(string); ok && settingsIn(s, "live-work replace-host recycle-host process-start source-changed workspace-changed refresh expired source") {
				out[key] = s
			}
		case "issues":
			out[key] = settingsIssues(value)
		}
	}
	data, err := json.Marshal(out)
	if err != nil {
		return
	}
	if len(data)+1 > maxEntryBytes {
		delete(out, "issues")
		out["issuesTruncated"] = true
		data, _ = json.Marshal(out)
	}
	l.write(data)
}

var settingsUUID = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var settingsOperation = regexp.MustCompile(`^[a-zA-Z0-9_-]{16,128}$`)
var settingsFields = strings.Fields("moku.hostHarnessPreference moku.executionHarnesses moku.targetHarnessIds moku.routingGuidance harnesses pluginSettings pluginEnabled appearance locale glassWorld")

func settingsIn(value, words string) bool {
	for _, word := range strings.Fields(words) {
		if value == word {
			return true
		}
	}
	return false
}
func settingsNumber(value any) (float64, bool) {
	var n float64
	switch v := value.(type) {
	case float64:
		n = v
	case float32:
		n = float64(v)
	case int:
		n = float64(v)
	case int64:
		n = float64(v)
	case uint64:
		n = float64(v)
	case json.Number:
		var e error
		n, e = v.Float64()
		if e != nil {
			return 0, false
		}
	default:
		return 0, false
	}
	return n, !math.IsNaN(n) && !math.IsInf(n, 0) && math.Abs(n) <= 9007199254740991
}
func settingsStrings(value any, allowed []string, limit int) []string {
	source := []string{}
	switch values := value.(type) {
	case []string:
		source = values
	case []any:
		for _, v := range values {
			if s, ok := v.(string); ok {
				source = append(source, s)
			}
		}
	}
	out := []string{}
	for _, value := range source {
		for _, known := range allowed {
			if value == known && len(out) < limit {
				out = append(out, value)
				break
			}
		}
	}
	return out
}
func settingsIssues(value any) []map[string]any {
	data, err := json.Marshal(value)
	if err != nil || len(data) > 64*1024 {
		return nil
	}
	var values []map[string]any
	if json.Unmarshal(data, &values) != nil {
		return nil
	}
	out := []map[string]any{}
	for _, issue := range values {
		if len(out) >= 32 {
			break
		}
		code, _ := issue["code"].(string)
		if !settingsIn(code, "invalid_type invalid_value invalid_literal invalid_enum_value invalid_union invalid_union_discriminator unrecognized_keys too_small too_big invalid_string invalid_format not_multiple_of not_finite custom required unknown_field") {
			code = "custom"
		}
		path := []any{}
		if segments, ok := issue["path"].([]any); ok {
			for _, part := range segments {
				if len(path) >= 16 {
					break
				}
				if n, ok := settingsNumber(part); ok && n >= 0 && n == math.Trunc(n) {
					path = append(path, n)
					continue
				}
				if key, ok := part.(string); ok && settingsIn(key, "settings expectedSettingsRevision moku hostHarnessPreference executionHarnesses targetHarnessIds routingGuidance harnesses pluginSettings pluginEnabled threadSettings model effort thinking mode serviceTier permissionMode useDefaultThreadSettings codex claude pi opencode fields event outcome flowId operationId revision durationMs id value args") {
					path = append(path, key)
				} else {
					path = append(path, "[field]")
				}
			}
		}
		out = append(out, map[string]any{"code": code, "path": path})
	}
	return out
}

// SearchEvent writes bounded, typed metadata through the existing rotation owner.
func (l *Logger) SearchEvent(event plugin.SearchDiagnostic) {
	switch event.Event {
	case "search.query.started", "search.query.completed", "search.request.completed",
		"search.index.started", "search.index.completed",
		"embedding.download.started", "embedding.download.completed", "embedding.process.start.completed",
		"embedding.process.stopped", "embedding.inference.completed":
	default:
		return
	}
	// Only allow known labels, even if an injected adapter supplies an unsafe error.
	if !settingsOperation.MatchString(event.OperationID) {
		event.OperationID = ""
	}
	if !settingsIn(event.Kind, "query index") {
		event.Kind = ""
	}
	if !settingsIn(event.Outcome, "completed failed fallback") {
		event.Outcome = ""
	}
	if !settingsIn(event.Mode, "keyword hybrid") {
		event.Mode = ""
	}
	if !settingsIn(event.Cache, "none hit miss") {
		event.Cache = ""
	}
	if event.Reason != "" && !settingsIn(event.Reason, "cancelled timeout local-unavailable cleanup unsupported model-missing input-limit response batch-limit download-failed internal query-limit paused disabled index-empty stale") {
		event.Reason = "internal"
	}
	data, err := json.Marshal(struct {
		At string `json:"at"`
		plugin.SearchDiagnostic
	}{time.Now().UTC().Format(time.RFC3339Nano), event})
	if err == nil {
		l.write(data)
	}
}
