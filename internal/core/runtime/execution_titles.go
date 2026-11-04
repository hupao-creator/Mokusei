package runtime

import (
	"context"
	"encoding/json"
	"maps"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// Title changes prove a naming commit, but input admission alone does not prove
// metadata retention: its storage failure is deliberately nonfatal. Keep every
// possible execution since the last proven naming commit, rather than assigning
// a delayed result to whichever execution happens to be current.
type executionTitleHistory struct {
	executionID string
	candidates  map[string]bool
	lastTitle   string
	titles      map[string]string
}

func (r *Runtime) restoreExecutionTitles(ctx context.Context) error {
	const marker = "execution-title-history-v1"
	snapshot := r.config.Store.Snapshot()
	if snapshot.Has(marker) {
		return nil
	}
	events, err := snapshot.Events()
	if err != nil {
		return err
	}
	histories := map[string]*executionTitleHistory{}
	for start := 0; start < len(events); {
		end := start + 1
		for end < len(events) && events[end].CreatedAt == events[start].CreatedAt {
			end++
		}
		byThread := map[string][]store.Event{}
		for _, event := range events[start:end] {
			if event.Subject.Kind == "thread" && event.Subject.TypeID == "agent" {
				byThread[event.Subject.ID] = append(byThread[event.Subject.ID], event)
			}
		}
		for id, group := range byThread {
			history := histories[id]
			if history == nil {
				history = &executionTitleHistory{candidates: map[string]bool{"": true}, titles: map[string]string{}}
				histories[id] = history
			}
			history.observe(group)
		}
		start = end
	}
	_, err = r.config.Store.Update(ctx, func(tx *store.Tx) error {
		for id, history := range histories {
			if len(history.titles) == 0 {
				continue
			}
			var thread model.ThreadRecord
			found, err := tx.Get("thread:"+id, &thread)
			if err != nil {
				return err
			}
			if !found || thread.Moku || thread.MokuHistory {
				continue
			}
			titles := maps.Clone(history.titles)
			// Explicitly stored ownership always wins over historical inference.
			maps.Copy(titles, thread.ExecutionTitles)
			if same(titles, thread.ExecutionTitles) {
				continue
			}
			thread.ExecutionTitles = titles
			thread.Revision++
			if err := tx.Put("thread:"+id, thread); err != nil {
				return err
			}
		}
		return tx.Put(marker, true)
	})
	return err
}

func (h *executionTitleHistory) observe(events []store.Event) {
	previousExecution := h.executionID
	executions := map[string]bool{}
	titles := map[string]bool{}
	for _, event := range events {
		switch {
		case event.Type == "entity.created":
			h.candidates = map[string]bool{}
		case strings.HasPrefix(event.Type, "execution."):
			var execution model.PublicExecution
			if json.Unmarshal(event.Data, &execution) == nil && execution.ExecutionID != "" {
				executions[execution.ExecutionID] = true
			}
		case event.Type == "entity.updated":
			var value struct {
				Title string `json:"title"`
			}
			if json.Unmarshal(event.Data, &value) == nil && strings.TrimSpace(value.Title) != "" {
				titles[value.Title] = true
			}
		}
	}
	if len(executions) > 1 {
		h.executionID = ""
	} else {
		for id := range executions {
			h.executionID = id
		}
	}
	accepted := map[string]bool{}
	for _, event := range events {
		if event.Type == "thread.input-accepted" {
			var input struct {
				ExecutionID string `json:"executionId"`
			}
			if json.Unmarshal(event.Data, &input) != nil {
				continue
			}
			// Older application-origin input facts omitted the ID. An unknown
			// or tied execution boundary remains an unknown candidate.
			if input.ExecutionID == "" && (len(executions) == 0 || previousExecution == h.executionID) {
				input.ExecutionID = h.executionID
			}
			accepted[input.ExecutionID] = true
		}
	}
	maps.Copy(h.candidates, accepted)
	if len(titles) > 1 {
		h.lastTitle = ""
		h.candidates[""] = true
		return
	}
	for title := range titles {
		// Tag/settings snapshots repeat the catalog title; they do not prove
		// naming completion. Nor can the first snapshot establish a change.
		if h.lastTitle != "" && title != h.lastTitle {
			// Random IDs cannot order facts sharing a millisecond. No title
			// attribution crosses an input/execution boundary in that group.
			if len(h.candidates) == 1 && len(accepted) == 0 && len(executions) == 0 {
				for id := range h.candidates {
					if id != "" {
						h.titles[id] = title
					}
				}
			}
			// The naming commit clears pending intent. Same-timestamp input
			// may have followed it, so conservatively retain those candidates.
			h.candidates = accepted
		}
		h.lastTitle = title
	}
}
