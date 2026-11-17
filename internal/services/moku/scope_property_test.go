package moku

import (
	"context"
	"fmt"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"pgregory.net/rapid"
)

// PBT-MOKU-SCOPE: README.md. Commit callbacks are deliberately reordered, while
// each owner's durable history remains a valid sequence of execution lifetimes.
// No native peer or alternate implementation of the coordinator is installed.
func TestToolScopeProperties(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		c := &Coordinator{ctx: ctx, running: true, scopes: map[string]executionScope{}, observed: map[string]string{}}
		retired := []context.Context{}
		for owner := range 2 {
			id := fmt.Sprintf("moku-%d", owner)
			initial := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id}, Moku: true}
			c.installConfiguration(initial, SessionConfiguration{})
			if c.scopeRevision != 0 || len(c.scopes) != 0 {
				t.Fatal("replacement inherited tool authority")
			}
			history := []model.ThreadRecord{}
			executions := rapid.IntRange(1, 12).Draw(t, "executions")
			for execution := range executions {
				statuses := []string{"running", "waiting-input", rapid.SampledFrom([]string{"completed", "failed", "interrupted"}).Draw(t, "terminal")}
				for _, status := range statuses {
					record := initial
					record.Revision = int64(len(history) + 1)
					record.Observation.LatestExecution = &model.PublicExecution{ExecutionID: fmt.Sprintf("execution-%d-%d", owner, execution), Status: status, StartedAt: int64(execution + 1)}
					history = append(history, record)
				}
			}
			// The final history may still be active. Every revision is delivered,
			// in a generated permutation, and arbitrary duplicates follow it.
			if rapid.Bool().Draw(t, "active-tail") {
				history = history[:len(history)-1]
			}
			order := make([]int, len(history))
			for i := range order {
				order[i] = i
			}
			for i := len(order) - 1; i > 0; i-- {
				j := rapid.IntRange(0, i).Draw(t, "permutation")
				order[i], order[j] = order[j], order[i]
			}
			order = append(order, rapid.SliceOfN(rapid.IntRange(0, len(history)-1), 0, 20).Draw(t, "duplicates")...)
			highest := -1
			wantActive := ""
			for _, index := range order {
				if rapid.IntRange(0, 5).Draw(t, "reinstall") == 0 {
					for _, scope := range c.scopes {
						retired = append(retired, scope.ctx)
					}
					c.installConfiguration(initial, SessionConfiguration{})
					wantActive = ""
				}
				previous := map[string]context.Context{}
				for id, scope := range c.scopes {
					previous[id] = scope.ctx
				}
				c.committed(history[index])
				if index > highest {
					highest = index
					wantActive = ""
					if execution := history[index].Observation.LatestExecution; !execution.Terminal() {
						wantActive = execution.ExecutionID
					}
				}
				for id, scope := range previous {
					if id != wantActive {
						retired = append(retired, scope)
					}
				}
				if c.scopeRevision != history[highest].Revision {
					t.Fatal("callback arrival order replaced durable revision authority")
				}
				if wantActive == "" {
					if len(c.scopes) != 0 {
						t.Fatal("stale callback resurrected tool scope")
					}
				} else {
					scope, ok := c.scopes[wantActive]
					if len(c.scopes) != 1 || !ok || scope.threadID != id || scope.ctx.Err() != nil {
						t.Fatal("latest active execution lost exclusive tool authority")
					}
				}
				for _, scope := range retired {
					if scope.Err() == nil {
						t.Fatal("retired tool context remains usable")
					}
				}
			}
			for _, scope := range c.scopes {
				retired = append(retired, scope.ctx)
			}
		}
		cancel()
		for _, scope := range retired {
			if scope.Err() == nil {
				t.Fatal("tool context survived coordinator lifetime")
			}
		}
	})
}
