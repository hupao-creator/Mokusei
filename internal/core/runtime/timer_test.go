package runtime

import (
	"encoding/json"
	"fmt"
	"testing"
)

func TestTimerAuditSurvivesSuccessorBeforeCatalogPublication(t *testing.T) {
	items := []json.RawMessage{}
	for i := range 260 {
		items = append(items, json.RawMessage(fmt.Sprintf(`{"type":"tool-operation","id":"timer-%d","executionId":"old","name":"timer","completedAt":2,"arguments":{"text":"ready"},"result":{"ok":true}}`, i)))
	}
	items = append(items,
		json.RawMessage(`{"type":"tool-operation","id":"failed","executionId":"old","name":"timer","completedAt":2,"isError":true,"result":{"ok":false}}`),
		json.RawMessage(`{"type":"tool-operation","id":"talk","executionId":"old","name":"talk","completedAt":2,"result":{"ok":true}}`),
		json.RawMessage(`{"type":"tool-operation","id":"pending","executionId":"old","name":"timer","result":{"ok":true}}`),
		json.RawMessage(`{"type":"message","id":"new","executionId":"successor","role":"user","content":"next"}`))
	preview := auditPreview(items)
	if len(preview) != 257 {
		t.Fatalf("catalog catch-up tail size = %d", len(preview))
	}
	for i, raw := range preview[:256] {
		var row struct {
			ID        string `json:"id"`
			Arguments struct {
				Text string `json:"text"`
			} `json:"arguments"`
			Result struct {
				OK bool `json:"ok"`
			} `json:"result"`
		}
		if err := json.Unmarshal(raw, &row); err != nil {
			t.Fatal(err)
		}
		if row.ID != fmt.Sprintf("timer-%d", i+4) || row.Arguments.Text != "ready" || !row.Result.OK {
			t.Fatalf("timer order, text or success lost: %s", raw)
		}
	}
}
