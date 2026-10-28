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
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func (p *peer) voiceReceiptFixture(method string, params object, id any) (bool, error) {
	capture := os.Getenv("MOKUSEI_CODEX_REPLAY_SPEECH_RECEIPT_CAPTURE")
	if method != "thread/realtime/appendSpeech" || capture == "" {
		return false, nil
	}
	file, err := os.OpenFile(capture, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return true, err
	}
	err = json.NewEncoder(file).Encode(object{"text": params["text"]})
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return true, errors.Join(err, closeErr)
	}
	if params["text"] == "fixture speech append uncertain" {
		return true, p.send(object{"id": id, "error": object{"code": -32000, "message": "fixture append outcome uncertain"}})
	}
	return true, p.send(object{"id": id, "result": object{}})
}

func verifyVoiceSpeechReceipt(parent context.Context, root, binary string) error {
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	defer cancel()
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	env["MOKUSEI_CODEX_REPLAY_VOICE_CONFIGURATION"] = "1"
	capture := filepath.Join(root, "speech-appends.jsonl")
	env["MOKUSEI_CODEX_REPLAY_SPEECH_RECEIPT_CAPTURE"] = capture
	adapter := codex.New(host(root, env))
	defer adapter.Close()
	store := &memoryStore{}
	sessionRecord := model.SessionRecord{ID: "speech-receipt-owner", Cwd: filepath.Join(root, "work"), CreatedAt: time.Now().UnixMilli(), Settings: encoded(object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "full-access"})}
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: sessionRecord.ID, ReadThread: func() model.SessionRecord { return sessionRecord }, SessionState: store, RequireExplicitSettings: true})
	if err != nil {
		return err
	}
	defer handle.Close()
	voice, err := handle.(plugin.NativeVoiceCapability).PrepareNativeVoice(ctx, nil)
	if err != nil {
		return err
	}
	defer voice.Stop(context.WithoutCancel(ctx))
	answer, err := voice.Start(ctx, "fixture-offer")
	if err != nil {
		return err
	}
	if answer != "fixture-answer-sdp" {
		return errors.New("speech receipt did not start the native V3 peer")
	}
	receipts, ok := voice.(plugin.VoiceSpeechReceipt)
	if !ok {
		return errors.New("native voice has no speech receipt capability")
	}
	ready, failures := make(chan plugin.VoiceEvent, 8), make(chan plugin.VoiceEvent, 8)
	unsubscribe := voice.OnEvent(func(event plugin.VoiceEvent) {
		switch event.Type {
		case "speech-ready":
			ready <- event
		case "speech-error":
			failures <- event
		}
	})
	defer unsubscribe()
	count := func(want int) error {
		data, err := os.ReadFile(capture)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		actual := 0
		for _, line := range strings.Split(string(data), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			if !json.Valid([]byte(line)) {
				return errors.New("native speech capture is not complete JSON")
			}
			actual++
		}
		if actual != want {
			return fmt.Errorf("native appendSpeech calls=%d, want %d", actual, want)
		}
		return nil
	}
	start := func(id, text string) (plugin.VoiceSpeech, <-chan error, error) {
		speech := plugin.VoiceSpeech{DeliveryID: id, Generation: voice.InputGeneration(), Text: text, RequireReceipt: true}
		done := make(chan error, 1)
		go func() { done <- voice.Speak(ctx, speech) }()
		select {
		case event := <-ready:
			if event.DeliveryID != id || event.Generation == nil || *event.Generation != speech.Generation {
				return speech, done, errors.New("speech readiness lost delivery/generation identity")
			}
		case err := <-done:
			return speech, done, fmt.Errorf("speech did not wait for a receipt: %v", err)
		case <-ctx.Done():
			return speech, done, ctx.Err()
		}
		return speech, done, nil
	}
	finish := func(done <-chan error) error {
		select {
		case err := <-done:
			return err
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	voice.FenceInput("receipt-first-input")
	first, done, err := start("receipt-first", "confirmed speech")
	if err != nil {
		return err
	}
	if err := receipts.ConfirmSpeech(ctx, first.DeliveryID, first.Generation-1); err != nil {
		return err
	}
	select {
	case err := <-done:
		return fmt.Errorf("stale receipt released pending speech: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	if err := count(0); err != nil {
		return err
	}
	if err := receipts.ConfirmSpeech(ctx, first.DeliveryID, first.Generation); err != nil {
		return err
	}
	if err := finish(done); err != nil {
		return err
	}
	if err := count(1); err != nil {
		return err
	}
	for i := 0; i < 2; i++ {
		if err := receipts.ConfirmSpeech(ctx, first.DeliveryID, first.Generation); err != nil {
			return err
		}
		if err := voice.Speak(ctx, first); err != nil {
			return err
		}
	}
	if err := count(1); err != nil {
		return err
	}

	fenced, done, err := start("receipt-fenced", "must not follow newer input")
	if err != nil {
		return err
	}
	voice.FenceInput("receipt-newer-input")
	if err := finish(done); err != nil {
		return err
	}
	if err := receipts.ConfirmSpeech(ctx, fenced.DeliveryID, fenced.Generation); err != nil {
		return err
	}
	if err := count(1); err != nil {
		return err
	}

	failed, done, err := start("receipt-failed", "fixture speech append uncertain")
	if err != nil {
		return err
	}
	if err := receipts.ConfirmSpeech(ctx, failed.DeliveryID, failed.Generation); err != nil {
		return err
	}
	if err := finish(done); err != nil {
		return err
	}
	select {
	case event := <-failures:
		if event.DeliveryID != failed.DeliveryID || event.Text == nil || !strings.Contains(*event.Text, "fixture append outcome uncertain") {
			return errors.New("append failure lost its speech-error identity")
		}
	case <-ctx.Done():
		return ctx.Err()
	}
	if err := receipts.ConfirmSpeech(ctx, failed.DeliveryID, failed.Generation); err != nil {
		return err
	}
	if err := voice.Speak(ctx, failed); err != nil {
		return err
	}
	if err := count(2); err != nil {
		return err
	}

	expired, done, err := start("receipt-timeout", "must not speak after timeout")
	if err != nil {
		return err
	}
	if err := finish(done); err == nil || !strings.Contains(err.Error(), "语音播放确认超时") {
		return fmt.Errorf("missing bounded native speech receipt timeout: %v", err)
	}
	if err := receipts.ConfirmSpeech(ctx, expired.DeliveryID, expired.Generation); err != nil {
		return err
	}
	if err := voice.Speak(ctx, expired); err != nil {
		return err
	}
	if err := count(2); err != nil {
		return err
	}

	stopped, done, err := start("receipt-stopped", "must not speak after Stop")
	if err != nil {
		return err
	}
	if err := voice.Stop(ctx); err != nil {
		return err
	}
	if err := finish(done); err != nil {
		return err
	}
	if err := receipts.ConfirmSpeech(ctx, stopped.DeliveryID, stopped.Generation); err != nil {
		return err
	}
	if err := voice.Speak(ctx, stopped); err != nil {
		return err
	}
	if err := count(2); err != nil {
		return err
	}
	fmt.Println("PASS native speech receipts: no append before exact acknowledgment, duplicate/stale acknowledgments never replay, newer input/Stop/10-second timeout cancel waiting speech, uncertain append failure sends once")
	return nil
}
