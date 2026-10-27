package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

type terminalGuardStore struct {
	memoryStore
	guard    sync.Mutex
	adapter  *codex.Adapter
	rejected int
}

func (s *terminalGuardStore) Commit(ctx context.Context, raw json.RawMessage) error {
	s.guard.Lock()
	defer s.guard.Unlock()
	before, err := s.adapter.SessionState().Project(s.Read())
	if err != nil {
		return err
	}
	after, err := s.adapter.SessionState().Project(raw)
	if err != nil {
		return err
	}
	if before.LatestExecution != nil && before.LatestExecution.Terminal() && after.LatestExecution != nil && before.LatestExecution.ExecutionID == after.LatestExecution.ExecutionID && !reflect.DeepEqual(before.LatestExecution, after.LatestExecution) {
		s.rejected++
		return errors.New("terminal execution cannot change")
	}
	return s.memoryStore.Commit(ctx, raw)
}
func verifyCanonicalClose(ctx context.Context, root, binary string) error {
	environment, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	environment["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	environment["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	adapter := codex.New(host(root, environment))
	defer adapter.Close()
	state := &terminalGuardStore{adapter: adapter}
	settings := encoded(object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "full-access"})
	record := model.SessionRecord{ID: "canonical-close", Cwd: filepath.Join(root, "work"), Settings: settings}
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: record.ID, ReadThread: func() model.SessionRecord { return record }, SessionState: state, RequireExplicitSettings: true})
	if err != nil {
		return err
	}
	defer handle.Close()
	if err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "canonical-close-execution", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "fixture-interrupt"}}}, Admitted: func() error { return nil }}); err != nil {
		return err
	}
	raw, err := adapter.SessionState().Settle(plugin.SettleRequest{SessionState: state.Read(), ExecutionID: "canonical-close-execution", Outcome: "interrupted", FinishedAt: time.Now().UnixMilli()})
	if err != nil {
		return err
	}
	if err = state.memoryStore.Commit(ctx, raw); err != nil {
		return err
	}
	before, _ := adapter.SessionState().Project(state.Read())
	if err = handle.Close(); err != nil {
		return fmt.Errorf("close after host terminal settlement: %w", err)
	}
	after, _ := adapter.SessionState().Project(state.Read())
	state.guard.Lock()
	rejected := state.rejected
	state.guard.Unlock()
	if rejected != 0 || !reflect.DeepEqual(before.LatestExecution, after.LatestExecution) {
		return errors.New("close retried or changed the host's immutable terminal execution")
	}
	fmt.Println("PASS Codex close after host settlement: late native callbacks discarded; canonical terminal preserved without rejected commits")
	return nil
}
