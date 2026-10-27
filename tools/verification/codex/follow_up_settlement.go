package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
)

// The peer blocks terminal-list publication, keeping native completion ahead of
// durable completion exactly as in the reported Moku race.
func (p *peer) settlementFixture(method string, params object, id any) (bool, error) {
	root := os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT")
	input := ""
	for _, part := range list(params["input"]) {
		input += text(record(part)["text"])
	}
	if method == "turn/start" && strings.HasPrefix(input, "fixture-settlement-") {
		p.settlementMode = strings.TrimPrefix(input, "fixture-settlement-")
		p.turnNumber++
		p.turn = fmt.Sprintf("fixture-turn-%d", p.turnNumber)
		if err := p.event("turn/started", object{"threadId": p.session, "turn": object{"id": p.turn}}); err != nil {
			return true, err
		}
		if err := p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}}); err != nil {
			return true, err
		}
		if p.settlementMode == "local" || p.settlementMode == "cancel" {
			p.holdSettlement = true
			return true, p.completed("Original completed")
		}
		return true, nil
	}
	if p.settlementMode == "" {
		return false, nil
	}
	if method == "turn/start" {
		log, err := os.OpenFile(filepath.Join(root, "successor-dispatched"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			return true, err
		}
		_, err = log.WriteString(input + "\n")
		if err = errors.Join(err, log.Close()); err != nil {
			return true, err
		}
	}
	if method == "turn/steer" && (input == "rejected-follow-up" || (strings.HasPrefix(p.settlementMode, "ended") && input == "Read the source")) {
		if strings.HasPrefix(p.settlementMode, "ended-delayed") {
			if !p.delayedSettlement {
				p.delayedSettlement = true
				// Keep the notification behind a barrier while rejecting every
				// steer, as a busy notification consumer can lag RPC replies.
				params := object{"threadId": p.session, "turn": object{"id": p.turn, "status": "completed", "items": []any{}}}
				go func() {
					ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
					defer cancel()
					if awaitSettlementFile(ctx, root, "release") == nil {
						_ = p.event("turn/completed", params)
					}
				}()
			}
			if err := os.WriteFile(filepath.Join(root, "rejected"), []byte("ready"), 0600); err != nil {
				return true, err
			}
		} else if p.settlementMode == "remote" || strings.HasPrefix(p.settlementMode, "ended") {
			p.holdSettlement = true
			if err := p.completed("Original completed"); err != nil {
				return true, err
			}
		}
		message := "fixture steer rejected"
		if strings.HasPrefix(p.settlementMode, "ended") {
			message = "no active turn to steer"
		}
		code := -32600
		if p.settlementMode == "ended-wrongcode" {
			code = -32000
		}
		return true, p.send(object{"id": id, "error": object{"code": code, "message": message}})
	}
	if method == "thread/backgroundTerminals/list" && p.holdSettlement {
		p.holdSettlement = false
		if err := os.WriteFile(filepath.Join(root, "settling"), []byte("ready"), 0600); err != nil {
			return true, err
		}
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := awaitSettlementFile(ctx, root, "release"); err != nil {
			return true, err
		}
		return true, p.send(object{"id": id, "result": object{"data": []any{}, "nextCursor": nil}})
	}
	return false, nil
}

