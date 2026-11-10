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
		if preset == "custom" {
			mokuReplayCheck(strings.Contains(instructions, "retained manual policy"), "custom preference missing from native injection")
		} else {
			mokuReplayCheck(strings.Contains(instructions, "Candidate groups:") && !strings.Contains(instructions, "retained manual policy"), "preset did not replace effective guidance while retaining custom text")
			if preset == "performance" {
				mokuReplayCheck(!strings.Contains(instructions, `"model":"gpt-6-luna"`), "performance routed to economy catalog model")
			} else {
				mokuReplayCheck(strings.Contains(instructions, `"model":"gpt-6-luna"`), "available economy model omitted")
			}
		}
		// Cross-tier candidate generation is production code fed with native identities.
		description := moku.ThreadCreationDescription{RoutingModels: []moku.RoutingModel{
			{HarnessID: "mock", ID: "gpt-6-luna"}, {HarnessID: "mock", ID: "gpt-6-astra"}, {HarnessID: "mock", ID: "unknown-free-pro"},
		}}
		guidance := moku.ModelRoutingGuidance(restored.Moku, description)
		if preset != "custom" {
			mokuReplayCheck(!strings.Contains(guidance, "unknown-free-pro"), "unknown model acquired an inferred tier")
			mokuReplayCheck(strings.Contains(guidance, `"model":"gpt-6-astra"`) == (preset != "economy"), "frontier mapping does not match preset")
		}
		s.close()
	}
	fmt.Println("PASS routing preferences: SQLite save/restart, retained custom text, actual native injection, exact available-model groups and unknown-model exclusion")
	return nil
}
