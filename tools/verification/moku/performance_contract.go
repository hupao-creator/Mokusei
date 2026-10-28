package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

func runContextReadContractReplay() error {
	w := newOrchestratorWorld()
	configuration := w.config()
	var reads atomic.Int64
	var unavailable atomic.Bool
	configuration.Threads = func() ([]model.ThreadRecord, error) {
		reads.Add(1)
		if unavailable.Load() {
			return nil, errors.New("fixture forbids an unnecessary full Thread read")
		}
		return w.threads()
	}
	c, err := moku.New(configuration)
	mokuReplayMust(err)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "fixture"}))
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("initialize context fixture")))
	reads.Store(0)
	unavailable.Store(true)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("no directory selection")))
	request := orchestratorInput("use the explicit directory")
	request.Input.Parts = append(request.Input.Parts, model.AgentInputPart{Kind: "mention", Name: "explicit", Path: "/fixture/explicit", PathType: "directory"})
	request.DirectoryTag = mokuReplayString("an unused selected tag")
	mokuReplayMust(c.Submit(mokuReplayContext(), request))
	mokuReplayCheck(reads.Load() == 0, "unneeded workspace hints read all Threads")
	w.mu.Lock()
	entries := append([]plugin.ContextEntry{}, w.sends[len(w.sends)-1].context...)
	w.records["same-name-source"] = model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "same-name-source", Cwd: "/other/selected", UpdatedAt: 2}}
	w.records["directory-source"] = model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "directory-source", Cwd: "/fixture/selected", UpdatedAt: 1}}
	w.mu.Unlock()
	mokuReplayCheck(contextContains(entries, "workspace", "/fixture/explicit"), "explicit directory hint was lost")
	unavailable.Store(false)
	tag := moku.ThreadDirectoryTag("/fixture/selected")
	request = orchestratorInput("use the selected directory tag")
	request.DirectoryTag = &tag
	scope := directorytag.Scope("/fixture/selected")
	request.DirectoryScopeID = &scope
	mokuReplayMust(c.Submit(mokuReplayContext(), request))
	mokuReplayCheck(reads.Load() == 1, "directory tag resolution did not read exactly one Thread snapshot")
	w.mu.Lock()
	entries = append([]plugin.ContextEntry{}, w.sends[len(w.sends)-1].context...)
	w.mu.Unlock()
	mokuReplayCheck(contextContains(entries, "workspace", "/fixture/selected"), "selected directory hint was lost")
	mokuReplayCheck(!contextContains(entries, "workspace", "/other/selected"), "same-name directory escaped its selected scope")
	unavailable.Store(true)
	mokuReplayCheck(c.Submit(mokuReplayContext(), request) != nil, "required directory snapshot failure was swallowed")
	fmt.Println("PASS Moku context reads Threads only for an unresolved directory tag, preserving hints and required-read errors")
	return nil
}

func contextContains(entries []plugin.ContextEntry, id, value string) bool {
	for _, entry := range entries {
		if entry.ID == id && strings.Contains(entry.Content, value) {
			return true
		}
	}
	return false
}

