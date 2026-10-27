package model

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strings"
	"unicode/utf16"
)

const MaximumSafeInteger int64 = 9007199254740991

func UTF16Length(value string) int { return len(utf16.Encode([]rune(value))) }
func checkText(value any, maximum int, nonblank bool) error {
	text, ok := value.(string)
	if !ok || UTF16Length(text) > maximum || strings.ContainsRune(text, 0) || (nonblank && strings.TrimSpace(text) == "") {
		return errors.New("invalid text")
	}
	return nil
}

var publicIdentifierPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]*$`)

func checkIdentifier(value any) error {
	if err := checkText(value, 128, true); err != nil {
		return err
	}
	if !publicIdentifierPattern.MatchString(value.(string)) {
		return errors.New("invalid identifier")
	}
	return nil
}
func objectKeys(value any, allowed, required []string) (Object, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("expected object")
	}
	for key := range object {
		found := false
		for _, name := range allowed {
			if key == name {
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("unsupported field %s", key)
		}
	}
	for _, key := range required {
		if _, ok := object[key]; !ok {
			return nil, fmt.Errorf("missing field %s", key)
		}
	}
	return object, nil
}
func number(value any) (float64, bool) {
	switch n := value.(type) {
	case json.Number:
		v, e := n.Float64()
		return v, e == nil && !math.IsInf(v, 0) && !math.IsNaN(v)
	case float64:
		return n, !math.IsInf(n, 0) && !math.IsNaN(n)
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}
func oneOf(value any, values ...string) bool {
	v, ok := value.(string)
	if !ok {
		return false
	}
	for _, item := range values {
		if v == item {
			return true
		}
	}
	return false
}
func optionalText(o Object, key string, max int, nonblank bool) error {
	if value, ok := o[key]; ok {
		return checkText(value, max, nonblank)
	}
	return nil
}
func checkBoolean(value any) error {
	if _, ok := value.(bool); !ok {
		return errors.New("expected boolean")
	}
	return nil
}
func checkArray(value any) ([]any, error) {
	items, ok := value.([]any)
	if !ok {
		return nil, errors.New("expected array")
	}
	return items, nil
}

func ParsePublicObservation(data []byte) (PublicObservation, error) {
	var result PublicObservation
	value, err := Decode(data)
	if err != nil {
		return result, err
	}
	object, err := objectKeys(value, []string{"latestExecution", "backgroundWork"}, []string{"latestExecution", "backgroundWork"})
	if err != nil {
		return result, err
	}
	if value := object["latestExecution"]; value != nil {
		if err = validateExecutionObject(value); err != nil {
			return result, err
		}
	}
	if value := object["backgroundWork"]; value != nil {
		o, e := objectKeys(value, []string{"status"}, []string{"status"})
		if e != nil {
			return result, e
		}
		if o["status"] != "running" {
			return result, errors.New("invalid background work")
		}
	}
	err = Unmarshal(data, &result)
	return result, err
}
func ValidatePublicObservation(value PublicObservation) error {
	raw, err := Raw(value)
	if err != nil {
		return err
	}
	_, err = ParsePublicObservation(raw)
	return err
}
func ParsePublicExecution(data []byte) (PublicExecution, error) {
	var result PublicExecution
	value, err := Decode(data)
	if err != nil {
		return result, err
	}
	if err = validateExecutionObject(value); err != nil {
		return result, err
	}
	err = Unmarshal(data, &result)
	return result, err
}
func validateExecutionObject(value any) error {
	o, ok := value.(map[string]any)
	if !ok {
		return errors.New("invalid execution")
	}
	fields := []string{"executionId", "status", "startedAt", "summary"}
	required := []string{"executionId", "status", "startedAt"}
	switch o["status"] {
	case "running":
	case "waiting-for-user":
		fields = append(fields, "interactions")
		required = append(required, "interactions")
	case "completed", "interrupted":
		fields = append(fields, "finishedAt")
		required = append(required, "finishedAt")
	case "failed":
		fields = append(fields, "finishedAt", "error")
		required = append(required, "finishedAt")
	default:
		return errors.New("invalid execution status")
	}
	if _, err := objectKeys(o, fields, required); err != nil {
		return err
	}
	if err := checkIdentifier(o["executionId"]); err != nil {
		return err
	}
	start, ok := number(o["startedAt"])
	if !ok || start < 0 {
		return errors.New("invalid execution startedAt")
	}
	if finish, present := o["finishedAt"]; present {
		end, ok := number(finish)
		if !ok || end < start {
			return errors.New("invalid execution finishedAt")
		}
	}
	for _, key := range []string{"summary", "error"} {
		if err := optionalText(o, key, 100000, false); err != nil {
			return err
		}
	}
	if v, present := o["interactions"]; present {
		items, err := checkArray(v)
		if err != nil || len(items) == 0 {
			return errors.New("waiting execution requires interactions")
		}
		seen := map[string]bool{}
		for _, item := range items {
			if err := validateInteractionObject(item); err != nil {
				return err
			}
			id := item.(map[string]any)["id"].(string)
			if seen[id] {
				return errors.New("duplicate interaction ID")
			}
			seen[id] = true
		}
	}
	return nil
}
func validateInteractionObject(value any) error {
	o, err := objectKeys(value, []string{"id", "kind", "title", "description", "actions", "questions"}, []string{"id", "kind", "title", "actions", "questions"})
	if err != nil {
		return err
	}
	if err := checkIdentifier(o["id"]); err != nil {
		return err
	}
	if !oneOf(o["kind"], "permission", "question") {
		return errors.New("invalid interaction kind")
	}
	if err := checkText(o["title"], 2000, true); err != nil {
		return err
	}
	if err := optionalText(o, "description", 20000, false); err != nil {
		return err
	}
	actions, err := checkArray(o["actions"])
	if err != nil || len(actions) == 0 {
		return errors.New("interaction requires actions")
	}
	seen := map[string]bool{}
	for _, item := range actions {
		a, e := objectKeys(item, []string{"id", "intent", "label"}, []string{"id", "intent", "label"})
		if e != nil {
			return e
		}
		if e = checkIdentifier(a["id"]); e != nil {
			return e
		}
		if !oneOf(a["intent"], "allow", "deny", "submit", "cancel") {
			return errors.New("invalid interaction action intent")
		}
		if e = checkText(a["label"], 2000, true); e != nil {
			return e
		}
		id := a["id"].(string)
		if seen[id] {
			return errors.New("duplicate action ID")
		}
		seen[id] = true
	}
	questions, err := checkArray(o["questions"])
	if err != nil {
		return err
	}
	seen = map[string]bool{}
	for _, item := range questions {
		q, e := validateQuestionObject(item)
		if e != nil {
			return e
		}
		id := q["id"].(string)
		if seen[id] {
			return errors.New("duplicate question ID")
		}
		seen[id] = true
	}
	return nil
}
func validateQuestionObject(value any) (Object, error) {
	o, err := objectKeys(value, []string{"id", "prompt", "header", "multiple", "allowOther", "secret", "answerFormat", "form", "options"}, []string{"id", "prompt", "multiple", "allowOther", "secret", "options"})
	if err != nil {
		return nil, err
	}
	if err = checkIdentifier(o["id"]); err != nil {
		return nil, err
	}
	if err = checkText(o["prompt"], 20000, true); err != nil {
		return nil, err
	}
	if err = optionalText(o, "header", 2000, false); err != nil {
		return nil, err
	}
	for _, key := range []string{"multiple", "allowOther", "secret"} {
		if err = checkBoolean(o[key]); err != nil {
			return nil, err
		}
	}
	if v, present := o["answerFormat"]; present && v != "json-object" {
		return nil, errors.New("invalid answer format")
	}
	if v, present := o["form"]; present {
		if err = validateQuestionFormObject(v); err != nil {
			return nil, err
		}
	}
	options, err := checkArray(o["options"])
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, item := range options {
		a, e := objectKeys(item, []string{"value", "label", "description"}, []string{"value", "label"})
		if e != nil {
			return nil, e
		}
		for _, key := range []string{"value", "label"} {
			if e = checkText(a[key], 2000, true); e != nil {
				return nil, e
			}
		}
		if e = optionalText(a, "description", 10000, false); e != nil {
			return nil, e
		}
		id := a["value"].(string)
		if seen[id] {
			return nil, errors.New("duplicate option value")
		}
		seen[id] = true
	}
	return o, nil
}
func validateQuestionFormObject(value any) error {
	o, err := objectKeys(value, []string{"type", "required", "hidden", "default", "when", "optionValues", "optionIdPrefix", "minimum", "maximum", "minLength", "maxLength", "pattern", "format", "minItems", "maxItems"}, []string{"type", "required"})
	if err != nil {
		return err
	}
	if !oneOf(o["type"], "string", "number", "integer", "boolean", "multiselect", "external") {
		return errors.New("invalid form type")
	}
	if err = checkBoolean(o["required"]); err != nil {
		return err
	}
	if v, ok := o["hidden"]; ok {
		if err = checkBoolean(v); err != nil {
			return err
		}
	}
	if v, ok := o["default"]; ok {
		switch item := v.(type) {
		case string, bool, json.Number:
		case []any:
			for _, entry := range item {
				if _, ok := entry.(string); !ok {
					return errors.New("invalid form default")
				}
			}
		default:
			return errors.New("invalid form default")
		}
	}
	if v, ok := o["when"]; ok {
		items, e := checkArray(v)
		if e != nil {
			return e
		}
		for _, item := range items {
			c, e := objectKeys(item, []string{"questionId", "op", "value"}, []string{"questionId", "op", "value"})
			if e != nil {
				return e
			}
			if e = checkIdentifier(c["questionId"]); e != nil {
				return e
			}
			if !oneOf(c["op"], "eq", "neq") {
				return errors.New("invalid condition operation")
			}
			switch c["value"].(type) {
			case string, bool, json.Number:
			default:
				return errors.New("invalid condition value")
			}
		}
	}
	if v, ok := o["optionValues"]; ok {
		options, ok := v.(map[string]any)
		if !ok {
			return errors.New("invalid option values")
		}
		for _, entry := range options {
			if _, ok := entry.(string); !ok {
				return errors.New("invalid option value")
			}
		}
	}
	if err = optionalText(o, "optionIdPrefix", 128, true); err != nil {
		return err
	}
	for _, key := range []string{"minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"} {
		if v, ok := o[key]; ok {
			n, valid := number(v)
			if !valid {
				return fmt.Errorf("invalid %s", key)
			}
			if key != "minimum" && key != "maximum" && (n < 0 || math.Trunc(n) != n) {
				return fmt.Errorf("invalid %s", key)
			}
		}
	}
	if v, ok := o["pattern"]; ok {
		pattern, ok := v.(string)
		if !ok {
			return errors.New("invalid form pattern")
		}
		if err := ValidatePublicQuestionPattern(pattern); err != nil {
			return err
		}
	}
	if v, ok := o["format"]; ok && !oneOf(v, "email", "uri", "date", "date-time") {
		return errors.New("invalid form format")
	}
	return nil
}
