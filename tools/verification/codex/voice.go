package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The focused replay uses the same JSON-RPC peer and production adapter without
// unrelated process-group/crash scenarios. It allocates no audio hardware.
func runSyntheticVoice(ctx context.Context, root string) error {
	environment, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	environment["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	environment["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	self, err := os.Executable()
	if err != nil {
		return err
	}
	binary := filepath.Join(root, "codex-fixture")
	if err = os.Symlink(self, binary); err != nil {
		return err
	}
	adapter := codex.New(host(root, environment))
	defer adapter.Close()
	// Select only this disposable native peer through the existing environment
	// discovery path; no installed Codex or user credentials are consulted.
	environment["PATH"] = root + ":" + environment["PATH"]
	if err = os.Symlink(self, filepath.Join(root, "codex")); err != nil {
		return err
	}
	voice, err := adapter.PrepareVoice(ctx, "Local voice event replay")
	if err != nil {
		return err
	}
	defer voice.Stop(context.WithoutCancel(ctx))
	if err = verifyVoiceEvents(ctx, voice); err != nil {
		return err
	}
	if err = verifyVoiceCompatibility(ctx, root, environment); err != nil {
		return err
	}
	if err = verifyLaunchCatalogCache(ctx, root, binary, environment); err != nil {
		return err
	}
	return verifyNativeVoicePrewarm(ctx, root, binary, environment)
}

func verifyVoiceCompatibility(ctx context.Context, root string, environment map[string]string) error {
	for _, scenario := range []struct {
		name, userAgent, rejection string
		code                       int
	}{
		{name: "future", userAgent: "codex-cli/9.0.0-alpha.1 (fixture)"},
		{name: "unversioned", userAgent: "custom-native-client"},
		{name: "missing-version"},
		{name: "missing-method", userAgent: "codex-cli/0.163.0 (fixture)", rejection: "method", code: -32601},
		{name: "unsupported-protocol", userAgent: "codex-cli/0.164.0 (fixture)", rejection: "protocol", code: -32602},
	} {
		env := make(map[string]string, len(environment))
		for key, value := range environment {
			env[key] = value
		}
		env["MOKUSEI_CODEX_REPLAY_USER_AGENT"] = scenario.userAgent
		env["MOKUSEI_CODEX_REPLAY_VOICE_REJECTION"] = scenario.rejection
		capture := filepath.Join(root, scenario.name+"-voice.jsonl")
		env["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"] = capture
		adapter := codex.New(host(root, env))
		err := func() error {
			defer adapter.Close()
			voice, err := adapter.PrepareVoice(ctx, "Offline protocol compatibility replay")
			if err != nil {
				return fmt.Errorf("%s preparation: %w", scenario.name, err)
			}
			defer voice.Stop(context.WithoutCancel(ctx))
			if scenario.code == 0 {
				return verifyVoiceEvents(ctx, voice)
			}
			answer, err := voice.Start(ctx, "fixture-offer")
			var rpc *codex.RPCError
			if answer != "" || !errors.As(err, &rpc) || rpc.Code != scenario.code {
				return fmt.Errorf("%s lost native protocol rejection: answer=%q error=%v", scenario.name, answer, err)
			}
			message := "thread/realtime/start is not supported"
			if scenario.rejection == "protocol" {
				message = "realtime V3 transport is not supported"
			}
			if rpc.Message != message {
				return fmt.Errorf("%s lost native error detail: %v", scenario.name, err)
			}
			if !strings.Contains(err.Error(), "Codex 无法接受 V3 语音启动请求（方法或参数不兼容）") || !strings.Contains(err.Error(), message) {
				return fmt.Errorf("%s lost actionable protocol diagnostic: %v", scenario.name, err)
			}
			events, pollErr := voice.Poll(0)
			if pollErr != nil {
				return pollErr
			}
			diagnostic := false
			for _, event := range events {
				if event.Type == "error" && event.Text != nil && *event.Text == err.Error() {
					diagnostic = true
				}
			}
			if !diagnostic {
				return fmt.Errorf("%s did not publish its startup diagnostic", scenario.name)
			}
			if err := voice.Stop(ctx); err != nil {
				return err
			}
			if !voice.Closed() || launchCount(capture, "realtime.start") != 1 {
				return fmt.Errorf("%s did not close after a single rejected start", scenario.name)
			}
			if _, err := voice.Start(ctx, "fixture-offer"); err == nil {
				return fmt.Errorf("%s reused a rejected voice session", scenario.name)
			}
			return nil
		}()
		if err != nil {
			return err
		}
	}
	fmt.Println("PASS voice compatibility follows native V3 calls, independent of version; RPC rejection preserved without retry")
	return nil
}

func verifyVoiceEvents(ctx context.Context, voice plugin.VoiceSession) error {
	sdp, e := voice.Start(ctx, "fixture-offer")
	if e != nil {
		return e
	}
	if e = check(sdp == "fixture-answer-sdp", "voice SDP mismatch"); e != nil {
		return e
	}
	var voiceEvents []plugin.VoiceEvent
	for deadline := time.Now().Add(3 * time.Second); ; {
		voiceEvents, e = voice.Poll(0)
		if e != nil {
			return e
		}
		if len(voiceEvents) >= 10 {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("voice transcript fixture timed out")
		}
		time.Sleep(time.Millisecond)
	}
	firstUser, secondUser, greeting := "", "", ""
	for _, event := range voiceEvents {
		if event.Type != "transcript" {
			continue
		}
		if event.Role == "user" && event.Text != nil {
			switch *event.Text {
			case "hello":
				greeting = event.ItemID
			case "voice ", "voice request":
				firstUser = event.ItemID
			case "new request":
				secondUser = event.ItemID
			}
		}
		if event.Role == "assistant" && event.Text != nil && event.ReplyToItemID != "" {
			return fmt.Errorf("unidentified assistant segment guessed ASR identity")
		}
	}
	if greeting == "" || firstUser == "" || secondUser == "" || firstUser == secondUser {
		return fmt.Errorf("ASR items were not distinct")
	}
	if e = voice.Speak(ctx, plugin.VoiceSpeech{DeliveryID: "fixture-reply", DelegationID: "fixture-voice-handoff", Generation: 1, Text: "Moku feedback"}); e != nil {
		return e
	}
	voiceEvents, e = voice.Poll(0)
	if e != nil {
		return e
	}
	matched := false
	for _, event := range voiceEvents {
		if event.Type == "answer" {
			matched = event.SessionID == voice.ID() && event.ReplyToItemID == firstUser && event.ReplyToItemID != secondUser
		}
	}
	if !matched {
		return fmt.Errorf("late Moku answer was not bound to its original ASR item")
	}
	handoffBeforeFinalEvents, err := verifyHandoffBeforeFinalEvents(ctx, voice, voiceEvents[len(voiceEvents)-1].Sequence)
	if err != nil {
		return err
	}
	feedbackBeforeFinalEvents, err := verifyFeedbackBeforeFinalEvents(ctx, voice, handoffBeforeFinalEvents[len(handoffBeforeFinalEvents)-1].Sequence)
	if err != nil {
		return err
	}
	if path := os.Getenv("MOKUSEI_VOICE_EVENT_EXPORT"); path != "" {
		data, err := json.MarshalIndent(map[string]any{"sessionId": voice.ID(), "events": voiceEvents, "handoffBeforeFinalEvents": handoffBeforeFinalEvents, "feedbackBeforeFinalEvents": feedbackBeforeFinalEvents}, "", "  ")
		if err != nil {
			return err
		}
		if err = os.WriteFile(path, data, 0600); err != nil {
			return err
		}
	}
	if e = voice.Stop(ctx); e != nil {
		return e
	}
	fmt.Println("PASS synthetic voice context / SDP / ASR feedback identity / poll / stop")
	return nil
}

func verifyHandoffBeforeFinalEvents(ctx context.Context, voice plugin.VoiceSession, after int64) ([]plugin.VoiceEvent, error) {
	syncer, ok := voice.(plugin.VoiceContextSync)
	if !ok {
		return nil, fmt.Errorf("voice fixture lacks production context sync")
	}
	if err := syncer.SyncContext(ctx, []plugin.ContextEntry{{ID: "fixture-handoff-before-final", Content: "Replay the handoff before the ASR final."}}); err != nil {
		return nil, err
	}
	var events []plugin.VoiceEvent
	poll := func(count int) error {
		for deadline := time.Now().Add(3 * time.Second); ; {
			var err error
			events, err = voice.Poll(after)
			if err != nil {
				return err
			}
			if len(events) >= count {
				return nil
			}
			if time.Now().After(deadline) {
				return fmt.Errorf("handoff-before-final fixture timed out at %d/%d events", len(events), count)
			}
			time.Sleep(time.Millisecond)
		}
	}
	if err := poll(3); err != nil {
		return nil, err
	}
	partial, input, final := events[0], events[1], events[2]
	if partial.Type != "transcript" || partial.Role != "user" || partial.Text == nil || *partial.Text != "partial" || partial.Complete == nil || *partial.Complete || input.Type != "input" || input.InputID != "" || input.Generation == nil || partial.Generation == nil || *partial.Generation != *input.Generation-1 || final.Type != "transcript" || final.ItemID != partial.ItemID || final.Text == nil || *final.Text != "complete request" || final.Complete == nil || !*final.Complete {
		return nil, fmt.Errorf("handoff-before-final fixture lost its ordered ASR/generation boundary")
	}
	speech := plugin.VoiceSpeech{DeliveryID: "fixture-unmapped-reply", DelegationID: "fixture-handoff-before-final", Generation: *input.Generation, Text: "Moku handoff-before-final feedback"}
	if err := voice.Speak(ctx, speech); err != nil {
		return nil, err
	}
	if err := poll(6); err != nil {
		return nil, err
	}
	if events[3].Type != "answer" || events[3].SessionID != voice.ID() || events[3].ReplyToItemID != partial.ItemID || events[3].Generation == nil || *events[3].Generation != *input.Generation || events[5].Type != "transcript" || events[5].Role != "user" || events[5].ItemID == partial.ItemID || events[5].Text == nil || *events[5].Text != "newer request after feedback" {
		return nil, fmt.Errorf("late ASR final did not bind its answer or preserve the newer ASR fixture")
	}
	if err := voice.Speak(ctx, speech); err != nil {
		return nil, err
	}
	duplicate, err := voice.Poll(events[len(events)-1].Sequence)
	if err != nil || len(duplicate) != 0 {
		return nil, fmt.Errorf("duplicate delivery generated new events: %v", err)
	}
	speech.DeliveryID = "fixture-unmapped-late-reply"
	speech.Text = "Late feedback for the earlier handoff"
	if err := voice.Speak(ctx, speech); err != nil {
		return nil, err
	}
	if err := poll(8); err != nil {
		return nil, err
	}
	if events[6].Type != "answer" || events[6].ReplyToItemID != partial.ItemID || events[6].Generation == nil || *events[6].Generation != *input.Generation {
		return nil, fmt.Errorf("late feedback lost its original ASR identity")
	}
	fmt.Println("PASS synthetic voice handoff-before-final / exact final binding / duplicate and late feedback")
	return events, nil
}

func verifyFeedbackBeforeFinalEvents(ctx context.Context, voice plugin.VoiceSession, after int64) ([]plugin.VoiceEvent, error) {
	syncer := voice.(plugin.VoiceContextSync)
	if err := syncer.SyncContext(ctx, []plugin.ContextEntry{{ID: "fixture-feedback-before-final", Content: "Replay feedback before the ASR final."}}); err != nil {
		return nil, err
	}
	events, err := pollVoiceEvents(voice, after, 2)
	if err != nil {
		return nil, err
	}
	partial, input := events[0], events[1]
	if partial.Type != "transcript" || partial.Role != "user" || input.Type != "input" || input.Generation == nil {
		return nil, fmt.Errorf("early feedback fixture lost its ASR/handoff boundary")
	}
	speech := plugin.VoiceSpeech{DeliveryID: "fixture-feedback-before-final-reply", DelegationID: "fixture-feedback-before-final", Generation: *input.Generation, Text: "Moku feedback before final"}
	if err = voice.Speak(ctx, speech); err != nil {
		return nil, err
	}
	events, err = pollVoiceEvents(voice, after, 7)
	if err != nil {
		return nil, err
	}
	initial, audio, final, resolved, newer := events[2], events[3], events[4], events[5], events[6]
	if initial.Type != "answer" || initial.ReplyToItemID != "" || initial.DeliveryID != speech.DeliveryID || audio.Type != "speech" || final.Type != "transcript" || final.ItemID != partial.ItemID || final.Complete == nil || !*final.Complete || resolved.Type != "answer" || resolved.ReplyToItemID != partial.ItemID || resolved.DeliveryID != initial.DeliveryID || newer.Type != "transcript" || newer.ItemID == partial.ItemID {
		return nil, fmt.Errorf("ASR final did not repair the original answer identity without replaying audio")
	}
	if err = voice.Speak(ctx, speech); err != nil {
		return nil, err
	}
	duplicate, err := voice.Poll(events[len(events)-1].Sequence)
	if err != nil || len(duplicate) != 0 {
		return nil, fmt.Errorf("repaired answer allowed duplicate delivery: %v", err)
	}
	speech.DeliveryID = "fixture-feedback-before-final-late-reply"
	speech.Text = "Late feedback after ASR identity repair"
	if err = voice.Speak(ctx, speech); err != nil {
		return nil, err
	}
	events, err = pollVoiceEvents(voice, after, 9)
	if err != nil {
		return nil, err
	}
	if events[7].Type != "answer" || events[7].ReplyToItemID != partial.ItemID {
		return nil, fmt.Errorf("repaired request acquired a newer ASR identity")
	}
	fmt.Println("PASS synthetic voice feedback-before-final / answer identity repair / no repeated speech")
	return events, nil
}

func pollVoiceEvents(voice plugin.VoiceSession, after int64, count int) ([]plugin.VoiceEvent, error) {
	for deadline := time.Now().Add(3 * time.Second); ; {
		events, err := voice.Poll(after)
		if err != nil {
			return nil, err
		}
		if len(events) >= count {
			return events, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("voice fixture timed out at %d/%d events", len(events), count)
		}
		time.Sleep(time.Millisecond)
	}
}
