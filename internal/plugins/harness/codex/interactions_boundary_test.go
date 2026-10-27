package codex

import "testing"

func TestRequestUserInputPreservesBlocking(t *testing.T) {
	for _, blocking := range []bool{false, true} {
		interaction, err := ParseInteraction("item/tool/requestUserInput", Map{"interactionId": "question", "isBlocking": blocking, "questions": []any{Map{"id": "choice", "question": "Choose", "options": []any{Map{"label": "A"}}}}})
		if err != nil {
			t.Fatal(err)
		}
		state := StageExecution(EmptyState(1), "execution", Map{"parts": []any{Map{"kind": "text", "text": "hello"}}}, 2, nil)
		state = ReduceEvent(state, "execution", Map{"type": "interaction-opened", "interaction": interaction, "at": 3})
		if _, err := DecodeState(state); err != nil {
			t.Fatal(err)
		}
		want := "running"
		if blocking {
			want = "waiting-input"
		}
		if interaction["blocksTurn"] != blocking || LatestTurn(state)["status"] != want {
			t.Fatalf("isBlocking=%v projected as %v, status=%v", blocking, interaction["blocksTurn"], LatestTurn(state)["status"])
		}
	}
}
