package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

type voiceReplayAdmission struct{ store *memoryStore }

func (a voiceReplayAdmission) Accept(ctx context.Context, project func(string) (json.RawMessage, error)) (string, error) {
	const id = "voice-takeover-execution"
	state, err := project(id)
	if err == nil {
		err = a.store.Commit(ctx, state)
	}
	return id, err
}

func verifyVoiceOwnerRecovery(ctx context.Context, root, binary string) error {
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	a := codex.New(host(root, env))
	defer a.Close()
	store := &memoryStore{}
	settings := object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "full-access"}
	record := model.SessionRecord{ID: "voice-owner-recovery", CreatedAt: time.Now().UnixMilli(), Cwd: filepath.Join(root, "work"), Settings: encoded(settings)}
	handle, err := a.Open(ctx, plugin.OpenContext{ThreadID: record.ID, ReadThread: func() model.SessionRecord { return record }, SessionState: store, RequireExplicitSettings: true, ExecutionAdmission: voiceReplayAdmission{store}})
	if err != nil {
		return err
	}
	defer handle.Close()
	voice, err := handle.(plugin.NativeVoiceCapability).PrepareNativeVoice(ctx, nil)
	if err != nil {
		return err
	}
	send := func(id, text string) error {
		return handle.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}})
	}
	if err = send("text-before-voice", "Read the source"); err != nil {
		return err
	}
	if _, err = awaitExecution(ctx, a, store, handle, false); err != nil {
		return err
	}
	if err = voice.(plugin.VoiceContextSync).SyncContext(ctx, []plugin.ContextEntry{{ID: "takeover", Content: "fixture-voice-takeover"}}); err != nil {
		return err
	}
	for {
		observation, err := a.SessionState().Project(store.Read())
		if err != nil {
			return err
		}
		if current := observation.LatestExecution; current != nil && current.ExecutionID == "voice-takeover-execution" && current.Terminal() {
			if current.Status != "completed" || current.Summary == nil || *current.Summary != "Voice takeover completed" {
				return fmt.Errorf("voice takeover lost execution events: %+v", current)
			}
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
	if err = send("voice-owner-stall", "fixture-recovery-storm"); err != nil {
		return err
	}
	if err = send("voice-owner-follow-up", "accepted-follow-up"); err != nil {
		return err
	}
	failed, err := awaitAnyNativeExecution(ctx, a, store)
	if err != nil {
		return err
	}
	if failed.Status != "failed" {
		return fmt.Errorf("voice owner did not fail on retry budget: %+v", failed)
	}
	for !voice.Closed() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
	if err = send("voice-owner-successor", "Read the source"); err != nil {
		return err
	}
	if _, err = awaitExecution(ctx, a, store, handle, false); err != nil {
		return err
	}
	// New preparation proves the released voice is no longer blocking the handle.
	replacement, err := handle.(plugin.NativeVoiceCapability).PrepareNativeVoice(ctx, nil)
	if err != nil {
		return err
	}
	if replacement.ID() == voice.ID() {
		return fmt.Errorf("voice owner was not released")
	}
	return replacement.Stop(ctx)
}
