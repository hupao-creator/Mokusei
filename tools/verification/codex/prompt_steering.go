package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func verifyPromptSteering(ctx context.Context, adapter *codex.Adapter, binary string) error {
	steering := plugin.NewPromptSteering()
	done := make(chan error, 1)
	go func() {
		result, err := adapter.Complete(ctx, plugin.PromptRequest{Steering: steering, Settings: encoded(object{"executablePath": binary, "model": "gpt-6-luna", "effort": "low"}), Messages: []plugin.PromptMessage{{Role: "user", Content: "fixture-steer"}}, OutputFormat: plugin.PromptOutputFormat{Type: "text"}})
		if err == nil && result.Output.Text != "Steered fixture" {
			err = fmt.Errorf("isolated steer answer: %s", result.Output.Text)
		}
		done <- err
	}()
	if err := steering.Send(ctx, "updated isolated intent"); err != nil && !errors.Is(err, plugin.ErrPromptSettled) {
		return err
	}
	select {
	case err := <-done:
		if err != nil {
			return err
		}
	case <-ctx.Done():
		return ctx.Err()
	}
	if err := steering.Send(ctx, "too late"); !errors.Is(err, plugin.ErrPromptSettled) {
		return fmt.Errorf("settled completion accepted steer: %v", err)
	}
	if err := verifyPromptSteeringCancel(ctx, adapter, binary); err != nil {
		return err
	}
	fmt.Println("PASS synthetic isolated Prompt Completion native steer, terminal fencing and in-flight cancellation")
	return nil
}

func verifyPromptSteeringCancel(ctx context.Context, adapter *codex.Adapter, binary string) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	steering := plugin.NewPromptSteering()
	finished := make(chan error, 1)
	sent := make(chan error, 1)
	go func() {
		_, err := adapter.Complete(ctx, plugin.PromptRequest{Steering: steering, Settings: encoded(object{"executablePath": binary, "model": "gpt-6-luna", "effort": "low"}), Messages: []plugin.PromptMessage{{Role: "user", Content: "fixture-steer"}}, OutputFormat: plugin.PromptOutputFormat{Type: "text"}})
		finished <- err
	}()
	go func() { sent <- steering.Send(ctx, "fixture-pending-steer") }()
	marker := filepath.Join(filepath.Dir(binary), "pending-steer")
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
	cancel()
	select {
	case err := <-sent:
		if err == nil {
			return fmt.Errorf("cancelled native steer succeeded")
		}
	case <-time.After(2 * time.Second):
		return fmt.Errorf("native steer ignored cancellation")
	}
	select {
	case err := <-finished:
		if err == nil {
			return fmt.Errorf("cancelled completion succeeded")
		}
	case <-time.After(4 * time.Second):
		return fmt.Errorf("completion did not drain cancelled steer")
	}
	return nil
}
