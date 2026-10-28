package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	runtimepkg "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

type relaySettingsCatalog struct {
	mu    sync.Mutex
	model string
}

type relaySettingsHarness struct {
	*voiceReplayHarness
	catalog *relaySettingsCatalog
}

func (h *relaySettingsHarness) Settings() plugin.HarnessSettings {
	return relaySettingsAPI{replayNativeSettings: replayNativeSettings{h: h.replayNativeHarness}, catalog: h.catalog}
}

func (h *relaySettingsHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	handle, err := h.voiceReplayHarness.Open(ctx, open)
	if err != nil {
		return nil, err
	}
	return relaySettingsReplyHandle{Handle: handle, open: open}, nil
}

type relaySettingsReplyHandle struct {
	plugin.Handle
	open plugin.OpenContext
}

func (h relaySettingsReplyHandle) CompletedReply(id string) (string, bool) {
	execution := h.open.ReadThread().Observation.LatestExecution
	if execution == nil || execution.ExecutionID != id || execution.Status != "completed" || execution.Summary == nil {
		return "", false
	}
	return "Full native reply: " + *execution.Summary, true
}

type relaySettingsAPI struct {
	replayNativeSettings
	catalog *relaySettingsCatalog
}

func (s relaySettingsAPI) Describe(ctx context.Context, request plugin.SettingsRequest) (json.RawMessage, error) {
	if _, err := s.replayNativeSettings.Describe(ctx, request); err != nil {
		return nil, err
	}
	s.catalog.mu.Lock()
	modelID := s.catalog.model
	s.catalog.mu.Unlock()
	return mokuReplayRaw(map[string]any{"type": "object", "properties": map[string]any{"model": map[string]any{"type": "string", "enum": []string{modelID}}}, "required": []string{"model"}, "additionalProperties": false}), nil
}

func startRelaySettingsReplay(root string, configure ...func(*moku.Configuration, *runtimepkg.Runtime)) (*voiceReplaySystem, *relaySettingsCatalog) {
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	mokuReplayMust(err)
	base := &replayNativeHarness{db: db, nativeModel: "voice-model", wake: make(chan struct{}, 128)}
	factory := &voiceReplayFactory{}
	catalog := &relaySettingsCatalog{model: "first-target-model"}
	harnesses := map[string]plugin.Harness{}
	for _, id := range []string{"mock", "other"} {
		harnesses[id] = &relaySettingsHarness{voiceReplayHarness: &voiceReplayHarness{replayNativeHarness: base, id: id, factory: factory}, catalog: catalog}
	}
	r, err := runtimepkg.New(mokuReplayContext(), runtimepkg.Config{Store: db, Harnesses: harnesses, DataDir: root, DefaultCwd: root})
	mokuReplayMust(err)
	base.r = r
	configuration := newReplayConfiguration(root, r, base)
	configuration.Harnesses = harnesses
	configuration.Voice = factory
	for _, configure := range configure {
		configure(&configuration, r)
	}
	c, err := moku.New(configuration)
	mokuReplayMust(err)
	r.SetMoku(c)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "fixture"}))
	return &voiceReplaySystem{r: r, c: c, db: db, h: base, factory: factory, ownership: map[string]string{}}, catalog
}

func relaySettingsInjection(s *voiceReplaySystem) *plugin.Injection {
	s.h.mu.Lock()
	defer s.h.mu.Unlock()
	return s.h.handles[len(s.h.handles)-1].open.Injection
}

func relaySettingsTool(s *voiceReplaySystem, name string) plugin.ToolBinding {
	for _, tool := range relaySettingsInjection(s).Tools.Bindings {
		if tool.Name == name {
			return tool
		}
	}
	panic("missing relay fixture binding: " + name)
}

