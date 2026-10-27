// Package report owns persistent, read-only reports. A report is an application
// document, never a Harness session or an agent execution.
package report

import (
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"path"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	appvalue "github.com/hupao-creator/Mokusei/internal/plugins/applications/value"
	"github.com/hupao-creator/Mokusei/internal/services/taglabel"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
	"golang.org/x/text/unicode/norm"
)

const (
	MaxTitleLength      = 60
	MaxIdentifierLength = 128
	MaxHTMLCharacters   = 1_000_000
	MaxPreviewLength    = 220
	MaxRelatedThreads   = 256
	MaxDocuments        = 10_000
)

type TagSource struct {
	TagEmojis     map[string]string `json:"tagEmojis"`
	SemanticTags  []string          `json:"semanticTags"`
	DirectoryTags []string          `json:"directoryTags"`
}
type Data struct {
	Scope             string               `json:"scope"`
	Title             string               `json:"title"`
	HTML              string               `json:"html"`
	ContentRevision   string               `json:"contentRevision"`
	Archived          bool                 `json:"archived"`
	RelatedExecutions []model.ExecutionRef `json:"relatedExecutions"`
	TagSources        map[string]TagSource `json:"tagSources"`
}
type View struct {
	PreviewText       string               `json:"previewText"`
	ContentRevision   string               `json:"contentRevision"`
	RelatedExecutions []model.ExecutionRef `json:"relatedExecutions"`
}
type Summary struct {
	ID                 string `json:"id"`
	Revision           int64  `json:"revision"`
	Title              string `json:"title"`
	CreatedAt          int64  `json:"createdAt"`
	UpdatedAt          int64  `json:"updatedAt"`
	RelatedThreadCount int    `json:"relatedThreadCount"`
	TagCount           int    `json:"tagCount"`
	Archived           bool   `json:"archived"`
}
type Content struct {
	ID                string               `json:"id"`
	Revision          int64                `json:"revision"`
	CreatedAt         int64                `json:"createdAt"`
	UpdatedAt         int64                `json:"updatedAt"`
	Title             string               `json:"title"`
	Archived          bool                 `json:"archived"`
	HTML              string               `json:"html"`
	ContentRevision   string               `json:"contentRevision"`
	RelatedExecutions []model.ExecutionRef `json:"relatedExecutions"`
	model.TagProjection
}
type CreateInput struct {
	Title             string               `json:"title"`
	HTML              string               `json:"html"`
	RelatedExecutions []model.ExecutionRef `json:"relatedExecutions"`
}
type UpdateInput struct {
	ReportID          string                `json:"reportId"`
	Title             *string               `json:"title,omitempty"`
	HTML              *string               `json:"html,omitempty"`
	RelatedExecutions *[]model.ExecutionRef `json:"relatedExecutions,omitempty"`
}
type IdentityInput struct {
	ReportID string `json:"reportId"`
}
type ListInput struct {
	Cursor          *string `json:"cursor,omitempty"`
	Limit           int     `json:"limit"`
	IncludeArchived bool    `json:"includeArchived"`
}
type Page struct {
	Items      []Summary `json:"items"`
	NextCursor string    `json:"nextCursor,omitempty"`
}

func ParseTitle(value string) (string, error) {
	title := strings.Join(strings.Fields(value), " ")
	if title == "" {
		return "", errors.New("报告 title 不能为空")
	}
	if utf8.RuneCountInString(title) > MaxTitleLength {
		return "", fmt.Errorf("报告 title 不能超过 %d 个字符", MaxTitleLength)
	}
	return title, nil
}

var rawMarkup = regexp.MustCompile(`(?i)<(?:[!?]|/?[a-z])`)
var markupStart = regexp.MustCompile(`(?i)^\s*<(?:[!?]|/?[a-z][^\s/>]*(?:[\s/>]))`)

func ParseHTML(value string) (string, error) {
	if strings.TrimSpace(value) == "" {
		return "", errors.New("报告 html 不能为空")
	}
	if utf8.RuneCountInString(value) > MaxHTMLCharacters {
		return "", fmt.Errorf("报告 html 不能超过 %d 个 Unicode 字符", MaxHTMLCharacters)
	}
	if !rawMarkup.MatchString(value) && markupStart.MatchString(html.UnescapeString(value)) {
		return "", errors.New("报告 html 必须提交原始 HTML，例如 <h2>结论摘要</h2>，不能将整篇标签转义成 &lt;h2&gt;。请使用原始 HTML 重试；如需展示代码示例，请放在 <pre><code> 中并仅转义示例内容。")
	}
	return value, nil
}
func validID(id string) bool {
	return id != "" && model.UTF16Length(id) <= MaxIdentifierLength && !strings.ContainsRune(id, 0) && strings.IndexFunc(id, unicode.IsSpace) < 0
}
func validateReferences(refs []model.ExecutionRef) error {
	if refs == nil {
		return errors.New("报告 relatedExecutions 必须是关联数组")
	}
	if len(refs) > MaxRelatedThreads {
		return fmt.Errorf("报告 relatedExecutions 不能超过 %d 项", MaxRelatedThreads)
	}
	seen := map[string]bool{}
	for _, ref := range refs {
		if ref.Thread.TypeID != "agent" || !validID(ref.Thread.ThreadID) || !validID(ref.ExecutionID) {
			return errors.New("报告关联含无效的 Thread 或 Execution ID")
		}
		if seen[ref.Thread.ThreadID] {
			return errors.New("同一报告对同一 Thread 只能关联一个 Execution")
		}
		seen[ref.Thread.ThreadID] = true
	}
	return nil
}
func validScope(scope string) bool {
	return scope == "inbox" || (path.IsAbs(scope) && path.Clean(scope) == scope && !strings.ContainsRune(scope, 0))
}

