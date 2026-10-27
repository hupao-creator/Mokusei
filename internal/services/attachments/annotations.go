package attachments

import (
	"encoding/json"
	"errors"
	"math"
	"strings"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type annotation struct {
	ID      string `json:"id"`
	Comment string `json:"comment"`
	URL     string `json:"url"`
	Title   string `json:"title"`
	Kind    string `json:"kind"`
	Rect    *struct {
		X      float64 `json:"x"`
		Y      float64 `json:"y"`
		Width  float64 `json:"width"`
		Height float64 `json:"height"`
	} `json:"rect"`
	Viewport *struct {
		Width   float64 `json:"width"`
		Height  float64 `json:"height"`
		ScrollX float64 `json:"scrollX"`
		ScrollY float64 `json:"scrollY"`
	} `json:"viewport"`
	Selector     *string `json:"selector,omitempty"`
	Text         *string `json:"text,omitempty"`
	ScreenshotID *string `json:"screenshotId,omitempty"`
}

func validateAnnotations(input model.AgentInput) error {
	var annotations []annotation
	if len(input.Annotations) > 0 {
		if err := model.Unmarshal(input.Annotations, &annotations); err != nil || annotations == nil {
			return errors.New("浏览器批注格式无效")
		}
		var entries []map[string]json.RawMessage
		if err := json.Unmarshal(input.Annotations, &entries); err != nil {
			return err
		}
		for _, entry := range entries {
			for _, key := range []string{"id", "comment", "url", "title", "kind", "rect", "viewport"} {
				if value, exists := entry[key]; !exists || model.IsNull(value) {
					return errors.New("浏览器批注字段缺失")
				}
			}
			for key, fields := range map[string][]string{"rect": {"x", "y", "width", "height"}, "viewport": {"width", "height", "scrollX", "scrollY"}} {
				var object map[string]json.RawMessage
				if err := json.Unmarshal(entry[key], &object); err != nil {
					return err
				}
				for _, field := range fields {
					if value, exists := object[field]; !exists || model.IsNull(value) {
						return errors.New("批注区域字段缺失")
					}
				}
			}
		}
	}
	if len(annotations) > 20 {
		return errors.New("批注数量不能超过 20 个")
	}
	ids := map[string]bool{}
	for _, a := range annotations {
		if !managedID.MatchString(a.ID) || ids[a.ID] {
			return errors.New("批注 ID 无效或重复")
		}
		ids[a.ID] = true
		scheme, _, err := model.ParseAbsoluteURL(a.URL)
		if err != nil || (scheme != "http" && scheme != "https") {
			return errors.New("批注 URL 必须是 HTTP(S) 链接")
		}
		if strings.TrimSpace(a.Comment) == "" || textLength(strings.TrimSpace(a.Comment)) > 10000 || textLength(a.Title) > 2048 || (a.Kind != "element" && a.Kind != "region") {
			return errors.New("批注内容无效")
		}
		if a.Selector != nil && textLength(*a.Selector) > 4096 || a.Text != nil && textLength(*a.Text) > 4000 {
			return errors.New("批注上下文过长")
		}
		if a.Rect == nil || a.Viewport == nil {
			return errors.New("批注区域缺失")
		}
		if !coordinate(a.Rect.X, false) || !coordinate(a.Rect.Y, false) || !coordinate(a.Rect.Width, true) || !coordinate(a.Rect.Height, true) || !coordinate(a.Viewport.Width, true) || !coordinate(a.Viewport.Height, true) || !finite(a.Viewport.ScrollX) || !finite(a.Viewport.ScrollY) {
			return errors.New("批注区域无效")
		}
		if a.ScreenshotID != nil {
			found := false
			for _, part := range input.Parts {
				if part.Kind == "image" && part.File != nil && part.File.ID == *a.ScreenshotID {
					found = true
					break
				}
			}
			if !managedID.MatchString(*a.ScreenshotID) || !found {
				return errors.New("批注截图必须是本条消息的图片附件")
			}
		}
	}
	for _, part := range input.Parts {
		if part.Kind == "text" && part.AnnotationID != "" && !ids[part.AnnotationID] {
			return errors.New("批注上下文缺少对应元数据")
		}
	}
	return nil
}
func coordinate(v float64, positive bool) bool {
	return finite(v) && v >= 0 && v <= 100000 && (!positive || v > 0)
}
func finite(v float64) bool   { return !math.IsNaN(v) && !math.IsInf(v, 0) }
func textLength(v string) int { return len(utf16.Encode([]rune(v))) }
