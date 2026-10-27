package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func verifyNativeVoicePrewarm(ctx context.Context, root, binary string, env map[string]string) error {
	env["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"] = filepath.Join(root, "prewarm-launch.jsonl")
	capture := env["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"]
	adapter := codex.New(host(root, env))
	defer adapter.Close()
	store := &memoryStore{}
	record := model.SessionRecord{ID: "voice-prewarm-host", CreatedAt: time.Now().UnixMilli(), Cwd: filepath.Join(root, "work"), Settings: encoded(object{"executablePath": binary, "model": "gpt-6-luna", "sandbox": "read-only", "approvalPolicy": "never"})}
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: record.ID, ReadThread: func() model.SessionRecord { return record }, SessionState: store})
	if err != nil {
		return err
	}
	defer handle.Close()
	native := handle.(plugin.NativeVoiceCapability)
	prepare := func() (plugin.VoiceSession, error) {
		return native.PrepareNativeVoice(ctx, []plugin.ContextEntry{{ID: "replay", Content: "offline startup replay"}})
	}
	stopAndWarm := func(voice plugin.VoiceSession) error {
		count := launchCount(capture, "initialize")
		if err := verifyVoiceEvents(ctx, voice); err != nil {
			return err
		}
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for launchCount(capture, "initialize") == count {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-deadline.C:
				return fmt.Errorf("idle voice did not prewarm a replacement process")
			case <-time.After(time.Millisecond):
			}
		}
		return nil
	}
	voice, err := prepare()
	if err != nil {
		return err
	}
	if err = stopAndWarm(voice); err != nil {
		return err
	}
	warmCount := launchCount(capture, "initialize")
	voice, err = prepare()
	if err != nil {
		return err
	}
	if launchCount(capture, "initialize") != warmCount {
		return fmt.Errorf("voice reopen ignored its prewarmed fresh process")
	}
	// A consumed candidate is now an active voice owner. Later source changes
	// must not rotate it when text arrives through the same handle.
	env["MOKUSEI_CODEX_REPLAY_ACTIVE_ENV_CHANGE"] = "1"
	if err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "voice-active-text", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Hello"}}}}); err != nil {
		return err
	}
	if _, err = awaitExecution(ctx, adapter, store, handle, true); err != nil {
		return err
	}
	if launchCount(capture, "initialize") != warmCount {
		return fmt.Errorf("source change rotated a consumed voice candidate during text execution")
	}
	if err = stopAndWarm(voice); err != nil {
		return err
	}
	// Source configuration changes after prewarming must invalidate the process,
	// even though the installed executable and durable thread are unchanged.
	config := filepath.Join(root, "work", ".codex")
	if err = os.MkdirAll(config, 0700); err != nil {
		return err
	}
	defer os.RemoveAll(config)
	if err = os.WriteFile(filepath.Join(config, "config.toml"), []byte("model='changed-after-prewarm'\n"), 0600); err != nil {
		return err
	}
	warmCount = launchCount(capture, "initialize")
	voice, err = prepare()
	if err != nil {
		return err
	}
	if launchCount(capture, "initialize") <= warmCount {
		return fmt.Errorf("voice reused prewarmed configuration after source changed")
	}
	if err = stopAndWarm(voice); err != nil {
		return err
	}
	// Native account changes invalidate a prepared isolated-home candidate too.
	auth := filepath.Join(env["CODEX_HOME"], "auth.json")
	if err = os.WriteFile(auth, []byte(`{"OPENAI_API_KEY":"changed-local-fixture"}`), 0600); err != nil {
		return err
	}
	defer os.Remove(auth)
	warmCount = launchCount(capture, "initialize")
	voice, err = prepare()
	if err != nil {
		return err
	}
	if launchCount(capture, "initialize") <= warmCount {
		return fmt.Errorf("voice reused prewarmed account after source changed")
	}
	// Closing the handle immediately after stop must cancel/join its prewarm.
	if err = verifyVoiceEvents(ctx, voice); err != nil {
		return err
	}
	if err = handle.Close(); err != nil {
		return err
	}
	// A read-only discussion shares the source history home and needs only a
	// catalog plus its real fork process, never a throwaway config reader.
	record.SessionState = store.Read()
	beforeDiscussion := launchCount(capture, "initialize")
	discussion, err := adapter.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: record}, Instructions: "Read-only replay"})
	if err != nil {
		return err
	}
	if launchCount(capture, "initialize") != beforeDiscussion+1 {
		_ = discussion.Close()
		return fmt.Errorf("discussion launched a redundant configuration-reading process")
	}
	defer discussion.Close()
	discussionVoice, err := discussion.(plugin.NativeVoiceCapability).PrepareNativeVoice(ctx, nil)
	if err != nil {
		return err
	}
	if err = verifyVoiceEvents(ctx, discussionVoice); err != nil {
		return err
	}
	if err = discussion.Close(); err != nil {
		return err
	}
	fmt.Println("PASS read-only discussion restricted catalog / independent fork / no throwaway config process")
	fmt.Println("PASS native voice prewarm/reopen, source config/account invalidation and close during prewarm")
	return nil
}
