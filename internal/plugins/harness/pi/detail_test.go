package pi

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func TestReaderDetailKeepsThinkingAndMessageIdentitiesDistinct(t *testing.T) {
	const executionID = "execution"
	state := State{Version: 1, Messages: []MessageState{
		{ID: "foo", ExecutionID: executionID, Role: "assistant", Text: "reply", Thinking: "reasoning", Status: "complete"},
		{ID: "foo:thinking", ExecutionID: executionID, Role: "assistant", Text: "literal", Status: "complete"},
	}, Executions: []model.PublicExecution{{ExecutionID: executionID, Status: "completed", StartedAt: 1, FinishedAt: executionPointer[int64](2)}},
		LatestExecutionID: executionPointer(executionID)}
	raw := mustJSON(t, state)
	adapter := stateAdapter{}
	thinkingID := "\x00pi:thinking:foo"
	projection, err := adapter.ProjectDetail(raw, model.DetailRequest{ExecutionID: executionID,
		Items: []string{thinkingID, "foo", "foo:thinking", "\x00pi:execution-error"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.Items) != 3 {
		t.Fatalf("selected identities = %+v", projection.Items)
	}
	if projection.Items[0].ID != thinkingID || projection.Items[0].Kind != "reasoning" {
		t.Fatalf("thinking item = %+v", projection.Items[0])
	}
	if projection.Items[1].ID != "foo" || projection.Items[2].ID != "foo:thinking" {
		t.Fatalf("literal identities changed = %+v", projection.Items)
	}
	if body, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: executionID, ItemID: thinkingID, Slot: "thinking"}); err != nil || body.Text != "reasoning" {
		t.Fatalf("thinking body = %q, %v", body.Text, err)
	}
	if body, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: executionID, ItemID: "foo:thinking", Slot: "text"}); err != nil || body.Text != "literal" {
		t.Fatalf("literal body = %q, %v", body.Text, err)
	}
	if _, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: executionID, ItemID: "\x00pi:execution-error", Slot: "detail"}); err == nil {
		t.Fatal("execution error remained an unreachable detail resource")
	}
}

func TestReaderDetailBoundsOverlongNativeIdentities(t *testing.T) {
	const executionID = "execution"
	short := strings.Repeat("a", model.MaximumContentIdentityUnits-len("\x00pi:thinking:"))
	long := short + "a"
	overlong := strings.Repeat("m", model.MaximumContentIdentityUnits+1)
	state := State{Version: 1, Messages: []MessageState{
		{ID: short, ExecutionID: executionID, Role: "assistant", Text: "short text", Thinking: "short thinking", Status: "complete"},
		{ID: long, ExecutionID: executionID, Role: "assistant", Text: "long text", Thinking: "long thinking", Status: "complete"},
		{ID: overlong, ExecutionID: executionID, Role: "assistant", Text: "overlong text", Status: "complete"},
	}, Executions: []model.PublicExecution{{ExecutionID: executionID, Status: "completed", StartedAt: 1, FinishedAt: executionPointer[int64](2)}},
		LatestExecutionID: executionPointer(executionID)}
	raw := mustJSON(t, state)
	digest := func(value string) string {
		sum := sha256.Sum256([]byte(value))
		return hex.EncodeToString(sum[:])
	}
	thinkingLong := "\x00pi:thinking:" + digest(long)
	messageOverlong := "\x00pi:message:" + digest(overlong)
	if thinkingLong != piThinkingID(long) || messageOverlong != piMessageRowID(overlong) {
		t.Fatalf("bounded identities = %q %q", piThinkingID(long), piMessageRowID(overlong))
	}
	if utf16Length(piThinkingID(short)) != model.MaximumContentIdentityUnits {
		t.Fatalf("thinking identity at the boundary = %d units", utf16Length(piThinkingID(short)))
	}
	adapter := stateAdapter{}
	projection, err := adapter.ProjectDetail(raw, model.DetailRequest{ExecutionID: executionID,
		Items: []string{piThinkingID(short), short, thinkingLong, long, messageOverlong}})
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.Items) != 5 {
		t.Fatalf("long identity selection = %+v", projection.Items)
	}
	for _, item := range projection.Items {
		if utf16Length(item.ID) > model.MaximumContentIdentityUnits {
			t.Fatalf("detail identity exceeded the transport bound: %d", utf16Length(item.ID))
		}
	}
	if projection.Items[0].ID != piThinkingID(short) || projection.Items[1].ID != short {
		t.Fatalf("boundary identities changed = %+v", projection.Items[:2])
	}
	if projection.Items[2].ID != thinkingLong || projection.Items[3].ID != long || projection.Items[4].ID != messageOverlong {
		t.Fatalf("overlong identities changed = %+v", projection.Items[2:])
	}
	for itemID, expected := range map[string][2]string{
		thinkingLong:    {"thinking", "long thinking"},
		messageOverlong: {"text", "overlong text"},
	} {
		body, err := adapter.ReadDetailBody(raw, model.DetailBodyRequest{ExecutionID: executionID, ItemID: itemID, Slot: expected[0]})
		if err != nil || body.Text != expected[1] {
			t.Fatalf("bounded body %q = %q, %v", itemID, body.Text, err)
		}
	}
}

func executionPointer[T any](value T) *T { return &value }
