package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

// SQLite settings and the actual coordinator injection must agree across a
// close/reopen. The external native engine is the existing replay fixture.
func runRoutingPreferencesReplay() error {
	root, err := os.MkdirTemp("", "mokusei-routing-preferences-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	for _, preset := range []string{"economy", "balanced", "performance", "custom"} {
		directory := filepath.Join(root, preset)
		h := &replayNativeHarness{nativeModel: "gpt-6-luna", wake: make(chan struct{}, 128)}
		s := startReplaySystem(directory, h)
		settings, revision, err := s.r.Settings()
		mokuReplayMust(err)
		invalid := settings
		invalid.Moku.RoutingPreset = "unknown"
		_, invalidErr := s.r.UpdateSettings(mokuReplayContext(), revision, invalid)
		mokuReplayCheck(invalidErr != nil, "unknown routing preset was accepted")
		settings.Moku.RoutingGuidance = mokuReplayString("retained manual policy")
		if preset != "custom" {
			settings.Moku.RoutingPreset = preset
		}
		result, err := s.r.UpdateSettings(mokuReplayContext(), revision, settings)
		mokuReplayMust(err)
		mokuReplayCheck(result.Status == "saved", "routing preset did not save")
		s.close()
		h = &replayNativeHarness{nativeModel: "gpt-6-luna", wake: make(chan struct{}, 128)}
		s = startReplaySystem(directory, h)
		restored, _, err := s.r.Settings()
		mokuReplayMust(err)
		mokuReplayCheck(restored.Moku.RoutingPreset == settings.Moku.RoutingPreset && *restored.Moku.RoutingGuidance == "retained manual policy", "restart lost preset or custom text")
		mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("inspect routing preferences")))
		h.mu.Lock()
		instructions := ""
		for _, handle := range h.handles {
			if handle.open.Injection != nil {
				instructions = strings.Join(handle.open.Injection.Instructions, "\n")
			}
		}
		h.mu.Unlock()
		guidance := moku.ModelRoutingGuidance(restored.Moku)
		if preset == "balanced" {
			mokuReplayCheck(guidance == "" && instructions == moku.DefaultSystemPrompt(), "balanced preference changed or duplicated the pre-preset default instructions")
		} else {
			mokuReplayCheck(strings.Contains(instructions, "Model routing guidance:\n"+guidance), "routing preference missing from native injection")
		}
		if preset == "custom" {
			mokuReplayCheck(guidance == "retained manual policy", "custom preference changed")
		} else {
			if preset != "balanced" {
				mokuReplayCheck(strings.HasPrefix(guidance, strings.ToUpper(preset[:1])+preset[1:]+":"), "wrong preset guidance injected")
			}
			mokuReplayCheck(!strings.Contains(instructions, "retained manual policy"), "preset included retained custom text")
			mokuReplayCheck(!strings.Contains(guidance, "Candidate groups:") && !strings.Contains(guidance, "gpt-") && !strings.Contains(guidance, "listed"), "preset still restricts routing to fixed candidates")
		}
		s.close()
	}
	fmt.Println("PASS routing preferences: SQLite save/restart, retained custom text, actual native injection, general routing priorities without fixed candidate groups")
	return nil
}