func runRelaySettingsChangeReplay() error {
	root, err := os.MkdirTemp("", "mokusei-relay-settings-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	s, catalog := startRelaySettingsReplay(filepath.Join(root, "continuous"))
	defer func() { _ = s.close() }()
	media, err := s.prepare(voiceReplayRequestID)
	mokuReplayMust(err)
	owner := s.record().ID
	mokuReplayCheck(s.record().HarnessID == "mock", "relay fixture chose the wrong initial host")
	save := func(change func(*model.Settings)) {
		settings, revision, err := s.r.Settings()
		mokuReplayMust(err)
		change(&settings)
		result, err := s.r.UpdateSettings(mokuReplayContext(), revision, settings)
		mokuReplayMust(err)
		mokuReplayCheck(result.Status == "saved", "relay settings save conflicted")
	}
	count := 0
	speak := func(id string) {
		count++
		media.delegate(plugin.VoiceDelegation{ID: id, Text: id, Generation: int64(count)})
		s.h.awaitTools(count)
		mokuReplayCheck(s.record().ID == owner && !media.Closed(), "same-owner configuration replacement retired relay media")
		mokuReplayCheck(voiceReplayHasMessage(s.record(), id), "relay input was not durably admitted")
		s.complete("answer to " + id)
		speech := voiceReplayWaitSpeech(media)
		mokuReplayCheck(speech.Text == "answer to "+id && speech.DelegationID == id && speech.DeliveryID == media.ID()+":"+id && speech.Generation == int64(count), "relay configuration change lost spoken reply ownership")
	}
	speak("initial relay request")
	oldTalk := relaySettingsTool(s, "talk")
	save(func(settings *model.Settings) {
		settings.Moku.RoutingGuidance = mokuReplayString("new relay routing guidance")
	})
	speak("routing change")
	mokuReplayCheck(strings.Contains(strings.Join(relaySettingsInjection(s).Instructions, "\n"), "new relay routing guidance"), "relay engine retained old routing instructions")
	_, err = oldTalk.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]string{"text": "retired binding"})})
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "retired settings generation"), "preserving relay media retained retired tool authority")

	s.h.mu.Lock()
	s.h.nativeModel = "new-host-model"
	s.h.mu.Unlock()
	save(func(settings *model.Settings) {
		settings.Moku.ExecutionHarnesses["mock"] = mokuReplayRaw(map[string]any{"useDefaultThreadSettings": false, "threadSettings": map[string]string{"model": "new-host-model"}})
	})
	speak("model change")
	mokuReplayCheck(replaySettingsModel(s.record().Settings) == "new-host-model", "relay execution retained old host model")

	save(func(settings *model.Settings) { settings.Moku.TargetHarnessIDs = []string{"other"} })
	speak("dispatch target change")
	var schema struct {
		Properties struct {
			Harness struct {
				Enum []string `json:"enum"`
			} `json:"harnessId"`
		} `json:"properties"`
	}
	mokuReplayMust(json.Unmarshal(relaySettingsTool(s, "create_thread").InputSchema, &schema))
	mokuReplayCheck(len(schema.Properties.Harness.Enum) == 1 && schema.Properties.Harness.Enum[0] == "other", "relay tools retained removed dispatch target")

	// A relay is independent of target tool discovery too. Its long-lived media
	// must not pin the first catalog until the user disconnects.
	catalog.mu.Lock()
	catalog.model = "refreshed-target-model"
	catalog.mu.Unlock()
	speak("native target catalog change")
	mokuReplayCheck(strings.Contains(string(relaySettingsTool(s, "create_thread").InputSchema), "refreshed-target-model"), "relay media prevented idle target schema refresh")
	mokuReplayCheck(s.factory.last() == media, "same-owner changes prepared replacement media")

	save(func(settings *model.Settings) { settings.Moku.HostHarnessPreference = "other" })
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("typed host replacement")))
	s.h.awaitTools(count + 1)
	mokuReplayCheck(media.Closed() && s.record().ID != owner && s.record().HarnessID == "other", "host replacement retained the old relay owner")
	old, err := s.r.Thread(owner)
	mokuReplayMust(err)
	mokuReplayCheck(old.MokuHistory, "relay host replacement lost read-only native history")
	_, err = s.command("moku:voice", map[string]any{"action": "heartbeat", "sessionId": media.ID()})
	mokuReplayCheck(err != nil, "retired relay retained media command authority")
	mokuReplayMust(s.close())

	broken := startVoiceReplay(filepath.Join(root, "cleanup"), "mock", &voiceReplayFactory{stopError: errors.New("relay cleanup failed")})
	defer func() { _ = broken.close() }()
	brokenMedia, err := broken.prepare(voiceReplayRequestID)
	mokuReplayMust(err)
	_, err = broken.command("moku:voice", map[string]any{"action": "stop", "sessionId": brokenMedia.ID()})
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "relay cleanup failed"), "relay cleanup failure disappeared")
	settings, revision, err := broken.r.Settings()
	mokuReplayMust(err)
	settings.Moku.RoutingGuidance = mokuReplayString("cannot bypass failed media cleanup")
	_, err = broken.r.UpdateSettings(mokuReplayContext(), revision, settings)
	mokuReplayMust(err)
	err = broken.c.Submit(mokuReplayContext(), mokuReplayText("must not bypass failed cleanup"))
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "relay cleanup failed"), "configuration replacement bypassed failed relay cleanup")
	replayRelayPendingSpeech(filepath.Join(root, "pending-speech"))
	fmt.Println("PASS relay settings: routing, model, dispatch and catalog changes preserve media and exact spoken delivery; retired tools, replaced owners and failed cleanup stay fenced")
	return nil
}

