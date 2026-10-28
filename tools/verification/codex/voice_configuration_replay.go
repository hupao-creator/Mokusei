package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

const voiceConfigurationText = "Use the updated model for this exact spoken request. 保留原话。"
const voiceConfigurationRequestID = "voice-configuration-handoff"
const voiceConfigurationBarrier = "voice-configuration-handoff-processed"

var voiceConfigurationTranscript = []any{object{"role": "user", "text": "Earlier voice context"}}

func (p *peer) voiceConfigurationFixture(method string, params object, id any) (bool, error) {
	if method == "turn/interrupt" && os.Getenv("MOKUSEI_CODEX_REPLAY_VOICE_CANCEL_FAILURE") == "1" {
		return true, p.send(object{"id": id, "error": object{"code": -32000, "message": "fixture native voice cancellation rejected"}})
	}
	if method != "thread/inject_items" || !strings.Contains(string(encoded(params["items"])), "fixture-voice-configuration") {
		return false, nil
	}
	root := os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT")
	if err := os.WriteFile(filepath.Join(root, "voice-configuration-peer.json"), encoded(object{"pid": os.Getpid(), "bridge": p.bridge}), 0600); err != nil {
		return true, err
	}
	if err := p.send(object{"id": id, "result": object{}}); err != nil {
		return true, err
	}
	if err := p.event("thread/realtime/itemAdded", object{"threadId": p.session, "item": object{"type": "handoff_request", "handoff_id": voiceConfigurationRequestID, "input_transcript": voiceConfigurationText, "active_transcript": voiceConfigurationTranscript}}); err != nil {
		return true, err
	}
	p.turnNumber++
	p.turn = fmt.Sprintf("configuration-turn-%d", p.turnNumber)
	if os.Getenv("MOKUSEI_CODEX_VOICE_CONFIGURATION_IDLE") != "1" {
		if err := p.event("turn/started", object{"threadId": p.session, "turn": object{"id": p.turn}}); err != nil {
			return true, err
		}
	}
	// The parent holds native execution admission. This is a real authenticated
	// bridge request from the native peer, not a direct call to the Go binding.
	toolErr := p.callTool()
	if err := os.WriteFile(filepath.Join(root, "voice-configuration-tool.json"), encoded(object{"rejected": toolErr != nil}), 0600); err != nil {
		return true, err
	}
	if os.Getenv("MOKUSEI_CODEX_VOICE_CONFIGURATION_IDLE") == "1" {
		return true, p.event("thread/realtime/transcript/done", object{"threadId": p.session, "role": "assistant", "text": voiceConfigurationBarrier})
	}
	return true, nil
}

type voiceConfigurationAdmission struct {
	store     *memoryStore
	entered   chan struct{}
	release   chan struct{}
	once      sync.Once
	err       error
	projected atomic.Int64
	cancelled chan struct{}
}

func (a *voiceConfigurationAdmission) Accept(ctx context.Context, project func(string) (json.RawMessage, error)) (string, error) {
	a.once.Do(func() { close(a.entered) })
	select {
	case <-a.release:
	case <-ctx.Done():
		if a.cancelled != nil {
			close(a.cancelled)
		}
		return "", ctx.Err()
	}
	if a.err != nil {
		return "", a.err
	}
	a.projected.Add(1)
	const id = "configuration-admitted-execution"
	state, err := project(id)
	if err == nil {
		err = a.store.Commit(ctx, state)
	}
	return id, err
}

type voiceConfigurationRecovery struct {
	request     plugin.VoiceDelegation
	err         error
	processGone bool
	bridgeGone  bool
}

func verifyVoiceConfiguration(ctx context.Context, root, binary string) error {
	for _, scenario := range []struct {
		name         string
		admissionErr error
		idle         bool
		closeRace    bool
		stopWaiting  bool
		cancelFails  bool
	}{
		{name: "exact-pending", admissionErr: plugin.ErrMokuConfigurationPending},
		{name: "generic-failure", admissionErr: errors.New("native admission failed")},
		{name: "joined-pending", admissionErr: errors.Join(plugin.ErrMokuConfigurationPending, errors.New("outcome is uncertain"))},
		{name: "idle-pending", idle: true},
		{name: "close-race", admissionErr: plugin.ErrMokuConfigurationPending, closeRace: true},
		{name: "admission-wins", closeRace: true},
		{name: "stop-while-waiting", stopWaiting: true},
		{name: "stop-cancellation-failure", stopWaiting: true, cancelFails: true},
	} {
		if err := verifyVoiceConfigurationCase(ctx, filepath.Join(root, scenario.name), binary, scenario.admissionErr, scenario.idle, scenario.closeRace, scenario.stopWaiting, scenario.cancelFails); err != nil {
			return fmt.Errorf("voice configuration %s: %w", scenario.name, err)
		}
	}
	fmt.Println("PASS native voice configuration: exact pending rejection retains one original handoff after process/bridge drain; generic/joined errors never recover; idle and in-flight close races preserve admission ownership; Stop cancels unadmitted voice input and preserves native cancellation failures")
	return verifyVoiceSpeechReceipt(ctx, filepath.Join(root, "speech-receipt"), binary)
}

