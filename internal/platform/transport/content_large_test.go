//go:build !race

package transport

import (
	"encoding/json"
	"testing"
)

// Race instrumentation makes decoding and re-encoding one million JSON numbers
// take minutes. The default suite still exercises the issue's exact frame-size
// fixture through the production publisher; race runs cover the same early-stop
// and fallback branches with smaller arrays.
func TestPublishMillionElementDenseUpdateFallsBackToSnapshot(t *testing.T) {
	fixture := newContentPublishFixture(t, denseDeltaValues(1_000_000, 0))
	first := fixture.publish(t)
	if first.Event.Type != "snapshot" || first.Event.Revision != 1 {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	fixture.set(t, denseDeltaValues(1_000_000, 1))
	second := fixture.publish(t)
	if second.Event.Type != "snapshot" || second.Event.Revision != 2 {
		t.Fatalf("million-element dense update did not fall back to snapshot: %+v", second.Event)
	}
	var values []any
	if err := json.Unmarshal(second.Event.Value, &values); err != nil || len(values) != 1_000_000 {
		t.Fatalf("dense snapshot did not contain the complete source value: %v", err)
	}
	if values[0] != float64(1) || values[len(values)-1] != float64(1) {
		t.Fatal("dense snapshot lost boundary elements")
	}
	if fixture.sub.revision != 2 || !fixture.sub.hasValue {
		t.Fatalf("fallback did not retain the subscription baseline: %+v", fixture.sub)
	}
}