func ParseData(raw json.RawMessage) (Data, error) {
	var value Data
	if err := appvalue.Decode(raw, &value); err != nil {
		return value, err
	}
	if !validScope(value.Scope) {
		return value, errors.New("invalid report scope")
	}
	var err error
	if value.Title, err = ParseTitle(value.Title); err != nil {
		return value, err
	}
	if value.HTML, err = ParseHTML(value.HTML); err != nil {
		return value, err
	}
	if !validID(value.ContentRevision) {
		return value, errors.New("invalid report content revision")
	}
	if err = validateReferences(value.RelatedExecutions); err != nil {
		return value, err
	}
	if value.TagSources == nil || len(value.TagSources) != len(value.RelatedExecutions) {
		return value, errors.New("Report tag sources must match its execution references")
	}
	for _, ref := range value.RelatedExecutions {
		source, ok := value.TagSources[ref.Thread.ThreadID]
		if !ok || source.SemanticTags == nil || source.DirectoryTags == nil || source.TagEmojis == nil {
			return value, errors.New("Report tag sources must match its execution references")
		}
		if len(source.TagEmojis) != len(source.SemanticTags) {
			return value, errors.New("Report tag emojis must match semantic tags")
		}
		for _, name := range source.SemanticTags {
			if !taglabel.ValidEmoji(source.TagEmojis[name]) || taglabel.HasEmojiPrefix(name) {
				return value, errors.New("invalid Report semantic tag decoration")
			}
		}
	}
	return value, nil
}
func ProjectTags(value Data) model.TagProjection {
	semantic, directory := []string{}, []string{}
	if value.Scope != "inbox" {
		directory = append(directory, path.Base(value.Scope))
	}
	candidates := map[string]string{}
	for _, ref := range value.RelatedExecutions {
		source := value.TagSources[ref.Thread.ThreadID]
		for name, emoji := range source.TagEmojis {
			if _, exists := candidates[name]; !exists {
				candidates[name] = emoji
			}
		}
		semantic = append(semantic, source.SemanticTags...)
	}
	semantic, directory = uniqueTags(semantic), uniqueTags(directory)
	emojis := map[string]string{}
	for _, name := range semantic {
		emojis[name] = candidates[name]
	}
	return model.TagProjection{Tags: uniqueTags(append(append([]string{}, directory...), semantic...)), SemanticTags: semantic, DirectoryTags: directory, TagEmojis: emojis}
}
func uniqueTags(values []string) []string {
	result := []string{}
	seen := map[string]bool{}
	for _, value := range values {
		key := cases.Lower(language.Und).String(strings.Join(strings.Fields(norm.NFKC.String(value)), " "))
		if key != "" && !seen[key] {
			seen[key] = true
			result = append(result, value)
		}
	}
	return result
}
func summarize(record model.VersionedRecord, value Data) Summary {
	return Summary{ID: record.ID, Revision: record.Revision, Title: value.Title, CreatedAt: record.CreatedAt, UpdatedAt: record.UpdatedAt, RelatedThreadCount: len(value.RelatedExecutions), TagCount: len(ProjectTags(value).Tags), Archived: value.Archived}
}

var tagName = regexp.MustCompile(`(?i)^\s*(/?)\s*([a-z][\w:-]*)`)
var hiddenTags = map[string]bool{"head": true, "script": true, "style": true, "template": true, "noscript": true, "svg": true}

// HTMLPreview scans once and never executes, sanitizes, or rewrites the document.
func HTMLPreview(source, title string) string { return htmlReaderText(source, title, MaxPreviewLength) }

// HTMLSearchText shares the established reader-text scan, without the card's
// excerpt truncation. It never executes script, reads files or loads resources.
func HTMLSearchText(source string) string { return htmlReaderText(source, "", 0) }

