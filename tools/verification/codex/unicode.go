package main

import (
	"fmt"
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
	state["nativeActivity"] = object{"status": "invalid\x00value", "updatedAt": 3}
	if _, err = adapter.Project(encoded(state)); err == nil {
		return fmt.Errorf("single-pass decoder bypassed state validation")
	}
	fmt.Println("PASS Codex single-pass validation, UTF-16 identity bounds and surrogate-safe head/tail previews")
	return nil
}