func runCompiledToolContractReplay() error {
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("initialize concurrent tool validation")))
	binding := w.binding("list_threads")
	const calls = 16
	ready := make(chan struct{})
	results := make(chan error, calls)
	var workers sync.WaitGroup
	for index := 0; index < calls; index++ {
		workers.Add(1)
		go func(index int) {
			defer workers.Done()
			<-ready
			arguments := json.RawMessage(`{"tags":["valid"]}`)
			invalid := index%2 != 0
			if invalid {
				arguments = json.RawMessage(`{"tags":["bad\u0000tag"]}`)
			}
			_, callErr := binding.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: arguments})
			if !invalid {
				results <- callErr
				return
			}
			var caller *plugin.ToolCallError
			if !errors.As(callErr, &caller) {
				results <- fmt.Errorf("concurrent invalid schema call lost its caller error: %v", callErr)
				return
			}
			results <- nil
		}(index)
	}
	close(ready)
	workers.Wait()
	close(results)
	for err := range results {
		mokuReplayMust(err)
	}
	completed, rejected := 0, 0
	for _, raw := range w.mokuRecord().Transcript {
		var item struct {
			Name        string `json:"name"`
			CompletedAt *int64 `json:"completedAt"`
			IsError     bool   `json:"isError"`
		}
		mokuReplayMust(json.Unmarshal(raw, &item))
		if item.Name == "list_threads" {
			mokuReplayCheck(item.CompletedAt != nil, "concurrent schema call was not settled in the audit")
			completed++
			if item.IsError {
				rejected++
			}
		}
	}
	mokuReplayCheck(completed == calls && rejected == calls/2, "concurrent fixed-schema calls changed audit outcomes")

	// Deferred targets keep admission authority in their current native schema,
	// even while the outer create_thread binding and its generation stay fixed.
	dynamicWorld := newOrchestratorWorld()
	dynamicWorld.settings.Moku.HostHarnessPreference = "mock"
	dynamicWorld.settings.Moku.TargetHarnessIDs = []string{"opencode"}
	dynamicWorld.settings.Harnesses["opencode"] = json.RawMessage(`{}`)
	configuration := dynamicWorld.config()
	var descriptions atomic.Int64
	configuration.Harnesses["opencode"] = performanceDynamicHarness{orchestratorHarness: orchestratorHarness{w: dynamicWorld}, descriptions: &descriptions}
	dynamic, err := moku.New(configuration)
	mokuReplayMust(err)
	mokuReplayMust(dynamic.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "fixture"}))
	defer stopOrchestrator(dynamic)
	mokuReplayMust(dynamic.Submit(mokuReplayContext(), orchestratorInput("initialize dynamic target schema")))
	create := dynamicWorld.binding("create_thread")
	invoke := func(modelID string) error {
		_, err := create.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{"worktree": false, "prompt": "delegate", "harnessId": "opencode", "options": map[string]string{"model": modelID}})})
		return err
	}
	mokuReplayMust(invoke("mock-model"))
	dynamicWorld.mu.Lock()
	dynamicWorld.schemaModel = "replacement-model"
	dynamicWorld.mu.Unlock()
	var caller *plugin.ToolCallError
	mokuReplayCheck(errors.As(invoke("mock-model"), &caller), "native schema change still admitted the retired model")
	mokuReplayMust(invoke("replacement-model"))
	mokuReplayCheck(descriptions.Load() == 3, "native target schema was not discovered for each creation admission")
	fmt.Println("PASS fixed tool schemas support concurrent first use and exact audited errors; dynamic target schemas remain fresh")
	return nil
}

type performanceDynamicHarness struct {
	orchestratorHarness
	descriptions *atomic.Int64
}

func (h performanceDynamicHarness) Descriptor() plugin.HarnessDescriptor {
	descriptor := h.orchestratorHarness.Descriptor()
	descriptor.ID = "opencode"
	return descriptor
}
func (h performanceDynamicHarness) DiscoverMokuTarget(context.Context, plugin.SettingsRequest) (json.RawMessage, plugin.Availability, error) {
	return nil, plugin.Availability{Available: true}, nil
}
func (h performanceDynamicHarness) Probe(context.Context, plugin.SettingsRequest, string) (plugin.Availability, error) {
	return plugin.Availability{Available: true}, nil
}
func (h performanceDynamicHarness) Settings() plugin.HarnessSettings {
	return performanceDynamicSettings{orchestratorSettings: orchestratorSettings{w: h.w}, descriptions: h.descriptions}
}

type performanceDynamicSettings struct {
	orchestratorSettings
	descriptions *atomic.Int64
}

func (s performanceDynamicSettings) Describe(ctx context.Context, request plugin.SettingsRequest) (json.RawMessage, error) {
	s.descriptions.Add(1)
	return s.orchestratorSettings.Describe(ctx, request)
}
