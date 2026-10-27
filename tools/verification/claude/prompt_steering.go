package main

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
)

func verifyPromptSteering(ctx context.Context, h *claude.Harness) {
	steering := plugin.NewPromptSteering()
	done := make(chan error, 1)
	go func() {
		result, err := h.Complete(ctx, plugin.PromptRequest{Steering: steering, Settings: json.RawMessage(`{"model":"claude-fixture","effort":"high"}`), Messages: []plugin.PromptMessage{{Role: "user", Content: "long isolated prompt"}}, OutputFormat: plugin.PromptOutputFormat{Type: "text"}})
		if err == nil && result.Output.Text != "answer" {
			err = errors.New("isolated completion did not use final assistant answer: " + result.Output.Text)
		}
		done <- err
	}()
	if err := steering.Send(ctx, "updated intent"); err != nil && !errors.Is(err, plugin.ErrPromptSettled) {
		must(err)
	}
	select {
	case err := <-done:
		must(err)
	case <-ctx.Done():
		must(ctx.Err())
	}
	if !errors.Is(steering.Send(ctx, "too late"), plugin.ErrPromptSettled) {
		panic("Claude accepted settled steer")
	}
}
