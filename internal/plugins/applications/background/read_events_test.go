package background

import (
	"context"
	"errors"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestReadEventsStopsPagingAfterCancellation(t *testing.T) {
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
	if _, err := runner.ReadEvents(ctx, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled evidence read returned %v", err)
	}
	if reads != 1 {
		t.Fatalf("canceled evidence read fetched %d pages", reads)
	}
}

type runnerTestHistory struct {
	runnerTestConsumer
	read func(plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error)
}

func (c runnerTestHistory) Read(query plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error) {
	return c.read(query)
}
