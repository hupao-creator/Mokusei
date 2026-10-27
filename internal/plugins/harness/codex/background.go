package codex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"strings"
	"time"
)

func (h *Handle) queueBackground(event Map) {
	h.backgroundMu.Lock()
	defer h.backgroundMu.Unlock()
	if h.backgroundQueue == nil {
		h.backgroundQueue = map[string]Map{}
	}
	h.backgroundQueue[str(event["activityId"])] = clone(event)
	if h.backgroundScheduled {
		return
	}
	h.backgroundScheduled = true
	go func() {
		select {
		case <-h.lifetime.Done():
			h.backgroundMu.Lock()
			h.backgroundScheduled = false
			h.backgroundMu.Unlock()
			return
		case <-time.After(25 * time.Millisecond):
		}
		attempt := 0
		for {
			h.backgroundMu.Lock()
			items := []Map{}
			for _, e := range h.backgroundQueue {
				items = append(items, e)
			}
			h.backgroundQueue = map[string]Map{}
			if len(items) == 0 {
				// Publish the idle scheduler under the same lock as enqueue.
				h.backgroundScheduled = false
				h.backgroundMu.Unlock()
				return
			}
			h.backgroundMu.Unlock()
			if e := h.deliverBackground(items); e == nil {
				attempt = 0
				continue
			}
			attempt++
			h.backgroundMu.Lock()
			for _, e := range items {
				id := str(e["activityId"])
				if h.backgroundQueue[id] == nil {
					h.backgroundQueue[id] = e
				}
			}
			if attempt >= 3 {
				h.backgroundScheduled = false
				h.backgroundMu.Unlock()
				return
			}
			h.backgroundMu.Unlock()
			select {
			case <-h.lifetime.Done():
				h.backgroundMu.Lock()
				h.backgroundScheduled = false
				h.backgroundMu.Unlock()
				return
			case <-time.After(25 * time.Millisecond):
			}
		}
	}()
}
func (h *Handle) deliverBackground(items []Map) error {
	h.opMu.Lock()
	defer h.opMu.Unlock()
	h.mu.Lock()
	current := []Map{}
	for _, item := range items {
		if int64(num(item["backgroundEpoch"])) == h.backgroundEpoch {
			current = append(current, item)
		}
	}
	items = current
	if h.closed || h.backgroundPaused || len(items) == 0 {
		h.mu.Unlock()
		return nil
	}
	ctx, cancel := context.WithTimeout(h.lifetime, 30*time.Second)
	h.backgroundCancel = cancel
	h.mu.Unlock()
	defer func() {
		cancel()
		h.mu.Lock()
		h.backgroundCancel = nil
		h.mu.Unlock()
	}()
	if h.context.ExecutionAdmission == nil {
		return errors.New("background continuation admission unavailable")
	}
	text := []string{"<task-notification>", "One or more Codex background commands completed. Continue the current task using these results."}
	for _, e := range items {
		text = append(text, fmt.Sprintf("- activity: %s; status: %s; detail: %s", str(e["activityId"]), str(e["status"]), str(e["detail"])))
	}
	text = append(text, "</task-notification>")
	input := model.AgentInput{Presentation: "internal", Parts: []model.AgentInputPart{{Kind: "text", Text: strings.Join(text, "\n")}}}
	wire, e := WireInput(input)
	if e != nil {
		return e
	}
	for {
		h.mu.Lock()
		active, native, closed := h.activeID, h.native, h.closed
		h.mu.Unlock()
		if closed {
			return errors.New("Codex handle closed")
		}
		if active == "" {
			break
		}
		if native != nil {
			if e := native.Steer(ctx, wire); e == nil {
				h.mu.Lock()
				defer h.mu.Unlock()
				return h.commit(ctx, AppendFollowUp(h.state, active, inputMap(input), now(), uid()))
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
	options, e := h.options(ctx)
	if e != nil {
		return e
	}
	id, e := h.context.ExecutionAdmission.Accept(ctx, func(id string) (json.RawMessage, error) {
		h.mu.Lock()
		defer h.mu.Unlock()
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		next, e := StageExecutionChecked(h.state, id, inputMap(input), now(), options.Settings)
		if e != nil {
			return nil, e
		}
		return raw(next), nil
	})
	if e != nil {
		return e
	}
	h.mu.Lock()
	h.state = rawMap(h.context.SessionState.Read())
	h.activeID = id
	h.mu.Unlock()
	if e = h.ensureNative(ctx, &options); e == nil {
		e = h.native.Start(ctx, options, id, wire, h.receive)
	}
	if e != nil {
		h.receive(Map{"type": "error", "message": e.Error()})
		h.receive(Map{"type": "done", "outcome": "failed"})
	}
	return e
}
