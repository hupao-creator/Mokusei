package model

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var uuidPattern = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// UserThreadInput is the durable fact of an admitted public thread follow-up.
// Embedded input preserves the existing lifecycle input shape for consumers.
type UserThreadInput struct {
	AgentInput
	ExecutionID         string `json:"executionId"`
	StartedNewExecution bool   `json:"startedNewExecution"`
}

// MarshalJSON preserves the required empty text field of a text variant.
func (p AgentInputPart) MarshalJSON() ([]byte, error) {
	type part AgentInputPart
	raw, err := json.Marshal(part(p))
	if err != nil {
		return nil, err
	}
	if p.Kind != "text" {
		return raw, nil
	}
	object, err := DecodeObject(raw)
	if err != nil {
		return nil, err
	}
	object["text"] = p.Text
	return json.Marshal(object)
}
func ParsePublicAgentInput(data []byte) (AgentInput, error) {
	var result AgentInput
	if len(data) > 8*1024*1024 {
		return result, errors.New("Agent input exceeds 8 MiB")
	}
	value, err := Decode(data)
	if err != nil {
		return result, err
	}
	o, err := objectKeys(value, []string{"parts", "annotations", "presentation"}, []string{"parts"})
	if err != nil {
		return result, err
	}
	parts, err := checkArray(o["parts"])
	if err != nil || len(parts) < 1 || len(parts) > 128 {
		return result, errors.New("Agent input requires 1 to 128 parts")
	}
	meaningful := false
	for _, part := range parts {
		p, ok := part.(map[string]any)
		if !ok {
			return result, errors.New("invalid input part")
		}
		kind, ok := p["kind"].(string)
		if !ok {
			return result, errors.New("missing input part kind")
		}
		allowed := []string{"kind"}
		required := []string{"kind"}
		switch kind {
		case "text":
			allowed = append(allowed, "text", "annotationId")
			required = append(required, "text")
		case "local-file", "audio":
			allowed = append(allowed, "file")
			required = append(required, "file")
		case "image":
			allowed = append(allowed, "file", "detail")
			required = append(required, "file")
		case "image-url":
			allowed = append(allowed, "url", "detail")
			required = append(required, "url")
		case "audio-url":
			allowed = append(allowed, "url")
			required = append(required, "url")
		case "mention":
			allowed = append(allowed, "name", "path", "pathType")
			required = append(required, "name", "path")
		case "skill":
			allowed = append(allowed, "name", "path")
			required = append(required, "name", "path")
		default:
			return result, errors.New("invalid input part kind")
		}
		if _, err = objectKeys(p, allowed, required); err != nil {
			return result, err
		}
		if kind == "text" {
			if err = checkText(p["text"], 1000000, false); err != nil {
				return result, err
			}
			if strings.TrimSpace(p["text"].(string)) != "" {
				meaningful = true
			}
		} else {
			meaningful = true
		}
		if v, ok := p["annotationId"]; ok {
			if s, ok := v.(string); !ok || !uuidPattern.MatchString(s) {
				return result, errors.New("invalid annotation ID")
			}
		}
		if v, ok := p["file"]; ok {
			file, e := objectKeys(v, []string{"id"}, []string{"id"})
			if e != nil {
				return result, e
			}
			if id, ok := file["id"].(string); !ok || !uuidPattern.MatchString(id) {
				return result, errors.New("invalid attachment ID")
			}
		}
		if v, ok := p["detail"]; ok && !oneOf(v, "auto", "low", "high", "original") {
			return result, errors.New("invalid image detail")
		}
		if v, ok := p["url"]; ok {
			if err = checkText(v, 4000000, true); err != nil {
				return result, err
			}
			scheme, normalized, e := ParseAbsoluteURL(v.(string))
			if e != nil || !oneOf(scheme, "http", "https", "data") {
				return result, errors.New("invalid media URL")
			}
			p["url"] = normalized
		}
		for key, limit := range map[string]int{"name": 1024, "path": 4096} {
			if err = optionalText(p, key, limit, true); err != nil {
				return result, err
			}
		}
		if v, ok := p["pathType"]; ok && !oneOf(v, "file", "directory") {
			return result, errors.New("invalid mention path type")
		}
	}
	if !meaningful {
		return result, errors.New("消息不能为空")
	}
	if v, ok := o["presentation"]; ok && v != "visible" {
		return result, errors.New("invalid input presentation")
	}
	if v, ok := o["annotations"]; ok {
		if err = validateAnnotations(v); err != nil {
			return result, err
		}
	}
	normalized, err := json.Marshal(o)
	if err != nil {
		return result, err
	}
	err = Unmarshal(normalized, &result)
	return result, err
}
func validateAnnotations(value any) error {
	items, err := checkArray(value)
	if err != nil || len(items) > 20 {
		return errors.New("invalid browser annotations")
	}
	for _, item := range items {
		o, e := objectKeys(item, []string{"id", "comment", "url", "title", "kind", "rect", "viewport", "selector", "text", "screenshotId"}, []string{"id", "comment", "url", "title", "kind", "rect", "viewport"})
		if e != nil {
			return e
		}
		for _, key := range []string{"id", "screenshotId"} {
			if v, ok := o[key]; ok {
				if text, ok := v.(string); !ok || !uuidPattern.MatchString(text) {
					return fmt.Errorf("invalid annotation %s", key)
				}
			}
		}
		if comment, ok := o["comment"].(string); ok {
			o["comment"] = strings.TrimSpace(comment)
		}
		for key, limit := range map[string]int{"comment": 10000, "title": 2048, "selector": 4096, "text": 4000} {
			if v, ok := o[key]; ok {
				str, valid := v.(string)
				if !valid || UTF16Length(str) > limit || (key == "comment" && str == "") {
					return fmt.Errorf("invalid annotation %s", key)
				}
			}
		}
		text, ok := o["url"].(string)
		if !ok {
			return errors.New("invalid annotation URL")
		}
		scheme, normalized, e := ParseAbsoluteURL(text)
		if e != nil || !oneOf(scheme, "http", "https") {
			return errors.New("invalid annotation URL")
		}
		o["url"] = normalized
		if !oneOf(o["kind"], "element", "region") {
			return errors.New("invalid annotation kind")
		}
		for _, key := range []string{"rect", "viewport"} {
			fields := []string{"x", "y", "width", "height"}
			if key == "viewport" {
				fields = []string{"width", "height", "scrollX", "scrollY"}
			}
			coordinates, e := objectKeys(o[key], fields, fields)
			if e != nil {
				return e
			}
			for field, value := range coordinates {
				n, ok := number(value)
				if !ok {
					return errors.New("invalid annotation coordinate")
				}
				if field == "scrollX" || field == "scrollY" {
					continue
				}
				if n < 0 || n > 100000 || ((field == "width" || field == "height") && n == 0) {
					return errors.New("invalid annotation coordinate")
				}
			}
		}
	}
	return nil
}
