package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func startChain(ctx context.Context, invoke systemInvoke, mock *provider) (model.AppState, error) {
	mock.mu.Lock()
	mock.children = map[string]string{}
	mock.scopeChecks = map[string]bool{}
	mock.mu.Unlock()
	if err := invoke("moku:submit", []any{object{"input": object{"parts": []any{object{"kind": "text", "text": "SYSTEM_CHAIN_START: create the child and record completion"}}}}}, nil); err != nil {
		return model.AppState{}, err
	}
	next, err := settleSystem(ctx, invoke, mock, func(s model.AppState) bool {
		if len(ordinary(s)) != max(1, len(mock.workspaces)) || reportCount(s) != max(1, len(mock.workspaces)) {
			return false
		}
		for _, t := range s.Threads {
			if t.Moku && t.Note != nil && t.Note.Text == "SYSTEM_CHAIN_VERIFIED" {
				return verifyFanout(s, mock.workspaces) == nil
			}
		}
		return false
	})
	if err != nil {
		return next, err
	}
	return next, verifyFanout(next, mock.workspaces)
}

func heldFollowup(ctx context.Context, invoke systemInvoke, mock *provider, id, marker string) (*responseBarrier, string, error) {
	gate := mock.armBarrier(marker)
	var receipt struct {
		ExecutionID         string
		StartedNewExecution bool
	}
	err := invoke("thread:follow-up", []any{object{"threadId": id, "input": object{"parts": []any{object{"kind": "text", "text": "SYSTEM_CHAIN_CHILD: reply SYSTEM_CHILD_DONE " + marker}}}}}, &receipt)
	if err == nil && (!receipt.StartedNewExecution || receipt.ExecutionID == "") {
		err = errors.New("held followup did not create execution")
	}
	if err == nil {
		select {
		case <-gate.entered:
		case <-ctx.Done():
			err = ctx.Err()
		}
	}
	if err != nil {
		gate.unblock()
	}
	return gate, receipt.ExecutionID, err
}

func activeRemoval(ctx context.Context, invoke systemInvoke, host actionHost, mock *provider, state model.AppState, action string, index int) (model.AppState, error) {
	children := ordinary(state)
	if len(children) == 0 {
		return state, errors.New("active removal requires source")
	}
	id := children[0].ID
	gate, _, err := heldFollowup(ctx, invoke, mock, id, fmt.Sprintf("SYSTEM_REMOVE_%d_END", index))
	defer gate.unblock()
	if err != nil {
		return state, err
	}
	next, err := exerciseLifecycle(ctx, invoke, host, mock, state, strings.TrimSuffix(action, "-active"), index)
	if err != nil {
		return next, err
	}
	gate.unblock()
	select {
	case <-gate.finished:
	case <-ctx.Done():
		return next, ctx.Err()
	}
	next, err = settleSystem(ctx, invoke, mock, func(s model.AppState) bool {
		_, exists := findThread(s, id)
		return !exists
	})
	if err != nil {
		return next, err
	}
	expectedReports := reportCount(state)
	if action == "clear-active" {
		expectedReports = 0
	}
	if reportCount(next) != expectedReports {
		return next, errors.New("late response created a completion Report")
	}
	fmt.Printf("PASS %s: request barrier, joined native shutdown, late response cannot resurrect task/Report\n", action)
	return next, nil
}
