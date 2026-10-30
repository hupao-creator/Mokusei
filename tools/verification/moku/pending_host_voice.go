package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// A saved host preference applies lazily, on the next coordinator ensure. Voice
// preparation is such an ensure, and it runs while holding its own service
// admission; that admission must not be mistaken for unrelated work when the
// pending host replacement asks for the harness-change gate.
func runPendingHostVoiceReplay() error {
	root, err := os.MkdirTemp("", "mokusei-pending-host-voice-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	s, _ := startRelaySettingsReplay(filepath.Join(root, "pending-host"))
	defer func() { _ = s.close() }()
	mokuReplayMust(saveReplayHostRuntime(s.r, "mock"))
	media, err := s.prepare(voiceReplayRequestID)
	mokuReplayMust(err)
	mokuReplayCheck(s.record().HarnessID == "mock", "relay fixture chose the wrong initial host")
	_, err = s.command("moku:voice", map[string]any{"action": "stop", "sessionId": media.ID()})
	mokuReplayMust(err)

	mokuReplayMust(saveReplayHostRuntime(s.r, "other"))
	next, err := s.prepare(voiceReplayRejectedInputID)
	mokuReplayMust(err)
	mokuReplayCheck(next.lifetime.Err() == nil, "voice prepared against a retired lifetime")
	mokuReplayCheck(s.record().HarnessID == "other", "voice preparation did not adopt the pending host preference")
	_, err = s.command("moku:voice", map[string]any{"action": "stop", "sessionId": next.ID()})
	mokuReplayMust(err)
	fmt.Println("PASS voice: pending Moku host preference is adopted by voice preparation")
	return nil
}