func awaitSettlementFile(ctx context.Context, root, name string) error {
	for {
		if _, err := os.Stat(filepath.Join(root, name)); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for %s: %w", name, ctx.Err())
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func verifyFollowUpSettlement(ctx context.Context, root, binary string) error {
	for _, mode := range []string{"local", "remote", "reject", "cancel", "ended", "ended-cancel", "ended-wrongcode", "ended-delayed", "ended-delayed-cancel", "ended-delayed-moku"} {
		if err := verifyFollowUpCase(ctx, filepath.Join(root, mode), binary, mode); err != nil {
			return fmt.Errorf("follow-up settlement %s: %w", mode, err)
		}
	}
	fmt.Println("PASS Codex follow-up settlement: native/durable completion race, rejected steering, canonical outcomes, single admission, cancellation and subsequent sends")
	return nil
}

func verifyFollowUpCase(lifetime context.Context, root, binary, mode string) error {
	ctx, cancel := context.WithTimeout(lifetime, 15*time.Second)
	defer cancel()
	r, db, adapter, err := backgroundRuntime(lifetime, root)
	if err != nil {
		return err
	}
	defer db.Close()
	defer adapter.Close()
	defer r.Close(context.Background())
	release := func() { _ = os.WriteFile(filepath.Join(root, "release"), []byte("ready"), 0600) }
	defer release()
	settings := object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "full-access"}
	input := func(s string) model.AgentInput {
		return model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: s}}}
	}
	var id, original, deliveryID string
	if mode == "ended-delayed-moku" {
		child, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "codex", Cwd: filepath.Join(root, "work"), Settings: encoded(settings), Input: input("Read the source")})
		if err != nil {
			return err
		}
		if _, err = waitBackground(ctx, r, child.Record.ID, false); err != nil {
			return err
		}
		pending, err := r.PendingMokuDeliveries()
		if err != nil || len(pending) != 1 {
			return fmt.Errorf("child completion delivery: %+v, %v", pending, err)
		}
		deliveryID = pending[0].ID
		delete(settings, "thinking")
		settings["effort"] = "low"
		moku, err := r.EnsureMokuThread(ctx, "codex", encoded(settings), filepath.Join(root, "work"))
		if err != nil {
			return err
		}
		started, err := r.SendMokuThread(ctx, moku.ID, input("fixture-settlement-"+mode), nil, nil, nil)
		if err != nil {
			return err
		}
		id, original = moku.ID, started.ExecutionID
	} else {
		created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "codex", Cwd: filepath.Join(root, "work"), Settings: encoded(settings), Input: input("fixture-settlement-" + mode)})
		if err != nil {
			return err
		}
		id, original = created.Record.ID, created.Execution.ExecutionID
	}
	if mode == "local" || mode == "cancel" {
		if err := awaitSettlementFile(ctx, root, "settling"); err != nil {
			return err
		}
	}
	type reply struct {
		result core.SendResult
		err    error
	}
	done := make(chan reply, 1)
	sendCtx, cancelSend := context.WithCancel(ctx)
	defer cancelSend()
	prompt := "Read the source"
	if mode == "remote" || mode == "reject" {
		prompt = "rejected-follow-up"
	}
	go func() {
		if deliveryID != "" {
			result, err := r.SendMokuDelivery(sendCtx, deliveryID, id, input(prompt), nil, nil)
			done <- reply{result, err}
			return
		}
		value, err := r.Invoke(sendCtx, "thread:follow-up", []json.RawMessage{encoded(object{"threadId": id, "input": input(prompt)})})
		var result core.SendResult
		if err == nil {
			result = value.(core.SendResult)
		}
		done <- reply{result, err}
	}()
	var sent reply
	if strings.HasPrefix(mode, "ended-delayed") {
		if err := awaitSettlementFile(ctx, root, "rejected"); err != nil {
			return err
		}
		// Exceed the former five-steer polling window (500 ms) while the
		// native terminal notification is explicitly held back.
		select {
		case sent = <-done:
			return fmt.Errorf("rejected input abandoned before delayed terminal: %+v, %v", sent.result, sent.err)
		case <-time.After(time.Second):
		}
		if mode == "ended-delayed-cancel" {
			cancelSend()
		}
		release()
	}
	if mode == "ended" || mode == "ended-cancel" {
		if err := awaitSettlementFile(ctx, root, "settling"); err != nil {
			return err
		}
	}
	if mode == "local" || mode == "cancel" || mode == "ended" || mode == "ended-cancel" {
		// The peer's explicit barrier has already established the race window.
		select {
		case sent = <-done:
			return fmt.Errorf("input acknowledged before terminal publication: %+v", sent)
		case <-time.After(100 * time.Millisecond):
		}
		if mode == "cancel" || mode == "ended-cancel" {
			cancelSend()
		}
		release()
	}
	select {
	case sent = <-done:
	case <-ctx.Done():
		return fmt.Errorf("waiting for send: %w", ctx.Err())
	}
	if mode == "local" || mode == "ended" || mode == "ended-delayed" || mode == "ended-delayed-moku" {
		if sent.err != nil || !sent.result.StartedNewExecution || sent.result.ExecutionID == original {
			return fmt.Errorf("input did not receive a fresh execution: %+v, %v", sent.result, sent.err)
		}
	} else if sent.err == nil {
		return fmt.Errorf("rejected/cancelled follow-up was acknowledged: %+v", sent)
	}
	release()
	if mode == "reject" {
		thread, err := r.Thread(id)
		if err != nil {
			return err
		}
		if thread.Observation.LatestExecution.Status != "running" {
			return fmt.Errorf("rejected steer settled original: %+v", thread.Observation.LatestExecution)
		}
		// A later accepted steer must retain the original execution identity.
		sent.result, err = r.SendThread(ctx, id, input("accepted-follow-up"))
		if err != nil || sent.result.StartedNewExecution || sent.result.ExecutionID != original {
			return fmt.Errorf("could not continue original after rejection: %+v, %v", sent.result, err)
		}
	}
	thread, err := waitBackground(ctx, r, id, false)
	if err != nil {
		return fmt.Errorf("waiting for completion (%+v): %w", thread.Observation.LatestExecution, err)
	}
	previous, err := adapter.SessionState().ResolveExecution(thread.SessionState, original)
	if err != nil || previous == nil || previous.Status != "completed" {
		return fmt.Errorf("original completion was overwritten: %+v, %v", previous, err)
	}
	if deliveryID != "" {
		pending, err := r.PendingMokuDeliveries()
		if err != nil || len(pending) != 0 {
			return fmt.Errorf("rejected delivery did not converge: %+v, %v", pending, err)
		}
		wire, err := os.ReadFile(filepath.Join(root, "successor-dispatched"))
		if err != nil || string(wire) != prompt+"\n" {
			return fmt.Errorf("delivery successor dispatch count/content: %q, %v", wire, err)
		}
		return nil
	}
	events, err := db.Snapshot().Events()
	if err != nil {
		return err
	}
	accepted := 0
	for _, event := range events {
		if event.Subject.ID == id && event.Type == "thread.input-accepted" {
			accepted++
			if (mode == "local" || mode == "ended" || mode == "ended-delayed" || mode == "ended-delayed-moku") && event.Source == "user" {
				var receipt model.UserThreadInput
				if err := json.Unmarshal(event.Data, &receipt); err != nil {
					return err
				}
				if receipt.ExecutionID != sent.result.ExecutionID || !receipt.StartedNewExecution {
					return fmt.Errorf("durable input receipt retained the ended execution: %+v", receipt)
				}
			}
		}
	}
	expected := 1
	if mode == "local" || mode == "reject" || mode == "ended" || mode == "ended-delayed" || mode == "ended-delayed-moku" {
		expected = 2
	}
	if accepted != expected {
		return fmt.Errorf("input admission count: got %d, want %d", accepted, expected)
	}
	if mode == "remote" || mode == "cancel" || mode == "ended-cancel" || mode == "ended-wrongcode" || mode == "ended-delayed-cancel" {
		if _, err := os.Stat(filepath.Join(root, "successor-dispatched")); !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("rejected/cancelled input was replayed: %v", err)
		}
	}

	// Every path must leave the same handle able to start another turn.
	next, err := r.SendThread(ctx, id, input("Read the source"))
	if err != nil || !next.StartedNewExecution {
		return fmt.Errorf("subsequent send failed: %+v, %v", next, err)
	}
	thread, err = waitBackground(ctx, r, id, false)
	if err != nil {
		return err
	}
	if thread.Observation.LatestExecution.Status != "completed" {
		return fmt.Errorf("subsequent execution failed: %+v", thread.Observation.LatestExecution)
	}
	return nil
}
