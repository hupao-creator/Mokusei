package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (s *voiceReplaySession) OnConfigurationRecovery(callback func(plugin.VoiceDelegation, error)) func() {
	s.mu.Lock()
	if s.configurationRecoveries == nil {
		s.configurationRecoveries = map[int]func(plugin.VoiceDelegation, error){}
	}
	s.nextHandler++
	id := s.nextHandler
	s.configurationRecoveries[id] = callback
	s.mu.Unlock()
	return func() { s.mu.Lock(); delete(s.configurationRecoveries, id); s.mu.Unlock() }
}

// This is the controlled native boundary's cleanup acknowledgement. Production
// Codex emits this capability only after a rejected, unadmitted native process
// and its tool bridge have drained successfully.
func (s *voiceReplaySession) configurationRecovered(request plugin.VoiceDelegation, err error) {
	s.mu.Lock()
	callbacks := []func(plugin.VoiceDelegation, error){}
	for _, callback := range s.configurationRecoveries {
		callbacks = append(callbacks, callback)
	}
	s.mu.Unlock()
	for _, callback := range callbacks {
		callback(request, err)
	}
	s.closeMedia()
}

func runNativeVoiceSettingsReplay() error {
	root, err := os.MkdirTemp("", "mokusei-native-voice-settings-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	for _, mode := range []string{"idle", "captured", "late-handoff", "reverted", "stop", "cleanup-failure", "multiple"} {
		if err := nativeVoiceSettingsCase(filepath.Join(root, mode), mode); err != nil {
			return err
		}
	}
	if err := nativeVoiceBackgroundSettingsCase(filepath.Join(root, "background")); err != nil {
		return err
	}
	fmt.Println("PASS native voice settings: idle reconnect, exact unadmitted handoff recovery once, ownership/Stop fencing and failed-cleanup rejection")
	return nil
}

