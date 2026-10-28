package moku

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"regexp"
	"sort"
	"strings"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
	"golang.org/x/text/unicode/norm"
)

var threadListStatuses = []string{"idle", "running", "waiting-for-user", "waiting-for-background", "completed", "interrupted", "failed"}

// ThreadListInputSchema shares its representable limits with ListThreads.
func ThreadListInputSchema() json.RawMessage {
	return mokuRaw(map[string]any{
		"type": "object", "additionalProperties": false,
		"properties": map[string]any{
			"limit":    map[string]any{"type": "integer", "minimum": 1, "maximum": 50, "description": "Number of Threads to return; defaults to 20."},
			"cursor":   map[string]any{"type": "string", "minLength": 1, "maxLength": 1024, "pattern": "^[A-Za-z0-9_-]+$", "description": "Opaque nextCursor from the previous page. Keep the same tags and statuses when continuing; omit to refresh from the beginning."},
			"tags":     map[string]any{"type": "array", "maxItems": 50, "items": map[string]any{"type": "string", "minLength": 1, "maxLength": 4096, "pattern": `^\s*[^\s\u0000][^\u0000]*$`}, "description": "Match any directory or content tag using overview normalization (Unicode, case and whitespace). Omit or pass [] for no tag filter."},
			"statuses": map[string]any{"type": "array", "maxItems": len(threadListStatuses), "items": map[string]any{"type": "string", "enum": threadListStatuses}, "description": "Match any listed status, together with any tags filter. Omit or pass [] for no status filter. waiting-for-background means the latest execution completed but the Thread still has running background work; completed means that work has ended."},
		},
	})
}

// ListThreads takes one committed-state snapshot. A subsequent page may see
// newer state; entries moved before its cursor intentionally require a refresh.
func ListThreads(records []model.ThreadRecord, raw json.RawMessage) (json.RawMessage, error) {
	request, err := model.DecodeObject(raw)
	if err != nil || !mokuAllowedKeys(request, "limit", "cursor", "tags", "statuses") {
		return nil, errors.New("list_threads requires an object containing only limit, cursor, tags and statuses")
	}
	limit := 20
	if value, ok := request["limit"]; ok {
		n, valid := mokuNumber(value)
		if !valid || n < 1 || n > 50 || math.Trunc(n) != n {
			return nil, errors.New("list_threads limit must be an integer between 1 and 50")
		}
		limit = int(n)
	}
	tags, err := mokuListFilter(request, "tags", 50, func(value string) bool {
		return model.UTF16Length(value) > 0 && model.UTF16Length(value) <= 4096 && !strings.ContainsRune(value, 0) && strings.TrimFunc(value, mokuWhitespace) != ""
	}, ThreadTagKey)
	if err != nil {
		return nil, err
	}
	for _, tag := range tags {
		if tag == "" {
			return nil, errors.New("list_threads tags 不能为空")
		}
	}
	statuses, err := mokuListFilter(request, "statuses", len(threadListStatuses), func(value string) bool {
		for _, candidate := range threadListStatuses {
			if value == candidate {
				return true
			}
		}
		return false
	}, func(value string) string { return value })
	if err != nil {
		return nil, err
	}
	// Struct field order matches JSON.stringify({tags,statuses}), making cursors
	// stable across the migration and independent of Go map iteration order.
	filterBytes := mokuRaw(struct {
		Tags     []string `json:"tags"`
		Statuses []string `json:"statuses"`
	}{tags, statuses})
	digest := sha256.Sum256(filterBytes)
	filter := hex.EncodeToString(digest[:])
	var cursor *mokuListCursor
	if value, present := request["cursor"]; present {
		text, valid := value.(string)
		if !valid || len(text) == 0 || len(text) > 1024 || !mokuCursorPattern.MatchString(text) {
			return nil, errors.New("list_threads cursor 无效，请省略 cursor 从第一页重新查询")
		}
		cursor, err = mokuReadCursor(text, filter)
		if err != nil {
			return nil, err
		}
	}
	matching := make([]model.ThreadRecord, 0, len(records))
	for _, thread := range records {
		if thread.Moku || thread.MokuHistory || thread.Archived != nil && *thread.Archived {
			continue
		}
		if len(statuses) > 0 && !mokuIncludes(statuses, ThreadListStatus(thread)) {
			continue
		}
		if len(tags) > 0 {
			matches := mokuIncludes(tags, ThreadTagKey(ThreadDirectoryTag(thread.Cwd)))
			for _, tag := range thread.Tags {
				matches = matches || mokuIncludes(tags, ThreadTagKey(tag))
			}
			if !matches {
				continue
			}
		}
		matching = append(matching, thread)
	}
	sort.Slice(matching, func(i, j int) bool {
		if matching[i].UpdatedAt != matching[j].UpdatedAt {
			return matching[i].UpdatedAt > matching[j].UpdatedAt
		}
		return mokuUTF16Less(matching[i].ID, matching[j].ID)
	})
	remaining := make([]model.ThreadRecord, 0, len(matching))
	for _, thread := range matching {
		if cursor == nil || float64(thread.UpdatedAt) < cursor.UpdatedAt || float64(thread.UpdatedAt) == cursor.UpdatedAt && mokuUTF16Less(cursor.ThreadID, thread.ID) {
			remaining = append(remaining, thread)
		}
	}
	page := remaining
	if len(page) > limit {
		page = page[:limit]
	}
	items := make([]any, 0, len(page))
	for _, thread := range page {
		items = append(items, map[string]any{"threadId": thread.ID, "title": thread.Title, "updatedAt": thread.UpdatedAt, "status": ThreadListStatus(thread)})
	}
	var nextCursor any
	if len(remaining) > len(page) && len(page) > 0 {
		last := page[len(page)-1]
		nextCursor = base64.RawURLEncoding.EncodeToString(mokuRaw(mokuListCursor{float64(last.UpdatedAt), last.ID, filter}))
	}
	return mokuRaw(map[string]any{"ok": true, "count": len(page), "total": len(matching), "threads": items, "nextCursor": nextCursor}), nil
}

