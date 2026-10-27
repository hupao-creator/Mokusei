package background

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
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

func TestEventEvidenceAddsBoundedInputExcerpt(t *testing.T) {
	text := strings.Repeat("分类", 700)
	data, err := json.Marshal(map[string]any{"parts": []any{map[string]any{"kind": "text", "text": text}}})
	if err != nil {
		t.Fatal(err)
	}
	rows := EventEvidence([]plugin.LifecycleEvent{{ID: "event", Type: "thread.input-accepted", Data: data}})
	excerpt, _ := rows[0]["excerpt"].(string)
	if !strings.HasPrefix(excerpt, "分类分类") || !strings.HasSuffix(excerpt, "…") {
		t.Fatalf("excerpt = %q", excerpt)
	}
	if len([]rune(excerpt)) != eventExcerptLimit+1 {
		t.Fatalf("excerpt length = %d", len([]rune(excerpt)))
	}
}

func TestEventEvidenceUsesInventoryTitle(t *testing.T) {
	rows := EventEvidence([]plugin.LifecycleEvent{{ID: "event", Type: "thread.inventory", Data: json.RawMessage(`{"title":"修复粘贴预览"}`)}})
	if rows[0]["excerpt"] != "修复粘贴预览" {
		t.Fatalf("excerpt = %v", rows[0]["excerpt"])
	}
}

func TestEventEvidenceStopsAtTotalBudget(t *testing.T) {
	data := json.RawMessage(`{"title":"` + strings.Repeat("a", eventExcerptLimit) + `"}`)
	events := []plugin.LifecycleEvent{}
	for i := 0; i < eventExcerptTotal/eventExcerptLimit+1; i++ {
		events = append(events, plugin.LifecycleEvent{ID: "event", Type: "thread.inventory", Data: data})
	}
	rows := EventEvidence(events)
	withExcerpt := 0
	for _, row := range rows {
		if _, ok := row["excerpt"]; ok {
			withExcerpt++
		}
	}
	if withExcerpt != eventExcerptTotal/eventExcerptLimit {
		t.Fatalf("excerpted events = %d", withExcerpt)
	}
	if _, ok := rows[withExcerpt]["excerpt"]; ok {
		t.Fatalf("event beyond the total budget received an excerpt")
	}
}
