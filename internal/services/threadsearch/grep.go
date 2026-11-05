package threadsearch

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// GrepSource comes from an authoritative ordinary-thread snapshot, never the
// bounded Overview index. The owner controls eligibility and revalidation.
type GrepSource struct {
	ID, Title, ScopeID, Hash string
	Archived                 bool
	StateBytes               int
	Load                     func() ([]plugin.SearchPassage, error)
}

type grepRequest struct {
	Query            string   `json:"query"`
	Mode             string   `json:"mode"`
	CaseSensitive    bool     `json:"caseSensitive"`
	Field            string   `json:"field"`
	IncludeArchived  bool     `json:"includeArchived"`
	ThreadIDs        []string `json:"threadIds"`
	DirectoryScopeID string   `json:"directoryScopeId"`
	Limit            int      `json:"limit"`
	Cursor           string   `json:"cursor"`
}

type grepCursor struct {
	Filter string `json:"filter"`
	After  string `json:"after"`
}

type GrepHit struct {
	ThreadID     string `json:"threadId"`
	ExecutionID  string `json:"executionId,omitempty"`
	PassageIndex int    `json:"passageIndex"`
	Field        string `json:"field"`
	Archived     bool   `json:"archived"`
	Snippet      string `json:"snippet"`
	// Offsets are UTF-8 bytes within the original individual title/message.
	Start          int  `json:"startByte"`
	End            int  `json:"endByte"`
	SnippetStart   int  `json:"snippetStartByte"`
	MatchTruncated bool `json:"matchTruncated"`
}

type GrepIssue struct {
	ThreadID string `json:"threadId"`
	Reason   string `json:"reason"`
}

type GrepResult struct {
	Hits       []GrepHit   `json:"hits"`
	Issues     []GrepIssue `json:"issues"`
	Scanned    int         `json:"scannedThreads"`
	NextCursor string      `json:"nextCursor,omitempty"`
	Coverage   string      `json:"coverage"`
}

