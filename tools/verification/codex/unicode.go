package main

import (
	"fmt"
	"reflect"
	"strings"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func verifyUnicodeState() error {
	adapter := codex.NewSessionStateAdapter()
	state, err := codex.BindPrimarySession(codex.EmptyState(1), strings.Repeat("😀", 512), 2)
	if err != nil {
		return err
	}
	if _, err = adapter.Project(encoded(state)); err != nil {
		return err
	}
	if _, err = codex.BindPrimarySession(codex.EmptyState(1), strings.Repeat("😀", 513), 2); err == nil {
		return fmt.Errorf("UTF-16 session identity bound was widened")
	}
	state = codex.UpdateNativeActivity(state, strings.Repeat("a", 10)+"😀"+strings.Repeat("b", 253), strings.Repeat("a", 1199)+"😀tail", 3)
	if _, err = adapter.Project(encoded(state)); err != nil {
		return err
	}
	value, err := adapter.ProjectRenderer(encoded(state), model.RendererScope{Kind: "overview"})
	if err != nil {
		return err
	}
	activity := record(decoded(value)["nativeActivity"])
	if text(activity["status"]) != "…\n"+strings.Repeat("b", 253) || text(activity["detail"]) != strings.Repeat("a", 1199) || !utf8.Valid(value) {
		return fmt.Errorf("UTF-16 preview split a surrogate pair or changed clipping bounds")
	}

	files := codex.StageExecution(state, "multi-file", object{"parts": []any{object{"kind": "text", "text": "Create two files"}}}, 4, nil)
	item := object{"id": "patch", "type": "fileChange", "changes": []any{object{"path": "one.txt"}, object{"path": "two.txt"}, object{"path": "one.txt"}}}
	files = codex.ReduceEvent(files, "multi-file", object{"type": "activity-start", "activity": codex.ParseActivity(item), "at": 5})
	event := codex.CompletedActivity(item)
	event["at"] = 6
	files = codex.ReduceEvent(files, "multi-file", event)
	files = codex.ReduceEvent(files, "multi-file", object{"type": "done", "outcome": "completed", "at": 7})
	rendered, err := adapter.ProjectRenderer(encoded(files), model.RendererScope{Kind: "execution", Key: "turn:multi-file"})
	if err != nil {
		return err
	}
	activities := list(record(list(decoded(rendered)["turns"])[0])["activities"])
	if len(activities) != 1 || !reflect.DeepEqual(record(activities[0])["filePaths"], []any{"one.txt", "two.txt"}) {
		return fmt.Errorf("native multi-file patch lost unique file paths during settlement/renderer projection: %s", rendered)
	}
	unknown := codex.StageExecution(files, "unknown-files", object{"parts": []any{object{"kind": "text", "text": "Unknown file facts"}}}, 8, nil)
	unknown = codex.ReduceEvent(unknown, "unknown-files", object{"type": "activity-start", "activity": codex.ParseActivity(item), "at": 9})
	item["changes"] = []any{object{"path": strings.Repeat("x", 33*1024)}}
	end := codex.CompletedActivity(item)
	end["at"] = 10
	unknown = codex.ReduceEvent(unknown, "unknown-files", end)
	if _, err := adapter.Project(encoded(unknown)); err != nil {
		return err
	}
	last := record(list(unknown["turns"])[1])
	if _, exists := record(list(last["activities"])[0])["filePaths"]; exists {
		return fmt.Errorf("oversized native file facts retained a stale or truncated count")
	}
	fmt.Println("PASS Codex native multi-file activity paths survive settlement and public renderer projection")
	state["nativeActivity"] = object{"status": "invalid\x00value", "updatedAt": 3}
	if _, err = adapter.Project(encoded(state)); err == nil {
		return fmt.Errorf("single-pass decoder bypassed state validation")
	}
	fmt.Println("PASS Codex single-pass validation, UTF-16 identity bounds and surrogate-safe head/tail previews")
	return nil
}