func verifyVoiceConfigurationCase(parent context.Context, root, binary string, admissionErr error, idle, closeRace, stopWaiting, cancelFails bool) error {
	ctx, cancel := context.WithTimeout(parent, 15*time.Second)
	defer cancel()
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	env["MOKUSEI_CODEX_REPLAY_VOICE_CONFIGURATION"] = "1"
	if cancelFails {
		env["MOKUSEI_CODEX_REPLAY_VOICE_CANCEL_FAILURE"] = "1"
	}
	if idle {
		env["MOKUSEI_CODEX_VOICE_CONFIGURATION_IDLE"] = "1"
	}
	adapter := codex.New(host(root, env))
	defer adapter.Close()
	store := &memoryStore{}
	admission := &voiceConfigurationAdmission{store: store, entered: make(chan struct{}), release: make(chan struct{}), cancelled: make(chan struct{}), err: admissionErr}
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(admission.release) }) }
	sessionRecord := model.SessionRecord{ID: "voice-configuration-owner", Cwd: filepath.Join(root, "work"), CreatedAt: time.Now().UnixMilli(), Settings: encoded(object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "full-access"})}
	var toolCalls, requests atomic.Int64
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: sessionRecord.ID, ReadThread: func() model.SessionRecord { return sessionRecord }, SessionState: store, RequireExplicitSettings: true, ExecutionAdmission: admission,
		Injection: &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: []plugin.ToolBinding{{Name: "echo_fixture", Description: "Configuration admission fixture", InputSchema: encoded(object{"type": "object", "properties": object{"text": object{"type": "string"}}}), Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
			toolCalls.Add(1)
			return encoded(object{"text": "tool works"}), nil
		}}}}},
	})
	if err != nil {
		return err
	}
	defer handle.Close()
	voice, err := handle.(plugin.NativeVoiceCapability).PrepareNativeVoice(ctx, nil)
	if err != nil {
		return err
	}
	defer voice.Stop(context.WithoutCancel(ctx))
	defer release()
	answer, err := voice.Start(ctx, "fixture-offer")
	if err != nil {
		return err
	}
	if answer != "fixture-answer-sdp" {
		return errors.New("configuration replay did not start the native V3 media session")
	}
	closer, ok := voice.(plugin.VoiceConfigurationCloser)
	if !ok {
		return errors.New("native voice does not provide configuration close")
	}
	recovered := make(chan voiceConfigurationRecovery, 4)
	unsubscribe := voice.(plugin.VoiceConfigurationRecoverySource).OnConfigurationRecovery(func(request plugin.VoiceDelegation, recoveryErr error) {
		data, readErr := os.ReadFile(filepath.Join(root, "voice-configuration-peer.json"))
		info := decoded(data)
		pid, _ := info["pid"].(float64)
		processGone := readErr == nil && pid > 0 && errors.Is(syscall.Kill(int(pid), 0), syscall.ESRCH)
		bridgeGone := readErr == nil && !voiceConfigurationBridgeAvailable(record(info["bridge"]))
		recovered <- voiceConfigurationRecovery{request, recoveryErr, processGone, bridgeGone}
	})
	defer unsubscribe()
	unsubscribeRequest := voice.(plugin.VoiceRequestSource).OnRequest(func(context.Context, plugin.VoiceDelegation, string) error { requests.Add(1); return nil })
	defer unsubscribeRequest()
	barrier := make(chan struct{}, 1)
	unsubscribeEvent := voice.OnEvent(func(event plugin.VoiceEvent) {
		if event.Type == "transcript" && event.Text != nil && *event.Text == voiceConfigurationBarrier {
			select {
			case barrier <- struct{}{}:
			default:
			}
		}
	})
	defer unsubscribeEvent()
	if err := voice.(plugin.VoiceContextSync).SyncContext(ctx, []plugin.ContextEntry{{ID: "configuration", Content: "fixture-voice-configuration"}}); err != nil {
		return err
	}
	if !idle {
		select {
		case <-admission.entered:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	toolResult, err := awaitVoiceConfigurationFile(ctx, filepath.Join(root, "voice-configuration-tool.json"))
	if err != nil {
		return err
	}
	toolRejected, _ := decoded(toolResult)["rejected"].(bool)
	if !toolRejected || toolCalls.Load() != 0 || admission.projected.Load() != 0 {
		return errors.New("unadmitted native execution reached a tool or durable projection")
	}
	peerData, err := os.ReadFile(filepath.Join(root, "voice-configuration-peer.json"))
	if err != nil {
		return err
	}
	if !voiceConfigurationBridgeAvailable(record(decoded(peerData)["bridge"])) {
		return errors.New("native tool rejection did not exercise a live MCP bridge")
	}
	if stopWaiting {
		stopDone := make(chan error, 1)
		go func() { stopDone <- voice.Stop(ctx) }()
		select {
		case <-admission.cancelled:
		case <-time.After(3 * time.Second):
			return errors.New("Stop did not cancel native voice admission while the configuration gate remained occupied")
		case <-ctx.Done():
			return ctx.Err()
		}
		release()
		select {
		case err := <-stopDone:
			if cancelFails {
				if err == nil || !strings.Contains(err.Error(), "fixture native voice cancellation rejected") {
					return fmt.Errorf("Stop hid native cancellation failure: %v", err)
				}
			} else if err != nil {
				return fmt.Errorf("Stop while native admission waited: %w", err)
			}
		case <-ctx.Done():
			return ctx.Err()
		}
		if err := handle.Close(); err != nil && (!cancelFails || !strings.Contains(err.Error(), "fixture native voice cancellation rejected")) {
			return fmt.Errorf("close after cancelling native admission: %w", err)
		}
		if len(recovered) != 0 || requests.Load() != 0 || admission.projected.Load() != 0 || toolCalls.Load() != 0 {
			return errors.New("stopped queued voice request acquired execution, recovery or tool authority")
		}
		observation, err := adapter.SessionState().Project(store.Read())
		if err != nil {
			return err
		}
		if observation.LatestExecution != nil {
			return errors.New("stopped queued voice request was durably admitted")
		}
		return nil
	}
	var closeDone chan error
	if closeRace {
		closeDone = make(chan error, 1)
		go func() { closeDone <- closer.CloseForConfiguration(ctx) }()
		select {
		case err := <-closeDone:
			return fmt.Errorf("configuration close bypassed in-flight admission: %v", err)
		case <-recovered:
			return errors.New("configuration recovery ran before admission ownership settled")
		case <-time.After(50 * time.Millisecond):
		}
	}
	if idle {
		select {
		case <-barrier:
		case <-ctx.Done():
			return ctx.Err()
		}
		if err := closer.CloseForConfiguration(ctx); err != nil {
			return err
		}
	}
	release()
	if closeRace && admissionErr == nil {
		select {
		case err := <-closeDone:
			if err == nil {
				return errors.New("configuration close retired an admitted execution")
			}
		case <-ctx.Done():
			return ctx.Err()
		}
		if admission.projected.Load() != 1 || requests.Load() != 1 || voice.Closed() {
			return errors.New("configuration close disrupted the winning native admission")
		}
		if len(recovered) != 0 {
			return errors.New("an admitted native request was offered for replay")
		}
		return handle.Interrupt(ctx)
	}
	if idle || admissionErr == plugin.ErrMokuConfigurationPending {
		select {
		case recovery := <-recovered:
			if recovery.err != nil || !recovery.processGone || !recovery.bridgeGone {
				return fmt.Errorf("recovery preceded native process/bridge drain: processGone=%t bridgeGone=%t cleanup=%v", recovery.processGone, recovery.bridgeGone, recovery.err)
			}
			if recovery.request.ID != voiceConfigurationRequestID || recovery.request.Text != voiceConfigurationText || recovery.request.Context != string(encoded(voiceConfigurationTranscript)) || recovery.request.Generation != 1 {
				return fmt.Errorf("recovery changed the captured handoff: %+v", recovery.request)
			}
		case <-ctx.Done():
			return ctx.Err()
		}
		if closeDone != nil {
			select {
			case err := <-closeDone:
				if err != nil {
					return err
				}
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		if err := closer.CloseForConfiguration(ctx); err != nil {
			return err
		}
	} else {
		// Let the rejected native notification itself terminate its peer before
		// caller cleanup. Otherwise cancelling admission here could mask a bug
		// that incorrectly recovers a generic/joined failure.
		pid, _ := decoded(peerData)["pid"].(float64)
		for !errors.Is(syscall.Kill(int(pid), 0), syscall.ESRCH) {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Millisecond):
			}
		}
		// Join the real native owner before deciding that no recovery callback
		// exists. No timing-based grace period can prove this negative result.
		if err := handle.Close(); err != nil {
			return err
		}
		if err := closer.CloseForConfiguration(ctx); err != nil {
			return err
		}
	}
	if len(recovered) != 0 || requests.Load() != 0 || admission.projected.Load() != 0 || toolCalls.Load() != 0 {
		return errors.New("rejected native request recovered twice or acquired execution/tool authority")
	}
	observation, err := adapter.SessionState().Project(store.Read())
	if err != nil {
		return err
	}
	if observation.LatestExecution != nil {
		return errors.New("rejected native start created a durable execution")
	}
	return nil
}

func awaitVoiceConfigurationFile(ctx context.Context, path string) ([]byte, error) {
	for {
		data, err := os.ReadFile(path)
		if err == nil && json.Valid(data) {
			return data, nil
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Millisecond):
		}
	}
}

func voiceConfigurationBridgeAvailable(bridge object) bool {
	request, err := http.NewRequest(http.MethodPost, text(bridge["url"]), bytes.NewReader(encoded(object{"jsonrpc": "2.0", "id": 99, "method": "ping"})))
	if err != nil {
		return false
	}
	request.Header.Set("Content-Type", "application/json")
	for key, value := range record(bridge["http_headers"]) {
		request.Header.Set(key, text(value))
	}
	response, err := (&http.Client{Timeout: time.Second}).Do(request)
	if err != nil {
		return false
	}
	response.Body.Close()
	return true
}