func replayRelayPendingSpeech(root string) {
	settlementEntered, settlementRelease := make(chan struct{}), make(chan struct{})
	discoveryEntered, discoveryRelease := make(chan struct{}), make(chan struct{})
	var settlementOnce, discoveryOnce sync.Once
	var pauseSettlement, pauseDiscovery sync.Once
	releaseSettlement := func() { settlementOnce.Do(func() { close(settlementRelease) }) }
	releaseDiscovery := func() { discoveryOnce.Do(func() { close(discoveryRelease) }) }
	s, _ := startRelaySettingsReplay(root, func(configuration *moku.Configuration, r *runtimepkg.Runtime) {
		configuration.CompletedReply = r.CompletedReply
		configuration.UpdateThread = func(ctx context.Context, id string, change func(*model.ThreadRecord) error) error {
			record, err := r.Thread(id)
			if err != nil {
				return err
			}
			// Hold the existing terminal audit boundary while configuration
			// replaces the engine. No native commit or Runtime lock is held.
			if execution := record.Observation.LatestExecution; execution != nil && execution.Terminal() {
				pauseSettlement.Do(func() {
					close(settlementEntered)
					select {
					case <-settlementRelease:
					case <-ctx.Done():
						err = ctx.Err()
					}
				})
				if err != nil {
					return err
				}
			}
			return r.UpdateThread(ctx, id, change)
		}
	})
	defer func() { _ = s.close() }()
	defer releaseDiscovery()
	defer releaseSettlement()
	media, err := s.prepare(voiceReplayRequestID)
	mokuReplayMust(err)
	media.delegate(plugin.VoiceDelegation{ID: "pending-reply", Text: "keep my full spoken reply", Generation: 4})
	s.h.awaitTools(1)
	completed := s.record()
	s.complete("short persisted summary")
	mokuReplayAwait("queued terminal speech settlement", settlementEntered)
	settings, revision, err := s.r.Settings()
	mokuReplayMust(err)
	settings.Moku.RoutingGuidance = mokuReplayString("reopen before queued speech delivery")
	_, err = s.r.UpdateSettings(mokuReplayContext(), revision, settings)
	mokuReplayMust(err)
	s.h.mu.Lock()
	s.h.describeFn = func(ctx context.Context) error {
		var err error
		pauseDiscovery.Do(func() {
			close(discoveryEntered)
			select {
			case <-discoveryRelease:
			case <-ctx.Done():
				err = ctx.Err()
			}
		})
		return err
	}
	s.h.mu.Unlock()
	done := make(chan error, 1)
	go func() {
		done <- s.c.Submit(mokuReplayContext(), mokuReplayText("next typed turn while speech is queued"))
	}()
	mokuReplayAwait("configuration gap before replacement handle opens", discoveryEntered)
	_, available := s.r.CompletedReply(completed.ID, completed.Observation.LatestExecution.ExecutionID)
	mokuReplayCheck(!available, "pending speech replay did not remove the original native handle")
	releaseSettlement()
	speech := voiceReplayWaitSpeech(media)
	mokuReplayCheck(speech.Text == "Full native reply: short persisted summary" && speech.DelegationID == "pending-reply" && speech.Generation == 4, "configuration replacement dropped or misattributed queued native speech")
	mokuReplayCheck(!media.Closed(), "pending speech recovery retired relay media")
	releaseDiscovery()
	mokuReplayWaitError("successor after pending speech", done)
	s.h.awaitTools(2)
	mokuReplayMust(s.close())
	fmt.Println("PASS relay pending speech: queued terminal delivery retains the original native reply across the handle close/reopen gap")
}
