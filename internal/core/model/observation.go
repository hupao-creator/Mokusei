package model

import "encoding/json"

type PublicObservation struct {
	LatestExecution *PublicExecution      `json:"latestExecution"`
	BackgroundWork  *PublicBackgroundWork `json:"backgroundWork"`
}
type PublicBackgroundWork struct {
	Status string `json:"status"`
}
type PublicExecution struct {
	ExecutionID  string              `json:"executionId"`
	Status       string              `json:"status"`
	StartedAt    int64               `json:"startedAt"`
	Summary      *string             `json:"summary,omitempty"`
	FinishedAt   *int64              `json:"finishedAt,omitempty"`
	Error        *string             `json:"error,omitempty"`
	Interactions []PublicInteraction `json:"interactions,omitempty"`
}

func (e PublicExecution) Terminal() bool {
	return e.Status == "completed" || e.Status == "failed" || e.Status == "interrupted"
}

type PublicInteraction struct {
	ID          string                      `json:"id"`
	Kind        string                      `json:"kind"`
	Title       string                      `json:"title"`
	Description *string                     `json:"description,omitempty"`
	Actions     []PublicInteractionAction   `json:"actions"`
	Questions   []PublicInteractionQuestion `json:"questions"`
}
type PublicInteractionAction struct {
	ID     string `json:"id"`
	Intent string `json:"intent"`
	Label  string `json:"label"`
}
type PublicInteractionOption struct {
	Value       string  `json:"value"`
	Label       string  `json:"label"`
	Description *string `json:"description,omitempty"`
}
type PublicInteractionQuestion struct {
	ID           string                    `json:"id"`
	Prompt       string                    `json:"prompt"`
	Header       *string                   `json:"header,omitempty"`
	Multiple     bool                      `json:"multiple"`
	AllowOther   bool                      `json:"allowOther"`
	Secret       bool                      `json:"secret"`
	AnswerFormat string                    `json:"answerFormat,omitempty"`
	Form         *PublicQuestionForm       `json:"form,omitempty"`
	Options      []PublicInteractionOption `json:"options"`
}
type PublicQuestionCondition struct {
	QuestionID string          `json:"questionId"`
	Op         string          `json:"op"`
	Value      json.RawMessage `json:"value"`
}
type PublicQuestionForm struct {
	Type           string                    `json:"type"`
	Required       bool                      `json:"required"`
	Hidden         *bool                     `json:"hidden,omitempty"`
	Default        json.RawMessage           `json:"default,omitempty"`
	When           []PublicQuestionCondition `json:"when,omitempty"`
	OptionValues   map[string]string         `json:"optionValues,omitempty"`
	OptionIDPrefix string                    `json:"optionIdPrefix,omitempty"`
	Minimum        *float64                  `json:"minimum,omitempty"`
	Maximum        *float64                  `json:"maximum,omitempty"`
	MinLength      *int                      `json:"minLength,omitempty"`
	MaxLength      *int                      `json:"maxLength,omitempty"`
	Pattern        *string                   `json:"pattern,omitempty"`
	Format         string                    `json:"format,omitempty"`
	MinItems       *int                      `json:"minItems,omitempty"`
	MaxItems       *int                      `json:"maxItems,omitempty"`
}
type RespondRequest struct {
	ExecutionID   string                     `json:"executionId,omitempty"`
	InteractionID string                     `json:"interactionId"`
	ActionID      string                     `json:"actionId"`
	Answers       map[string]json.RawMessage `json:"answers,omitempty"`
	Message       string                     `json:"message,omitempty"`
	// Supplied only by trusted public-answer preflight; clients cannot inject
	// native values through the wire schema.
	ValidatedFormValues map[string]any `json:"-"`
}
type HarnessActivity struct {
	ExecutionID string `json:"executionId"`
	Sequence    int64  `json:"sequence"`
	Kind        string `json:"kind"`
	Text        string `json:"text,omitempty"`
	TextOffset  int64  `json:"textOffset,omitempty"`
	CallID      string `json:"callId,omitempty"`
	ToolName    string `json:"toolName,omitempty"`
}
