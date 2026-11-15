package transport

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func denseDeltaValues(count int, value int) []any {
	values := make([]any, count)
	for index := range values {
		values[index] = value
	}
	return values
}

func TestBoundedDeltaStopsDenseArrayBeforeBudget(t *testing.T) {
	// The issue's boundary fixture: one million changed array elements would
	// encode to a patch larger than the entire content frame.
	before := denseDeltaValues(1_000_000, 0)
	after := denseDeltaValues(1_000_000, 1)
	result := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: 64, MaxBytes: 1 << 20})
	if result.Complete || len(result.Operations) != 0 {
		t.Fatalf("dense diff was not discarded: complete=%t operations=%d", result.Complete, len(result.Operations))
	}
	// The first rejected candidate is the only work beyond the accepted
	// operations; the remaining array must not be diffed.
	if result.Examined > 65 {
		t.Fatalf("diff kept examining operations after its budget: %d", result.Examined)
	}
	if result.Bytes > 1<<20 {
		t.Fatalf("incomplete delta exceeded its byte budget: %d", result.Bytes)
	}
}

func TestProductionByteBudgetStopsMillionElementArray(t *testing.T) {
	before := denseDeltaValues(1_000_000, 0)
	after := denseDeltaValues(1_000_000, 1)
	raw, err := json.Marshal(before)
	if err != nil {
		t.Fatal(err)
	}
	result := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: maxDeltaOperations, MaxBytes: len(raw)})
	if result.Complete || len(result.Operations) != 0 {
		t.Fatalf("dense array did not fall back: %+v", result)
	}
	if result.Bytes > len(raw) {
		t.Fatalf("byte budget was exceeded: %d > %d", result.Bytes, len(raw))
	}
	if result.Examined >= maxDeltaOperations {
		t.Fatalf("operation safety valve stopped before the byte budget: %d", result.Examined)
	}
}

func TestBoundedDeltaRejectsOperationWhoseEncodingExceedsByteBudget(t *testing.T) {
	before := map[string]any{"text": "old"}
	after := map[string]any{"text": strings.Repeat("x", 4096)}
	result := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: 16, MaxBytes: 128})
	if result.Complete || len(result.Operations) != 0 || result.Examined != 1 {
		t.Fatalf("oversized operation was not rejected first: %+v", result)
	}
	// The builder must measure the complete operation before accepting it, so
	// the rejected candidate is not appended and only the empty array remains.
	if result.Bytes != 2 {
		t.Fatalf("rejected operation changed encoded array accounting: %d", result.Bytes)
	}
}

func TestBoundedDeltaKeepsSmallTextPatch(t *testing.T) {
	before := map[string]any{"text": "hello 😀"}
	after := map[string]any{"text": "hello 😃"}
	result := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: 16, MaxBytes: 1 << 10})
	if !result.Complete || result.Examined != 1 {
		t.Fatalf("small text patch did not complete: %+v", result)
	}
	expected := []map[string]any{{"op": "text", "path": []any{"text"}, "index": 6, "deleteCount": 2, "text": "😃"}}
	if !reflect.DeepEqual(result.Operations, expected) {
		t.Fatalf("unexpected text patch: %#v", result.Operations)
	}
	encoded, err := json.Marshal(result.Operations)
	if err != nil {
		t.Fatal(err)
	}
	if result.Bytes != len(encoded) {
		t.Fatalf("patch byte accounting=%d encoded=%d", result.Bytes, len(encoded))
	}
}

func TestCreateJSONDeltaUsesProductionBudget(t *testing.T) {
	if patch := CreateJSONDelta(denseDeltaValues(1_000_000, 0), denseDeltaValues(1_000_000, 1)); patch != nil {
		t.Fatalf("unbounded patch escaped the default production budget: %d operations", len(patch))
	}
	before := map[string]any{"text": "hello 😀"}
	after := map[string]any{"text": "hello 😃"}
	if patch := CreateJSONDelta(before, after); len(patch) != 1 {
		t.Fatalf("small fixture did not return its patch: %v", patch)
	}
}

func TestMinJSONValueBytesIsConservativeUnderEscaping(t *testing.T) {
	raw := []byte(`{"\u0061":"\u0062","control":"\n","unicode":"\u2028"}`)
	value, err := model.Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	minimum := minJSONValueBytes(value)
	if minimum > len(encoded) {
		t.Fatalf("lower bound %d exceeded encoded size %d", minimum, len(encoded))
	}
	if minimum >= len(raw) {
		t.Fatalf("escaped raw fixture did not exercise a lower bound: minimum=%d raw=%d", minimum, len(raw))
	}
}

func TestBoundedDeltaNoOpDoesNotNeedBudget(t *testing.T) {
	value := map[string]any{"rows": []any{map[string]any{"text": "same"}}}
	result := CreateBoundedJSONDelta(value, value, DeltaBudget{})
	if !result.Complete || result.Operations != nil || result.Examined != 0 || result.Bytes != 2 {
		t.Fatalf("no-op needed diff budget or lost its empty-array contract: %+v", result)
	}
}
