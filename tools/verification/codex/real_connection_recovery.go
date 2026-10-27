package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

type retryObservationStore struct {
	memoryStore
	retryObserved atomic.Bool
}

func (s *retryObservationStore) Commit(ctx context.Context, state json.RawMessage) error {
	if strings.Contains(string(state), "Codex 连接中断，正在恢复") {
		s.retryObserved.Store(true)
	}
	return s.memoryStore.Commit(ctx, state)
}

func verifyRealHTTPRecovery(lifetime context.Context, root, wrapper string, adapter *codex.Adapter, provider *localProvider) error {
	ctx, cancel := context.WithTimeout(lifetime, 80*time.Second)
	defer cancel()
	store := &retryObservationStore{}
	thread := model.SessionRecord{ID: "real-http-recovery", CreatedAt: time.Now().UnixMilli(), Cwd: filepath.Join(root, "work"), Settings: encoded(object{"executablePath": wrapper, "model": "gpt-5.4", "serviceTier": "default", "approvalPolicy": "never", "approvalsReviewer": "user", "sandbox": "workspace-write"})}
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: thread.ID, ReadThread: func() model.SessionRecord { return thread }, SessionState: store})
	if err != nil {
		return err
	}
	defer handle.Close()
	if err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "real-http-retry", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "native-retry-fixture"}}}}); err != nil {
		return err
	}
	failed, err := awaitAnyNativeExecution(ctx, adapter, &store.memoryStore)
	if err != nil {
		return err
	}
	if !store.retryObserved.Load() || failed.Status != "failed" || failed.Error == nil || !strings.Contains(*failed.Error, "连接恢复失败") {
		return fmt.Errorf("installed CLI HTTP disconnect did not enter bounded willRetry recovery: status=%s retryObserved=%v error=%v", failed.Status, store.retryObserved.Load(), failed.Error)
	}
	requests, failures := provider.snapshot()
	count := 0
	for _, request := range requests {
		if strings.Contains(string(encoded(request["input"])), "native-retry-fixture") {
			count++
		}
	}
	if count < 2 || count > 5 || len(failures) != 0 {
		return fmt.Errorf("HTTP recovery request audit: retries=%d failures=%v", count, failures)
	}
	// Native history contains the original prompt; disable this provider fault
	// for the successor by matching its deliberate recovery instruction first.
	if err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "real-http-successor", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "native-retry-successor: continue once after the connection recovered"}}}}); err != nil {
		return err
	}
	completed, err := awaitExecution(ctx, adapter, &store.memoryStore, handle, false)
	if err != nil {
		return err
	}
	if completed.Status != "completed" || completed.Summary == nil || *completed.Summary != realAnswer {
		return fmt.Errorf("installed CLI did not recover on next deliberate input: %+v", completed)
	}
	after, failures := provider.snapshot()
	if len(after) != len(requests)+1 || len(failures) != 0 {
		return fmt.Errorf("successor was replayed: before=%d after=%d failures=%v", len(requests), len(after), failures)
	}
	fmt.Printf("PASS real native HTTP SSE disconnect -> willRetry recovery (%d attempts), process retirement and exactly-once resumed successor\n", count)
	return nil
}

func awaitAnyNativeExecution(ctx context.Context, adapter *codex.Adapter, store *memoryStore) (*model.PublicExecution, error) {
	for {
		observation, err := adapter.SessionState().Project(store.Read())
		if err != nil {
			return nil, err
		}
		if execution := observation.LatestExecution; execution != nil && execution.Terminal() {
			return execution, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
}