func htmlReaderText(source, title string, limit int) string {
	var visible strings.Builder
	// HTML tag names are ASCII. Full Unicode lowercasing may change byte length
	// and invalidate the offsets used to skip non-reader content below.
	lower := asciiLower(source)
	for cursor := 0; cursor < len(source); {
		relative := strings.IndexByte(source[cursor:], '<')
		if relative < 0 {
			visible.WriteString(source[cursor:])
			break
		}
		start := cursor + relative
		visible.WriteString(source[cursor:start])
		if strings.HasPrefix(source[start:], "<!--") {
			end := strings.Index(source[start+4:], "-->")
			if end < 0 {
				break
			}
			cursor = start + 4 + end + 3
			visible.WriteByte(' ')
			continue
		}
		end := htmlTagEnd(source, start+1)
		if end < 0 {
			visible.WriteString(source[start:])
			break
		}
		tag := source[start+1 : end]
		match := tagName.FindStringSubmatch(tag)
		if match == nil {
			if strings.HasPrefix(strings.TrimSpace(tag), "!") || strings.HasPrefix(strings.TrimSpace(tag), "?") {
				visible.WriteByte(' ')
			} else {
				visible.WriteString(source[start : end+1])
			}
			cursor = end + 1
			continue
		}
		name := strings.ToLower(match[2])
		if match[1] == "" && !strings.HasSuffix(strings.TrimSpace(tag), "/") && hiddenTags[name] {
			closing := findClosingTag(lower, name, end+1)
			if closing < 0 {
				break
			}
			closingEnd := htmlTagEnd(source, closing+1)
			if closingEnd < 0 {
				break
			}
			cursor = closingEnd + 1
		} else {
			cursor = end + 1
		}
		visible.WriteByte(' ')
	}
	text := strings.Join(strings.Fields(decodePreviewEntities(visible.String())), " ")
	normalizedTitle := strings.Join(strings.Fields(title), " ")
	if normalizedTitle != "" && strings.HasPrefix(text, normalizedTitle) {
		rest := strings.TrimPrefix(text, normalizedTitle)
		if rest == "" || strings.ContainsRune(" :：|·—–-\t\n", []rune(rest)[0]) {
			text = strings.TrimLeftFunc(rest, func(r rune) bool { return unicode.IsSpace(r) || strings.ContainsRune(":：|·—–-", r) })
		}
	}
	characters := []rune(text)
	if limit > 0 && len(characters) > limit {
		return strings.TrimRightFunc(string(characters[:limit-1]), unicode.IsSpace) + "…"
	}
	return text
}
func asciiLower(value string) string {
	data := []byte(value)
	for index, c := range data {
		if c >= 'A' && c <= 'Z' {
			data[index] = c + ('a' - 'A')
		}
	}
	return string(data)
}

var previewEntity = regexp.MustCompile(`(?i)&(?:#[0-9]+|#x[0-9a-f]+|[a-z][a-z0-9]+);`)
var previewNames = map[string]string{"amp": "&", "apos": "'", "copy": "©", "gt": ">", "hellip": "…", "lt": "<", "mdash": "—", "middot": "·", "nbsp": " ", "ndash": "–", "quot": "\"", "reg": "®"}

func decodePreviewEntities(value string) string {
	return previewEntity.ReplaceAllStringFunc(value, func(entity string) string {
		name := entity[1 : len(entity)-1]
		if strings.HasPrefix(name, "#") {
			base := 10
			digits := name[1:]
			if strings.HasPrefix(digits, "x") || strings.HasPrefix(digits, "X") {
				base = 16
				digits = digits[1:]
			}
			point, err := strconv.ParseUint(digits, base, 32)
			if err != nil || point == 0 || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff) {
				return " "
			}
			return string(rune(point))
		}
		if decoded, ok := previewNames[strings.ToLower(name)]; ok {
			return decoded
		}
		return entity
	})
}
func htmlTagEnd(source string, start int) int {
	var quote byte
	state := byte(0)
	declaration := start < len(source) && (source[start] == '!' || source[start] == '?')
	space := func(c byte) bool { return strings.ContainsRune("\t\n\f\r ", rune(c)) }
	for index := start; index < len(source); index++ {
		c := source[index]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			}
		case declaration && (c == '\'' || c == '"'):
			quote = c
		case c == '>':
			return index
		case state == 1:
			if space(c) {
				continue
			}
			if c == '\'' || c == '"' {
				quote = c
				state = 0
			} else {
				state = 2
			}
		case state == 2:
			if space(c) {
				state = 0
			}
		case c == '=':
			state = 1
		}
	}
	return -1
}
func findClosingTag(source, name string, start int) int {
	prefix := "</" + name
	for start < len(source) {
		offset := strings.Index(source[start:], prefix)
		if offset < 0 {
			return -1
		}
		candidate := start + offset
		end := candidate + len(prefix)
		if end == len(source) || strings.ContainsRune(" \t\n\r\f/>", rune(source[end])) {
			return candidate
		}
		start = end
	}
	return -1
}