func nativeVoiceSettingsCase(root, mode string) error {
	system := startVoiceReplay(root, "codex", &voiceReplayFactory{})
	defer system.close()
	media, err := system.prepare(voiceReplayRequestID)
	if err != nil {
		return err
	}
	first, err := media.admitNative(mokuReplayContext(), plugin.VoiceDelegation{ID: "initial", Text: "initial native turn"})
	if err != nil {
		return err
	}
	speechRelease := make(chan struct{})
	media.mu.Lock()
	media.speechRelease = speechRelease
	media.mu.Unlock()
	system.complete("initial complete")
	voiceReplayWaitSpeech(media)
	settings, revision, err := system.r.Settings()
	if err != nil {
		return err
	}
	original := orchestratorCopyJSON(settings)
	system.h.mu.Lock()
	system.h.nativeModel = "updated-model"
	system.h.mu.Unlock()
	settings.Moku.ExecutionHarnesses["codex"] = mokuReplayRaw(map[string]any{"useDefaultThreadSettings": false, "threadSettings": map[string]string{"model": "updated-model"}})
	settings.Moku.RoutingGuidance = mokuReplayString("updated routing policy")
	saved, err := system.r.UpdateSettings(mokuReplayContext(), revision, settings)
	if err != nil {
		return err
	}
	mokuReplayCheck(saved.Status == "saved", "native voice settings save failed")
	poll := func() map[string]any {
		value, err := system.command("moku:voice-events", map[string]any{"action": "poll", "sessionId": media.ID(), "after": 0})
		mokuReplayMust(err)
		return value.(map[string]any)
	}
	mokuReplayCheck(poll()["reconnect"] == false, "native voice reconnected before pending speech finished")
	close(speechRelease)
	media.mu.Lock()
	media.speechRelease = nil
	media.mu.Unlock()
	deadline := time.After(3 * time.Second)
	for poll()["reconnect"] != true {
		select {
		case <-deadline:
			return errors.New("idle native voice did not request reconnect")
		case <-time.After(time.Millisecond):
		}
	}
	// A settings save can hold the gate longer than the media heartbeat budget.
	entered, release := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- system.r.WithConfigurationAdmission(mokuReplayContext(), func(context.Context) error { close(entered); <-release; return nil })
	}()
	<-entered
	began := time.Now()
	response := poll()
	mokuReplayCheck(response["reconnect"] == false && time.Since(began) < time.Second, "slow configuration admission blocked voice poll")
	close(release)
	mokuReplayMust(<-done)
	if mode == "reverted" {
		system.h.mu.Lock()
		system.h.nativeModel = "voice-model"
		system.h.mu.Unlock()
		restored, err := system.r.UpdateSettings(mokuReplayContext(), saved.SettingsRevision, original)
		if err != nil {
			return err
		}
		mokuReplayCheck(restored.Status == "saved", "settings revert failed")
	}
	request := plugin.VoiceDelegation{ID: "captured-input", Text: "retain exactly this spoken request", Context: "captured conversation"}
	if mode != "idle" && mode != "late-handoff" {
		_, err = media.admitNative(mokuReplayContext(), request)
		mokuReplayCheck(err == plugin.ErrMokuConfigurationPending, "stale native start did not reject before admission")
		mokuReplayCheck(system.record().Observation.LatestExecution.ExecutionID == first, "stale native start reserved an execution")
		mokuReplayCheck(poll()["reconnect"] == false, "reconnect raced unfinished native cleanup")
		var cleanupErr error
		if mode == "cleanup-failure" {
			cleanupErr = errors.New("controlled native cleanup failure")
		}
		media.configurationRecovered(request, cleanupErr)
		if mode == "captured" {
			entered, release := make(chan struct{}), make(chan struct{})
			done := make(chan error, 1)
			go func() {
				done <- system.r.WithConfigurationAdmission(mokuReplayContext(), func(context.Context) error { close(entered); <-release; return nil })
			}()
			<-entered
			mokuReplayCheck(poll()["reconnect"] == true, "slow save exposed closed event instead of retained reconnect")
			close(release)
			mokuReplayMust(<-done)
		}
		if mode == "multiple" {
			media.configurationRecovered(plugin.VoiceDelegation{ID: "another-input", Text: "do not overwrite the first pending input"}, nil)
		}
	}
	if mode == "late-handoff" {
		media.mu.Lock()
		media.configurationClose = func(ctx context.Context) error {
			_, err := media.admitNative(ctx, request)
			mokuReplayCheck(err == plugin.ErrMokuConfigurationPending, "late handoff bypassed freeze")
			media.configurationRecovered(request, nil)
			return nil
		}
		media.mu.Unlock()
	}
	if mode == "stop" {
		_, err = system.command("moku:voice", map[string]any{"action": "stop", "sessionId": media.ID()})
		if err != nil {
			return err
		}
	}
	reprepare := map[string]any{"action": "prepare", "requestId": voiceReplayInputID, "reconnectFrom": voiceReplayRequestID}
	// Another authenticated device cannot continue this call or recover its input.
	other := model.WithClientDevice(mokuReplayContext(), "other-device")
	_, stolen := system.r.Invoke(other, "moku:voice", []json.RawMessage{mokuReplayRaw(reprepare)})
	mokuReplayCheck(stolen != nil, "another device claimed configuration recovery")
	if mode != "stop" {
		occupied, err := system.r.Invoke(other, "moku:voice", []json.RawMessage{mokuReplayRaw(map[string]any{"action": "prepare", "requestId": voiceReplayRejectedInputID})})
		if err != nil {
			return err
		}
		mokuReplayCheck(occupied.(map[string]any)["occupiedOwner"] != nil, "another device silently replaced retained recovery")
	}
	value, err := system.command("moku:voice", reprepare)
	if mode == "stop" || mode == "cleanup-failure" || mode == "multiple" {
		mokuReplayCheck(err != nil, "cancelled/unclean native input recovery succeeded")
		mokuReplayCheck(system.record().Observation.LatestExecution.ExecutionID == first, "cancelled/unclean recovery executed an input")
		return system.close()
	}
	if err != nil {
		return err
	}
	next := system.factory.last()
	identity := value.(map[string]any)
	mokuReplayCheck(identity["sessionId"] == next.ID(), "reconnect returned wrong native session")
	system.ownershipMu.Lock()
	system.ownership[next.ID()] = voiceReplayInputID
	system.ownershipMu.Unlock()
	_, duplicate := system.command("moku:voice", reprepare)
	mokuReplayCheck(duplicate != nil, "old reconnect token created another media session")
	_, err = system.command("moku:voice", map[string]any{"action": "start", "sessionId": next.ID(), "sdp": "fixture-offer"})
	if err != nil {
		return err
	}
	applied, err := system.r.ReadMokuConfiguration()
	if err != nil {
		return err
	}
	if mode == "reverted" {
		mokuReplayCheck(replaySettingsModel(system.record().Settings) == "voice-model", "reverted settings lost at reconnect")
	} else {
		mokuReplayCheck(replaySettingsModel(system.record().Settings) == "updated-model" && applied.AppliedSettings.Moku.RoutingGuidance != nil, "reconnected native voice did not adopt settings")
	}
	if mode == "captured" || mode == "late-handoff" || mode == "reverted" {
		system.h.awaitTools(1)
		mokuReplayCheck(voiceReplayHasMessage(system.record(), request.Text), "reconnect discarded captured speech")
		_, err = system.command("moku:voice", map[string]any{"action": "start", "sessionId": next.ID(), "sdp": "fixture-offer"})
		if err != nil {
			return err
		}
		system.h.mu.Lock()
		sends := system.h.nativeSends
		system.h.mu.Unlock()
		mokuReplayCheck(sends == 1, "repeated start replayed captured input")
		system.complete("recovered result")
		speech := voiceReplayWaitSpeech(next)
		mokuReplayCheck(speech.Text == "recovered result", "new media lost recovered request answer")
	} else {
		_, err = next.admitNative(mokuReplayContext(), plugin.VoiceDelegation{ID: "fresh-after-reconnect", Text: "new native turn"})
		if err != nil {
			return err
		}
	}
	return system.close()
}