// Grep returns the first matching passage per thread. Live keyset pages avoid
// storing a second copy of private history; refresh to see edits behind a cursor.
func Grep(ctx context.Context, raw json.RawMessage, sources []GrepSource, valid func(GrepSource) bool) (GrepResult, error) {
	result := GrepResult{Hits: []GrepHit{}, Issues: []GrepIssue{}, Coverage: "Committed public completed-execution text only; not complete native history. One first match per thread. Live pages: refresh for edits behind the cursor. Issues describe unavailable coverage on this page."}
	request := grepRequest{Mode: "literal", Field: "body", IncludeArchived: true, Limit: 20}
	var object map[string]json.RawMessage
	if json.Unmarshal(raw, &object) != nil || object == nil {
		return result, plugin.CallerError(errors.New("grep_threads requires an object"))
	}
	for _, value := range object {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return result, plugin.CallerError(errors.New("grep_threads does not accept null fields"))
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return result, plugin.CallerError(errors.New("invalid grep_threads arguments"))
	}
	if request.Query == "" || !utf8.ValidString(request.Query) || utf8.RuneCountInString(request.Query) > 1024 || strings.ContainsRune(request.Query, 0) || request.Limit < 1 || request.Limit > 50 || len(request.ThreadIDs) > 100 || len(request.DirectoryScopeID) > 4096 || strings.ContainsRune(request.DirectoryScopeID, 0) || len(request.Cursor) > 2048 {
		return result, plugin.CallerError(errors.New("grep_threads argument exceeds limits"))
	}
	if _, ok := object["directoryScopeId"]; ok && request.DirectoryScopeID == "" {
		return result, plugin.CallerError(errors.New("directoryScopeId must not be empty"))
	}
	if _, ok := object["cursor"]; ok && request.Cursor == "" {
		return result, plugin.CallerError(errors.New("cursor must not be empty"))
	}
	if request.Mode != "literal" && request.Mode != "regex" || request.Field != "body" && request.Field != "title" {
		return result, plugin.CallerError(errors.New("grep_threads mode must be literal/regex and field must be body/title"))
	}
	if request.Field == "title" {
		result.Coverage = "Current ordinary-thread titles only; no execution or native-history coverage. Live pages: refresh for edits behind the cursor."
	}
	ids := map[string]bool{}
	for _, id := range request.ThreadIDs {
		if id == "" || len(id) > 128 || strings.ContainsAny(id, " \t\r\n\x00") {
			return result, plugin.CallerError(errors.New("invalid grep_threads threadId"))
		}
		ids[id] = true
	}
	// Canonical filters bind continuation to the same query, but allow page size changes.
	request.ThreadIDs = make([]string, 0, len(ids))
	for id := range ids {
		request.ThreadIDs = append(request.ThreadIDs, id)
	}
	sort.Strings(request.ThreadIDs)
	cursorText := request.Cursor
	request.Cursor = ""
	limit := request.Limit
	request.Limit = 0
	filterBytes, _ := json.Marshal(request)
	filter := Hash(filterBytes)
	after := ""
	if cursorText != "" {
		data, err := base64.RawURLEncoding.DecodeString(cursorText)
		var cursor grepCursor
		if err != nil || json.Unmarshal(data, &cursor) != nil || cursor.Filter != filter || cursor.After == "" || len(cursor.After) > 128 {
			return result, plugin.CallerError(errors.New("invalid grep_threads cursor; restart without cursor"))
		}
		after = cursor.After
	}
	pattern := request.Query
	if request.Mode == "literal" {
		pattern = regexp.QuoteMeta(pattern)
	}
	if !request.CaseSensitive {
		pattern = "(?i)" + pattern
	}
	matcher, err := regexp.Compile(pattern)
	if err != nil {
		return result, plugin.CallerError(errors.New("invalid grep_threads RE2 regular expression"))
	}
	sort.Slice(sources, func(i, j int) bool { return sources[i].ID < sources[j].ID })
	selected := make([]GrepSource, 0, len(sources))
	for _, source := range sources {
		if source.ID <= after || !request.IncludeArchived && source.Archived || len(ids) > 0 && !ids[source.ID] || request.DirectoryScopeID != "" && source.ScopeID != request.DirectoryScopeID {
			continue
		}
		selected = append(selected, source)
	}
	scanned := []GrepSource{}
	bytesRead := 0
	for i, source := range selected {
		if err := ctx.Err(); err != nil {
			return GrepResult{}, err
		}
		if result.Scanned >= 100 || len(result.Hits) >= limit || request.Field == "body" && source.StateBytes <= 16<<20 && bytesRead+source.StateBytes > 32<<20 {
			data, _ := json.Marshal(grepCursor{Filter: filter, After: selected[i-1].ID})
			result.NextCursor = base64.RawURLEncoding.EncodeToString(data)
			break
		}
		result.Scanned++
		scanned = append(scanned, source)
		passages := []plugin.SearchPassage{{Text: source.Title}}
		if request.Field == "body" {
			if source.Load == nil {
				result.Issues = append(result.Issues, GrepIssue{source.ID, "unsupported-harness"})
				continue
			}
			if source.StateBytes == 0 {
				result.Issues = append(result.Issues, GrepIssue{source.ID, "missing-state"})
				continue
			}
			if source.StateBytes > 16<<20 {
				result.Issues = append(result.Issues, GrepIssue{source.ID, "state-size-limit"})
				continue
			}
			bytesRead += source.StateBytes
			passages, err = source.Load()
			if err != nil {
				result.Issues = append(result.Issues, GrepIssue{source.ID, "invalid-state"})
				continue
			}
		}
		hasText, unavailable := false, false
		for passageIndex, passage := range passages {
			if err := ctx.Err(); err != nil {
				return GrepResult{}, err
			}
			if passage.Unavailable {
				unavailable = true
				continue
			}
			if passage.Text == "" {
				continue
			}
			hasText = true
			loc := matcher.FindStringIndex(passage.Text)
			if loc == nil {
				continue
			}
			start := loc[0]
			for n := 0; n < 80 && start > 0; n++ {
				_, size := utf8.DecodeLastRuneInString(passage.Text[:start])
				start -= size
			}
			end := loc[0]
			for n := 0; n < 320 && end < len(passage.Text); n++ {
				_, size := utf8.DecodeRuneInString(passage.Text[end:])
				end += size
			}
			result.Hits = append(result.Hits, GrepHit{ThreadID: source.ID, ExecutionID: passage.ExecutionID, PassageIndex: passageIndex, Field: request.Field, Archived: source.Archived, Snippet: passage.Text[start:end], Start: loc[0], End: loc[1], SnippetStart: start, MatchTruncated: loc[1] > end})
			// Keep walking omitted passages so a hit does not hide incomplete
			// input coverage later in this thread.
			for _, remaining := range passages[passageIndex+1:] {
				if err := ctx.Err(); err != nil {
					return GrepResult{}, err
				}
				unavailable = unavailable || remaining.Unavailable
			}
			break
		}
		if unavailable {
			result.Issues = append(result.Issues, GrepIssue{source.ID, "unknown-input-visibility"})
		}
		if !hasText {
			result.Issues = append(result.Issues, GrepIssue{source.ID, "no-public-text"})
		}
	}
	// Changes, deletion and history clearing must not leak captured text. Do not
	// return raw adapter errors: they may contain private state or native paths.
	stale := map[string]bool{}
	for _, source := range scanned {
		if !valid(source) {
			stale[source.ID] = true
			result.Issues = append(result.Issues, GrepIssue{source.ID, "source-changed-refresh"})
		}
	}
	hits := result.Hits[:0]
	for _, hit := range result.Hits {
		if !stale[hit.ThreadID] {
			hits = append(hits, hit)
		}
	}
	result.Hits = hits
	if err := ctx.Err(); err != nil {
		return GrepResult{}, err
	}
	return result, nil
}
