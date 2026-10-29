package moku

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestTimerRegisteredBindingAndAudit(t *testing.T) {
	for _, name := range []string{"timer", "talk"} {
		t.Run(name, func(t *testing.T) {
			_, record, coordinator := clipboardToolFixture(t, nil)
			var binding plugin.ToolBinding
			for _, candidate := range coordinator.tools(record.ID, ThreadCreationDescription{}) {
				if candidate.Name == name {
					binding = candidate
				}
			}
			if binding.Execute == nil {
				t.Fatal("missing communication binding")
			}
			if name == "timer" && (!strings.Contains(binding.Description, TimerTextPolicy) || !strings.Contains(DefaultSystemPrompt(), TimerTextPolicy)) {
				t.Fatal("timer tool and system prompt policy drifted")
			}
			for _, text := range []string{"  exact\ntext  ", strings.Repeat("😀", 160), strings.Repeat("e\u0301", 80), "\u0085visible\uFEFF"} {
				args, _ := json.Marshal(map[string]string{"text": text})
				result, err := binding.Execute(context.Background(), plugin.ToolCall{CallID: "native-call", Arguments: args})
				if err != nil || string(result) != `{"ok":true}` {
					t.Fatalf("communication failed: %s, %v", result, err)
				}
				var item struct {
					Name      string `json:"name"`
					Arguments struct {
						Text string `json:"text"`
					} `json:"arguments"`
					Result struct {
						OK bool `json:"ok"`
					} `json:"result"`
					CompletedAt int64 `json:"completedAt"`
					IsError     bool  `json:"isError"`
				}
				if err := json.Unmarshal(record.Transcript[len(record.Transcript)-1], &item); err != nil {
					t.Fatal(err)
				}
				if item.Name != name || item.Arguments.Text != text || !item.Result.OK || item.CompletedAt == 0 || item.IsError {
					t.Fatalf("incomplete or altered audit: %+v", item)
				}
			}
			for _, args := range []string{`{}`, `{"text":null}`, `{"text":12}`, `{"text":""}`, `{"text":" \n\u0085\uFEFF"}`, `{"text":"a\u0000b"}`, `{"text":"event","after":1}`, `{"text":"event","at":"2026-10-29T00:00:00Z"}`} {
				if _, err := binding.Execute(context.Background(), plugin.ToolCall{Arguments: json.RawMessage(args)}); err == nil {
					t.Fatalf("invalid input accepted: %s", args)
				}
			}
			for _, text := range []string{strings.Repeat("😀", 161), strings.Repeat("e\u0301", 81)} {
				args, _ := json.Marshal(map[string]string{"text": text})
				if _, err := binding.Execute(context.Background(), plugin.ToolCall{Arguments: args}); err == nil {
					t.Fatal("oversized input accepted")
				}
			}
		})
	}
}

func TestTimerDoesNotReportSuccessWhenAuditFails(t *testing.T) {
	_, record, coordinator := clipboardToolFixture(t, nil)
	var binding plugin.ToolBinding
	for _, candidate := range coordinator.tools(record.ID, ThreadCreationDescription{}) {
		if candidate.Name == "timer" {
			binding = candidate
		}
	}
	original := coordinator.config.UpdateThread
	calls := 0
	coordinator.config.UpdateThread = func(ctx context.Context, id string, update func(*model.ThreadRecord) error) error {
		calls++
		if calls == 2 {
			return errors.New("completion write failed")
		}
		return original(ctx, id, update)
	}
	result, err := binding.Execute(context.Background(), plugin.ToolCall{Arguments: json.RawMessage(`{"text":"ready"}`)})
	if err == nil || result != nil || !strings.Contains(err.Error(), "completion write failed") {
		t.Fatalf("false success: %s, %v", result, err)
	}
	if len(record.Transcript) != 1 || strings.Contains(string(record.Transcript[0]), "completedAt") {
		t.Fatalf("failed completion became deliverable: %s", record.Transcript)
	}
}
