// Seed completed reading fixtures through the production Codex reducer and store.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func main() {
	if err := seed(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func seed() error {
	if len(os.Args) != 2 || !filepath.IsAbs(os.Args[1]) {
		return errors.New("usage: thread-interaction /absolute/new/profile")
	}
	root := os.Args[1]
	// Refuse existing profiles so no user data can be overwritten.
	if err := os.Mkdir(root, 0700); err != nil {
		return err
	}
	db, err := store.Open(filepath.Join(root, "mokusei-go-state-v1", "state.sqlite"))
	if err != nil {
		return err
	}
	// A fixed epoch keeps timeline identities, ordering and content reproducible.
	const at int64 = 1_735_689_600_000
	ids := []string{"interaction-a", "interaction-b", "interaction-c"}
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		for i, id := range ids {
			state := codex.EmptyState(at)
			turns := []int{1, 8, 150}[i]
			for j := 0; j < turns; j++ {
				exec := fmt.Sprintf("%s-turn-%d", id, j)
				stamp := at + int64(j*20)
				state, err = codex.StageExecutionChecked(state, exec, codex.Map{"messageId": exec + "-prompt", "parts": []any{codex.Map{"kind": "text", "text": fmt.Sprintf("[%s/%d] 只读 replay fixture 🚀 — explain retained thread identity and navigation.", id, j)}}}, stamp, codex.Map{"model": "fixture-read-only", "effort": "low"})
				if err != nil {
					return err
				}
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "reasoning-delta", "delta": "This is stored reasoning fixture text; no model is called.", "at": stamp + 1})
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "activity-start", "activity": codex.Map{"id": exec + "-command", "kind": "command", "label": "Read-only fixture command (never executed)", "toolCall": true}, "at": stamp + 2})
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "activity-end", "activityId": exec + "-command", "status": "completed", "detail": "Fixture output line 1\nFixture output 中文 🚀\n" + strings.Repeat("Long command output for disclosure scroll\n", 30), "at": stamp + 3})
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "activity-start", "activity": codex.Map{"id": exec + "-tool", "kind": "tool", "label": "Read-only fixture tool", "toolName": "fixture_lookup", "toolCall": true}, "at": stamp + 4})
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "activity-end", "activityId": exec + "-tool", "status": "completed", "at": stamp + 5})
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "activity-start", "activity": codex.Map{"id": exec + "-file", "kind": "file", "label": "Fixture file observation", "toolCall": true}, "at": stamp + 6})
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "activity-end", "activityId": exec + "-file", "status": "completed", "at": stamp + 7})
				state = codex.ReduceEvent(state, exec, codex.Map{"type": "text-final", "itemId": exec + "-answer", "text": fmt.Sprintf("# Read-only thread %s, turn %d\n\nNavigation identity marker: **%s-%d**.\n\n", id, j, id, j) + strings.Repeat("Multiline body: 中文 / emoji 🚀 / inline `code`.\n\n", 8+i*8) + "```go\nfunc main() { println(\"read-only fixture\") }\n```\n\n| State | Expected |\n| --- | --- |\n| Mounted | True |\n| Back | Available |\n", "at": stamp + 9})
				state = codex.SettleExecution(state, exec, "completed", stamp+10, "")
			}
			if _, e := codex.DecodeState(state); e != nil {
				return e
			}
			native, e := json.Marshal(state)
			if e != nil {
				return e
			}
			archived := false
			rec := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "codex", SessionState: native, Settings: json.RawMessage(`{}`), Cwd: filepath.Dir(root), CreatedAt: at + int64(i), UpdatedAt: at + 1000 + int64(i)}, Title: fmt.Sprintf("Read-only thread %s (%d turns)", id, turns), Archived: &archived, Tags: []string{"replay"}, TagEmojis: map[string]string{"replay": "🔁"}}
			if e = tx.Put("thread:"+id, rec); e != nil {
				return e
			}
		}
		return tx.SetOrder("threads", ids)
	})
	return errors.Join(err, db.Close())
}
