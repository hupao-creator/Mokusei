package opencode

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func opaque(prefix string, parts ...string) string {
	raw, _ := json.Marshal(append([]string{"mokusei.opencode.public-interaction.v2"}, parts...))
	sum := sha256.Sum256(raw)
	return "opencode-" + prefix + "-" + hex.EncodeToString(sum[:])
}
func interactionID(v *Interaction) string { return opaque("interaction", v.ExecutionID, v.ID) }
func questionID(v *Interaction, key string) string {
	return opaque("question", v.ExecutionID, v.ID, key)
}
func optionID(v *Interaction, key, value string) string {
	return opaque("option", v.ExecutionID, v.ID, key, value)
}
func stringList(v any) ([]string, error) {
	out := []string{}
	values, ok := v.([]any)
	if !ok {
		if strs, ok := v.([]string); ok {
			return strs, nil
		}
		return nil, errors.New("expected string array")
	}
	for _, value := range values {
		s, ok := value.(string)
		if !ok {
			return nil, errors.New("expected string")
		}
		out = append(out, s)
	}
	return out, nil
}
func parsePermission(value Object, execution string) (*Interaction, error) {
	action, id, session := str(value["action"]), str(value["id"]), str(value["sessionID"])
	if action == "" || id == "" || session == "" {
		return nil, errors.New("invalid OpenCode permission")
	}
	resources, err := stringList(value["resources"])
	if err != nil {
		return nil, err
	}
	var save []string
	if value["save"] != nil {
		save, err = stringList(value["save"])
		if err != nil {
			return nil, err
		}
	}
	description := strings.TrimSpace(strings.Join(append([]string{str(value["message"])}, resources...), "\n"))
	return &Interaction{ID: id, ExecutionID: execution, SessionID: session, Kind: "permission", Title: "Allow " + action + "?", Status: "pending", Action: action, Resources: resources, Save: save, Description: description, Metadata: object(value["metadata"])}, nil
}
func parseForm(value Object, execution string) (*Interaction, error) {
	title, validTitle := value["title"].(string)
	v := &Interaction{ID: str(value["id"]), ExecutionID: execution, SessionID: str(value["sessionID"]), Kind: "form", Title: title, Status: "pending", Metadata: object(value["metadata"])}
	if v.ID == "" || v.SessionID == "" || !validTitle {
		return nil, errors.New("invalid OpenCode form")
	}
	if v.Title == "" {
		v.Title = "OpenCode request"
	}
	for _, field := range array(value["fields"]) {
		v.Fields = append(v.Fields, object(field))
	}
	if err := ValidateFields(v.Fields); err != nil {
		return nil, err
	}
	return v, nil
}
func ValidateFields(fields []Object) error {
	if len(fields) == 0 {
		return errors.New("OpenCode form has no fields")
	}
	earlier := map[string]Object{}
	common := []string{"key", "title", "description", "required", "hidden", "when", "type", "default"}
	extra := map[string][]string{"string": {"format", "minLength", "maxLength", "pattern", "placeholder", "options", "custom"}, "number": {"minimum", "maximum"}, "integer": {"minimum", "maximum"}, "boolean": {}, "multiselect": {"options", "minItems", "maxItems", "custom"}, "external": {"url"}}
	for _, field := range fields {
		key, kind := str(field["key"]), str(field["type"])
		if key == "" || strings.ContainsRune(key, 0) || earlier[key] != nil {
			return errors.New("invalid or duplicate OpenCode field key")
		}
		keys, ok := extra[kind]
		if !ok {
			return fmt.Errorf("unsupported OpenCode form field %s", kind)
		}
		allowed := append(append([]string{}, common...), keys...)
		if kind == "external" {
			allowed = []string{"key", "title", "description", "type", "url"}
		}
		for k := range field {
			if !slices.Contains(allowed, k) {
				return fmt.Errorf("unsupported OpenCode field property %s", k)
			}
		}
		for _, k := range []string{"title", "description", "pattern", "placeholder"} {
			if value, ok := field[k]; ok {
				if _, ok = value.(string); !ok {
					return fmt.Errorf("invalid field %s", k)
				}
			}
		}
		for _, k := range []string{"required", "hidden", "custom"} {
			if value, ok := field[k]; ok {
				if _, ok = value.(bool); !ok {
					return fmt.Errorf("invalid field %s", k)
				}
			}
		}
		for _, k := range []string{"minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"} {
			if value, ok := field[k]; ok {
				n, ok := value.(float64)
				if !ok || math.IsNaN(n) || math.IsInf(n, 0) || (k != "minimum" && k != "maximum" && (n < 0 || math.Trunc(n) != n)) {
					return fmt.Errorf("invalid field %s", k)
				}
			}
		}
		if f := str(field["format"]); f != "" && !slices.Contains([]string{"email", "uri", "date", "date-time"}, f) {
			return errors.New("unsupported form field format")
		}
		if pattern := str(field["pattern"]); pattern != "" {
			if err := model.ValidatePublicQuestionPattern(pattern); err != nil {
				return fmt.Errorf("unsupported OpenCode form pattern: %w", err)
			}
		}
		if kind == "external" {
			_, _, err := model.ParseAbsoluteURL(str(field["url"]))
			if err != nil {
				return errors.New("invalid external form URL")
			}
		}
		options := map[string]bool{}
		if values, ok := field["options"]; ok {
			arr, ok := values.([]any)
			if !ok {
				return errors.New("invalid form options")
			}
			for _, v := range arr {
				o := object(v)
				value, ok := o["value"].(string)
				if !ok || options[value] {
					return errors.New("invalid or duplicate form option")
				}
				if _, ok := o["label"].(string); !ok {
					return errors.New("invalid form option label")
				}
				for k := range o {
					if k != "value" && k != "label" && k != "description" {
						return errors.New("unsupported form option property")
					}
				}
				if description, exists := o["description"]; exists {
					if _, ok := description.(string); !ok {
						return errors.New("invalid option description")
					}
				}
				options[value] = true
			}
		} else if kind == "multiselect" {
			return errors.New("multiselect requires options")
		}
		if conditions, exists := field["when"]; exists {
			if _, ok := conditions.([]any); !ok {
				return errors.New("invalid OpenCode form conditions")
			}
		}
		for _, v := range array(field["when"]) {
			c := object(v)
			target := earlier[str(c["key"])]
			if target == nil || target["type"] == "external" || (c["op"] != "eq" && c["op"] != "neq") {
				return errors.New("form condition must reference earlier input")
			}
			for k := range c {
				if k != "key" && k != "op" && k != "value" {
					return errors.New("unsupported form condition")
				}
			}
			switch str(target["type"]) {
			case "boolean":
				if _, ok := c["value"].(bool); !ok {
					return errors.New("invalid boolean condition")
				}
			case "number", "integer":
				if _, ok := c["value"].(float64); !ok {
					return errors.New("invalid number condition")
				}
			default:
				if _, ok := c["value"].(string); !ok {
					return errors.New("invalid string condition")
				}
				if target["options"] != nil && target["custom"] != true {
					found := false
					for _, option := range fieldOptions(target) {
						if option["value"] == c["value"] {
							found = true
						}
					}
					if !found {
						return errors.New("unknown OpenCode conditional option")
					}
				}
			}
		}
		if value, ok := field["default"]; ok {
			if err := validateField(field, value); err != nil {
				return err
			}
		}
		earlier[key] = field
	}
	return nil
}
func fieldOptions(field Object) []Object {
	switch field["type"] {
	case "external":
		return []Object{{"value": "true", "label": "I have completed this step"}}
	case "boolean":
		return []Object{{"value": "true", "label": "Yes"}, {"value": "false", "label": "No"}}
	}
	out := []Object{}
	for _, v := range array(field["options"]) {
		out = append(out, object(v))
	}
	return out
}
func publicInteraction(v *Interaction) model.PublicInteraction {
	out := model.PublicInteraction{ID: interactionID(v), Kind: "question", Title: v.Title, Actions: []model.PublicInteractionAction{}, Questions: []model.PublicInteractionQuestion{}}
	if v.Description != "" {
		description := v.Description
		out.Description = &description
	}
	if v.Kind == "permission" {
		out.Kind = "permission"
		out.Actions = append(out.Actions, model.PublicInteractionAction{ID: "allow", Intent: "allow", Label: "Allow once"})
		if len(v.Save) > 0 {
			out.Actions = append(out.Actions, model.PublicInteractionAction{ID: "allow-session", Intent: "allow", Label: "Allow for this session"})
		}
		out.Actions = append(out.Actions, model.PublicInteractionAction{ID: "deny", Intent: "deny", Label: "Deny"})
		return out
	}
	out.Actions = []model.PublicInteractionAction{{ID: "submit", Intent: "submit", Label: "Submit"}, {ID: "cancel", Intent: "cancel", Label: "Cancel"}}
	for _, f := range v.Fields {
		key, kind := str(f["key"]), str(f["type"])
		prompt := str(f["title"])
		if prompt == "" {
			prompt = key
		}
		if description := str(f["description"]); description != "" {
			prompt += "\n" + description
		}
		if kind == "external" {
			prompt += "\n" + str(f["url"])
		}
		encoded, _ := json.Marshal(f)
		form := &model.PublicQuestionForm{}
		_ = json.Unmarshal(encoded, form)
		form.OptionIDPrefix = "opencode-option-"
		if kind == "external" {
			form.Required = true
		}
		form.When = nil
		for _, raw := range array(f["when"]) {
			c := object(raw)
			value, _ := json.Marshal(c["value"])
			form.When = append(form.When, model.PublicQuestionCondition{QuestionID: questionID(v, str(c["key"])), Op: str(c["op"]), Value: value})
		}
		q := model.PublicInteractionQuestion{ID: questionID(v, key), Prompt: prompt, Multiple: kind == "multiselect", AllowOther: kind != "boolean" && kind != "external", Options: []model.PublicInteractionOption{}, Form: form}
		if kind == "string" && f["options"] != nil || kind == "multiselect" {
			q.AllowOther = f["custom"] == true
		}
		options := fieldOptions(f)
		if len(options) > 0 || f["options"] != nil {
			form.OptionValues = map[string]string{}
		}
		for _, o := range options {
			id := optionID(v, key, str(o["value"]))
			form.OptionValues[id] = str(o["value"])
			option := model.PublicInteractionOption{Value: id, Label: str(o["label"])}
			if s := str(o["description"]); s != "" {
				option.Description = &s
			}
			q.Options = append(q.Options, option)
		}
		out.Questions = append(out.Questions, q)
	}
	return out
}
func validateField(f Object, value any) error {
	kind, key := str(f["type"]), str(f["key"])
	bad := func(reason string) error { return fmt.Errorf("invalid OpenCode field %s: %s", key, reason) }
	switch kind {
	case "string":
		text, ok := value.(string)
		if !ok {
			return bad("expected text")
		}
		encoded, err := json.Marshal(f)
		if err != nil {
			return err
		}
		var form model.PublicQuestionForm
		if err := json.Unmarshal(encoded, &form); err != nil {
			return err
		}
		if reason := model.ValidatePublicQuestionString(form, text); reason != "" {
			return bad(reason)
		}
		if f["options"] != nil && f["custom"] != true {
			found := false
			for _, o := range fieldOptions(f) {
				if o["value"] == text {
					found = true
				}
			}
			if !found {
				return bad("unknown option")
			}
		}
	case "number", "integer":
		n, ok := value.(float64)
		if !ok || math.IsNaN(n) || math.IsInf(n, 0) || (kind == "integer" && math.Trunc(n) != n) {
			return bad("invalid number")
		}
		if f["minimum"] != nil && n < number(f["minimum"]) || f["maximum"] != nil && n > number(f["maximum"]) {
			return bad("outside bounds")
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return bad("expected boolean")
		}
	case "multiselect":
		values, err := stringList(value)
		if err != nil {
			return bad("expected multiple choices")
		}
		if f["minItems"] != nil && float64(len(values)) < number(f["minItems"]) || f["maxItems"] != nil && float64(len(values)) > number(f["maxItems"]) {
			return bad("choice count outside bounds")
		}
		seen := map[string]bool{}
		for _, v := range values {
			if seen[v] {
				return bad("duplicate choice")
			}
			seen[v] = true
			if f["custom"] != true {
				found := false
				for _, o := range fieldOptions(f) {
					if o["value"] == v {
						found = true
					}
				}
				if !found {
					return bad("unknown option")
				}
			}
		}
	case "external":
		if value != true {
			return bad("external step must be acknowledged")
		}
	default:
		return bad("unsupported type")
	}
	return nil
}
func formAnswers(v *Interaction, request model.RespondRequest) (Object, error) {
	values := request.ValidatedFormValues
	if values == nil {
		// Standalone adapter callers enter the same public boundary as Runtime.
		checked := model.ValidatePublicInteractionAnswers(publicInteraction(v), request.Answers)
		if !checked.Valid {
			return nil, fmt.Errorf("invalid OpenCode answers: %v", checked.Errors)
		}
		values = checked.ValidatedFormValues
	}
	answers := Object{}
	for _, field := range v.Fields {
		key := str(field["key"])
		if value, present := values[questionID(v, key)]; present {
			answers[key] = value
		}
	}
	return answers, nil
}
