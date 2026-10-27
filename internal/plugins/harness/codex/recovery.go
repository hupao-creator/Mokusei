package codex

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"strings"
)

// Only deterministic request-decoding failures prove that no native turn ran.
// A missing rollout alone does not authorize discarding conversation history.
func canRecoverRejectedStart(state Map) bool {
	primary := str(state["primarySessionId"])
	turns := arr(state["turns"])
	if primary == "" || len(turns) == 0 || len(turns) >= stMaxTurns || len(arr(state["forkHistory"])) > 0 || state["nativeHistorySeed"] != nil || state["nativeActivity"] != nil || len(arr(state["backgroundTerminals"])) > 0 {
		return false
	}
	rejected := false
	for _, value := range turns {
		turn := obj(value)
		if turn["status"] != "failed" || str(turn["answer"]) != "" || str(turn["reasoning"]) != "" || str(turn["diff"]) != "" || turn["usage"] != nil || len(arr(turn["activities"])) > 0 || len(arr(turn["interactions"])) > 0 || len(arr(turn["plan"])) > 0 {
			return false
		}
		for _, value := range arr(turn["messages"]) {
			message := obj(value)
			if message["role"] != "user" || message["kind"] != "prompt" {
				return false
			}
		}
		failure := str(turn["error"])
		if strings.HasPrefix(failure, "Codex app-server (-32600): Invalid request: invalid type:") {
			rejected = true
		} else if failure != "Codex app-server (-32600): no rollout found for thread id "+primary {
			return false
		}
	}
	return rejected
}

func (a *Adapter) recoverUnstartedSession(ctx context.Context, state Map, record model.SessionRecord) (Map, error) {
	if !canRecoverRejectedStart(state) {
		return state, nil
	}
	cwd := record.Cwd
	if record.Worktree != nil {
		cwd = record.Worktree.Cwd
	}
	server, err := a.server(ctx, cwd, str(rawMap(record.Settings)["executablePath"]), str(state["nativeToolMode"]), record.ID)
	if err != nil {
		return nil, err
	}
	// The installed app-server's read APIs only see loaded threads. Attempt
	// native resume without submitting any input; only an exact missing-rollout
	// response authorizes retirement of this provably unstarted binding.
	native := NewNativeSession(server)
	_, historyErr := native.Prepare(ctx, NativeOptions{Cwd: cwd, SessionID: str(state["primarySessionId"]), Settings: rawMap(record.Settings), ToolMode: str(state["nativeToolMode"])})
	if err = native.Close(); err != nil {
		return nil, err
	}
	var rpc *RPCError
	if !errors.As(historyErr, &rpc) || rpc.Code != -32600 || rpc.Message != "no rollout found for thread id "+str(state["primarySessionId"]) {
		return state, historyErr
	}
	next := clone(state)
	delete(next, "primarySessionId")
	next["updatedAt"] = max(now(), int64(num(state["updatedAt"]))+1)
	return next, nil
}

// A history seed rejected before any native work can return to its unchanged
// parent. Display failures remain durable; no previous input is resent.
func (a *Adapter) recoverHistory(ctx context.Context, state Map, record model.SessionRecord) (Map, error) {
	last := LatestTurn(state)
	primary := str(state["primarySessionId"])
	seed := str(state["nativeHistorySeed"])
	if primary == "" || seed == "" || last["status"] != "failed" || !strings.Contains(str(last["error"]), "context_length_exceeded") || len(arr(state["backgroundTerminals"])) > 0 || state["nativeActivity"] != nil {
		return state, nil
	}
	for _, v := range arr(state["turns"]) {
		status := obj(v)["status"]
		if status == "running" || status == "waiting-input" {
			return state, nil
		}
	}
	var sources []any
	if json.Unmarshal([]byte(seed), &sources) != nil || len(sources) == 0 {
		return state, nil
	}
	source := obj(sources[len(sources)-1])
	parentID := str(source["nativeSessionId"])
	recorded := arr(source["turns"])
	if parentID == "" || parentID == primary || len(recorded) == 0 {
		return state, nil
	}
	cwd := record.Cwd
	if record.Worktree != nil {
		cwd = record.Worktree.Cwd
	}
	s, e := a.server(ctx, cwd, str(rawMap(record.Settings)["executablePath"]), str(state["nativeToolMode"]), record.ID)
	if e != nil {
		return nil, e
	}
	n := NewNativeSession(s)
	defer n.Close()
	rejected, e := n.History(ctx, primary)
	if e != nil {
		return nil, e
	}
	if len(rejected) == 0 {
		return state, nil
	}
	for _, v := range rejected {
		turn := obj(v)
		if turn["status"] != "failed" {
			return state, nil
		}
		for _, item := range arr(turn["items"]) {
			if obj(item)["type"] != "userMessage" {
				return state, nil
			}
		}
	}
	parent, e := n.History(ctx, parentID)
	if e != nil {
		return nil, e
	}
	if len(parent) != len(recorded) {
		return nil, errors.New("Codex 原生父会话已变化，无法安全恢复超限的历史重放；原始记录已保留")
	}
	for i, v := range parent {
		turn, saved := obj(v), obj(recorded[i])
		if str(turn["id"]) == "" || turn["id"] != saved["id"] || turn["status"] != saved["status"] || turn["status"] == "inProgress" || jsonText(turn["items"]) != jsonText(saved["items"]) {
			return nil, errors.New("Codex 原生父会话已变化，无法安全恢复超限的历史重放；原始记录已保留")
		}
	}
	next := clone(state)
	next["primarySessionId"] = parentID
	delete(next, "nativeHistorySeed")
	if len(sources) > 1 {
		next["nativeHistorySeed"] = jsonText(sources[:len(sources)-1])
	}
	next["updatedAt"] = max(now(), int64(num(state["updatedAt"]))+1)
	return next, nil
}