func (s *voiceReplaySession) CloseForConfiguration(ctx context.Context) error {
	s.mu.Lock()
	hook := s.configurationClose
	s.mu.Unlock()
	if hook != nil {
		if err := hook(ctx); err != nil {
			return err
		}
	}
	s.closeMedia()
	return ctx.Err()
}

func nativeVoiceBackgroundSettingsCase(root string) error {
	system := startVoiceReplay(root, "codex", &voiceReplayFactory{})
	defer system.close()
	media, err := system.prepare(voiceReplayRequestID)
	if err != nil {
		return err
	}
	_, err = media.admitNative(mokuReplayContext(), plugin.VoiceDelegation{ID: "background-origin", Text: "start native background work"})
	if err != nil {
		return err
	}
	system.complete("foreground complete")
	voiceReplayWaitSpeech(media)
	setBackground := func(active bool) {
		observation := system.record().Observation
		observation.BackgroundWork = nil
		if active {
			observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
		}
		system.h.mu.Lock()
		handle := system.h.handles[len(system.h.handles)-1]
		system.h.mu.Unlock()
		mokuReplayMust(handle.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
	}
	setBackground(true)
	settings, revision, err := system.r.Settings()
	if err != nil {
		return err
	}
	settings.Moku.RoutingGuidance = mokuReplayString("pending until background drains")
	_, err = system.r.UpdateSettings(mokuReplayContext(), revision, settings)
	if err != nil {
		return err
	}
	_, err = media.admitNative(mokuReplayContext(), plugin.VoiceDelegation{ID: "foreground-on-background", Text: "continue admitted native owner"})
	if err != nil {
		return err
	}
	applied, err := system.r.ReadMokuConfiguration()
	if err != nil {
		return err
	}
	mokuReplayCheck(applied.AppliedSettings.Moku.RoutingGuidance == nil, "native background adopted pending config")
	system.complete("background remains")
	voiceReplayWaitSpeech(media)
	poll := func() bool {
		value, err := system.command("moku:voice-events", map[string]any{"action": "poll", "sessionId": media.ID(), "after": 0})
		mokuReplayMust(err)
		return value.(map[string]any)["reconnect"] == true
	}
	mokuReplayCheck(!poll(), "native background requested destructive reconnect")
	setBackground(false)
	deadline := time.After(3 * time.Second)
	for !poll() {
		select {
		case <-deadline:
			return errors.New("native background never released configuration")
		case <-time.After(time.Millisecond):
		}
	}
	return system.close()
}