func ThreadListStatus(thread model.ThreadRecord) string {
	status := "idle"
	if thread.Observation.LatestExecution != nil {
		status = thread.Observation.LatestExecution.Status
	}
	if status == "completed" && thread.Observation.BackgroundWork != nil && thread.Observation.BackgroundWork.Status == "running" {
		return "waiting-for-background"
	}
	return status
}

// ThreadTagKey follows the Overview's NFKC, locale-neutral Unicode lowercase,
// ECMAScript whitespace collapsing and trimming rules.
func ThreadTagKey(value string) string {
	value = cases.Lower(language.Und).String(norm.NFKC.String(value))
	return strings.Join(strings.FieldsFunc(value, mokuWhitespace), " ")
}

func ThreadDirectoryTag(cwd string) string {
	return directorytag.Name(cwd)
}

type mokuListCursor struct {
	UpdatedAt float64 `json:"updatedAt"`
	ThreadID  string  `json:"threadId"`
	Filter    string  `json:"filter"`
}

var mokuCursorPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
var mokuFilterPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

func mokuReadCursor(value, filter string) (*mokuListCursor, error) {
	invalid := errors.New("list_threads cursor 无效，请省略 cursor 从第一页重新查询")
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, invalid
	}
	o, err := model.DecodeObject(decoded)
	if err != nil || len(o) != 3 || !mokuAllowedKeys(o, "updatedAt", "threadId", "filter") {
		return nil, invalid
	}
	updatedAt, valid := mokuNumber(o["updatedAt"])
	threadID, idOK := o["threadId"].(string)
	cursorFilter, filterOK := o["filter"].(string)
	if !valid || updatedAt < 0 || !idOK || model.UTF16Length(threadID) < 1 || model.UTF16Length(threadID) > 128 || !filterOK || !mokuFilterPattern.MatchString(cursorFilter) {
		return nil, invalid
	}
	if cursorFilter != filter {
		return nil, errors.New("list_threads cursor 的筛选条件（tags/statuses）不匹配；改变筛选条件后请从第一页重新查询")
	}
	return &mokuListCursor{updatedAt, threadID, cursorFilter}, nil
}

func mokuListFilter(request map[string]any, field string, max int, validate func(string) bool, normalize func(string) string) ([]string, error) {
	result := []string{}
	value, present := request[field]
	if !present {
		return result, nil
	}
	items, ok := value.([]any)
	if !ok || len(items) > max {
		return nil, errors.New("list_threads " + field + " 无效")
	}
	seen := make(map[string]bool, len(items))
	for _, item := range items {
		text, ok := item.(string)
		if !ok || !validate(text) {
			return nil, errors.New("list_threads " + field + " 无效")
		}
		text = normalize(text)
		if !seen[text] {
			seen[text] = true
			result = append(result, text)
		}
	}
	sort.Slice(result, func(i, j int) bool { return mokuUTF16Less(result[i], result[j]) })
	return result, nil
}

func mokuUTF16Less(a, b string) bool {
	left, right := utf16.Encode([]rune(a)), utf16.Encode([]rune(b))
	for i := 0; i < len(left) && i < len(right); i++ {
		if left[i] != right[i] {
			return left[i] < right[i]
		}
	}
	return len(left) < len(right)
}

func mokuWhitespace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', '\u00a0', '\u1680', '\u2028', '\u2029', '\u202f', '\u205f', '\u3000', '\ufeff':
		return true
	}
	return r >= '\u2000' && r <= '\u200a'
}

func mokuIncludes(values []string, value string) bool {
	for _, item := range values {
		if item == value {
			return true
		}
	}
	return false
}
func mokuAllowedKeys(object map[string]any, keys ...string) bool {
	for key := range object {
		if !mokuIncludes(keys, key) {
			return false
		}
	}
	return true
}
func mokuNumber(value any) (float64, bool) {
	n, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	v, err := n.Float64()
	return v, err == nil && !math.IsInf(v, 0) && !math.IsNaN(v)
}

// mokuRaw handles only validated JSON values and static schemas. The encoder
// uses JSON.stringify-compatible string escaping for byte limits and hashes.
func mokuRaw(value any) json.RawMessage {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		panic(err)
	}
	raw := bytes.TrimSuffix(buffer.Bytes(), []byte("\n"))
	// Do not replace an escaped literal "\\u2028" within user text.
	out := make([]byte, 0, len(raw))
	for i := 0; i < len(raw); i++ {
		if raw[i] == '\\' && i+1 < len(raw) {
			if i+5 < len(raw) && (string(raw[i:i+6]) == `\u2028` || string(raw[i:i+6]) == `\u2029`) {
				if raw[i+5] == '8' {
					out = append(out, []byte("\u2028")...)
				} else {
					out = append(out, []byte("\u2029")...)
				}
				i += 5
				continue
			}
			out = append(out, raw[i], raw[i+1])
			i++
			continue
		}
		out = append(out, raw[i])
	}
	return out
}
