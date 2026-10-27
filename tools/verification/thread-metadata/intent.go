package main

import (
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func initialIntent() {
	input := model.AgentInput{Parts: []model.AgentInputPart{
		{Kind: "text", Text: "Preserve the original task intent. " + strings.Repeat("x", 600_000)},
		{Kind: "text", Text: strings.Repeat("y", 600_000)},
	}}
	raw, err := json.Marshal(input)
	must(err)
	_, err = model.ParsePublicAgentInput(raw)
	must(err)
	raw, err = (plugin.GeneratedThreadMetadata{}).Initialize("fixture", input, nil)
	must(err)
	var state struct {
		Initial model.AgentInput `json:"initialInput"`
		Recent  model.AgentInput `json:"recentInput"`
	}
	must(json.Unmarshal(raw, &state))
	check(len(state.Initial.Parts) == 1 && strings.HasPrefix(state.Initial.Parts[0].Text, "Preserve the original task intent."), "large first input lost its initial intent")
	check(model.UTF16Length(state.Initial.Parts[0].Text) == 6_000, "initial intent exceeded its text budget")
	check(len(input.Parts[0].Text) > 600_000 && len(input.Parts[1].Text) == 600_000, "metadata retention mutated caller input")
	check(len(state.Recent.Parts) == 2 && strings.HasPrefix(state.Recent.Parts[0].Text, "x") && len(state.Recent.Parts[1].Text) == 600_000, "recent intent no longer retained the input tail")

	input = model.AgentInput{Parts: []model.AgentInputPart{
		{Kind: "text", Text: "A" + strings.Repeat("😀", 3_000)},
		{Kind: "text", Text: "B😀"},
		{Kind: "image", Detail: "high", File: &model.InputFile{ID: "fixture-image", Name: "diagram.png", MimeType: "image/png", Size: 42}},
	}}
	raw, err = (plugin.GeneratedThreadMetadata{}).Initialize("fixture", input, nil)
	must(err)
	must(json.Unmarshal(raw, &state))
	check(len(state.Initial.Parts) == 3, "initial intent lost an attachment or the remaining text budget")
	check(state.Initial.Parts[0].Text == "A"+strings.Repeat("😀", 2_999) && state.Initial.Parts[1].Text == "B", "initial intent split a UTF-16 surrogate pair or lost the next part's budget")
	attachment := state.Initial.Parts[2]
	check(attachment.Kind == "image" && attachment.Detail == "high" && attachment.File != nil && *attachment.File == *input.Parts[2].File, "initial intent lost attachment metadata")
	check(input.Parts[0].Text == "A"+strings.Repeat("😀", 3_000) && input.Parts[1].Text == "B😀", "initial intent bounds mutated caller text")
}
