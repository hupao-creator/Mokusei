package model

import "encoding/json"

// The wire protocol uses discriminated unions. Their required fields must not
// disappear merely because Go considers a false, zero or empty value omitted.
func (value ThinkingCapability) MarshalJSON() ([]byte, error) {
	switch value.Kind {
	case "effort":
		efforts := value.Efforts
		if efforts == nil {
			efforts = []string{}
		}
		return json.Marshal(struct {
			Kind       string   `json:"kind"`
			Efforts    []string `json:"efforts"`
			CanDisable bool     `json:"canDisable"`
		}{value.Kind, efforts, value.CanDisable})
	case "unknown":
		return json.Marshal(struct {
			Kind   string `json:"kind"`
			Reason string `json:"reason"`
		}{value.Kind, value.Reason})
	default:
		return json.Marshal(struct {
			Kind string `json:"kind"`
		}{value.Kind})
	}
}
func (value ThreadRecord) MarshalJSON() ([]byte, error) {
	type record ThreadRecord
	if !value.Moku {
		return json.Marshal(record(value))
	}
	// Moku has a required transcript even before its first message.
	raw, err := json.Marshal(record(value))
	if err != nil {
		return nil, err
	}
	object, err := DecodeObject(raw)
	if err != nil {
		return nil, err
	}
	transcript := value.Transcript
	if transcript == nil {
		transcript = []json.RawMessage{}
	}
	object["transcript"] = transcript
	return json.Marshal(object)
}
func (value PublicInteraction) MarshalJSON() ([]byte, error) {
	type interaction PublicInteraction
	if value.Questions == nil {
		value.Questions = []PublicInteractionQuestion{}
	}
	if value.Actions == nil {
		value.Actions = []PublicInteractionAction{}
	}
	return json.Marshal(interaction(value))
}
func (value PublicInteractionQuestion) MarshalJSON() ([]byte, error) {
	type question PublicInteractionQuestion
	if value.Options == nil {
		value.Options = []PublicInteractionOption{}
	}
	return json.Marshal(question(value))
}
func (value HarnessActivity) MarshalJSON() ([]byte, error) {
	type activity HarnessActivity
	raw, err := json.Marshal(activity(value))
	if err != nil {
		return nil, err
	}
	if value.Kind != "reasoning" {
		return raw, nil
	}
	object, err := DecodeObject(raw)
	if err != nil {
		return nil, err
	}
	object["text"] = value.Text
	return json.Marshal(object)
}
