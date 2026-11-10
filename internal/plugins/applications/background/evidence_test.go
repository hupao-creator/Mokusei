package background

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestLifecycleEvidenceStopsPagingAfterCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	reads := 0
	consumer := runnerTestHistory{read: func(plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error) {
		reads++
		if reads == 1 {
			cancel()
			return plugin.Page[plugin.LifecycleHistoryEntry]{NextCursor: "1"}, nil
		}
		return plugin.Page[plugin.LifecycleHistoryEntry]{}, nil
	}}
	runner := &Runner{consumer: consumer}
	for _, tool := range EvidenceTools(t.Context(), nil, runner) {
		if tool.Name != "read_lifecycle_events" {
			continue
		}
		if _, err := tool.Execute(ctx, plugin.ToolCall{Arguments: json.RawMessage(`{}`)}); !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled evidence call returned %v", err)
		}
		if reads != 1 {
			t.Fatalf("canceled evidence call read %d pages", reads)
		}
		return
	}
	t.Fatal("lifecycle evidence tool is missing")
}

type runnerTestHistory struct {
	runnerTestConsumer
	read func(plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error)
}

func (c runnerTestHistory) Read(query plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error) {
	return c.read(query)
}
