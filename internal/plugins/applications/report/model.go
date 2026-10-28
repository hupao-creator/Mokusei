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
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	appvalue "github.com/hupao-creator/Mokusei/internal/plugins/applications/value"
	"github.com/hupao-creator/Mokusei/internal/services/taglabel"
	htmlnode "golang.org/x/net/html"
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

var hiddenTags = map[string]bool{"head": true, "script": true, "style": true, "template": true, "noscript": true, "svg": true}

// HTMLPreview parses static reader text without executing or rewriting the document.
func HTMLPreview(source, title string) string { return htmlReaderText(source, title, MaxPreviewLength) }

// HTMLSearchText shares the reader-text projection, without the card's
// excerpt truncation. It never executes script, reads files or loads resources.
func HTMLSearchText(source string) string { return htmlReaderText(source, "", 0) }

func htmlReaderText(source, title string, limit int) string {
	var visible strings.Builder
	// The tree builder owns namespace changes, HTML integration points and
	// raw-text/RCDATA state. A tokenizer alone treats SVG <style/> as an
	// unclosed HTML style element and consumes the remaining document.
	root, err := htmlnode.Parse(strings.NewReader(source))
	if err != nil {
		root = recoverReaderHTMLPrefix(source)
	}
	var visit func(*htmlnode.Node)
	visit = func(node *htmlnode.Node) {
		if node.Type == htmlnode.ElementNode && hiddenTags[node.Data] {
			return
		}
		block := node.Type == htmlnode.ElementNode && node.Namespace == "" && readerBlockTags[node.Data]
		if block {
			visible.WriteByte(' ')
		}
		if node.Type == htmlnode.TextNode {
			visible.WriteString(node.Data)
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			visit(child)
		}
		if block {
			visible.WriteByte(' ')
		}
	}
	visit(root)
	text := strings.Join(strings.Fields(visible.String()), " ")
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

// Parse discards its partial tree on depth-limit and internal parser errors.
// Reparse bounded prefixes with the same HTML tree builder rather than guessing
// at text after a lost template/foreign-content context. Only successful trees
// are eligible for projection; even an unexpected parser error degrades safely.
// The search makes at most log2(len(source))+1 attempts and never splits UTF-8.
func recoverReaderHTMLPrefix(source string) *htmlnode.Node {
	root := &htmlnode.Node{Type: htmlnode.DocumentNode}
	low, high := 0, len(source)-1
	for low < high {
		end := low + (high-low+1)/2
		for end > low && !utf8.RuneStart(source[end]) {
			end--
		}
		if end == low {
			break
		}
		candidate, err := htmlnode.Parse(strings.NewReader(source[:end]))
		if err != nil {
			high = end - 1
		} else {
			root = candidate
			low = end
		}
	}
	return root
}

// Structural boundaries separate words; inline markup and comments do not.
var readerBlockTags = map[string]bool{
	"address": true, "article": true, "aside": true, "blockquote": true,
	"br": true, "dd": true, "details": true, "dialog": true, "div": true,
	"dl": true, "dt": true, "fieldset": true, "figcaption": true, "figure": true,
	"footer": true, "form": true, "h1": true, "h2": true, "h3": true,
	"h4": true, "h5": true, "h6": true, "header": true, "hr": true,
	"li": true, "main": true, "nav": true, "ol": true, "p": true,
	"pre": true, "section": true, "summary": true, "table": true,
	"td": true, "th": true, "tr": true, "ul": true, "textarea": true,
}
