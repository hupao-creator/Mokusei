package main

// This replay feeds actual Swift encodedData bytes through Runtime.Invoke and
// the production Moku/retained-thread contracts; only Harness/media are synthetic.
import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
)

func verifyRuntimeVoice(ctx context.Context, root string, swift bool) {
	// The service owns its own durable Moku session; keep it outside the main
	// runtime fixture's ordinary-thread mutation/count observations.
	directory := filepath.Join(root, "runtime-voice")
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	must(err)
	harnesses := map[string]plugin.Harness{"fixture": voiceHarness{}}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: harnesses, DataDir: directory, DefaultCwd: directory})
	must(err)
	defer func() { must(r.Close(ctx)); must(db.Close()) }()
	workspace := filepath.Join(directory, "moku")
	must(os.MkdirAll(workspace, 0700))
	c, err := moku.New(moku.Configuration{
		Workspace: workspace, DataDir: directory, Harnesses: harnesses,
		WithSettingsAdmission: r.WithConfigurationAdmission, PrepareSettings: r.PrepareSettings,
		Settings: r.Settings, Threads: r.Threads, Thread: r.Thread, UpdateThread: r.UpdateThread,
		ReadSessionConfiguration: func() (moku.SessionConfiguration, error) {
			value, err := r.ReadMokuConfiguration()
			return moku.SessionConfiguration{Unapplied: value.Unapplied, HarnessID: value.HarnessID,
				Settings: value.Settings, AppliedSettings: value.AppliedSettings,
				SettingsRevision: value.SettingsRevision, Cwd: value.Cwd}, err
		},
		EnsureSession: func(ctx context.Context, value moku.SessionConfiguration) (model.ThreadRecord, error) {
			return r.EnsureConfiguredMokuThread(ctx, core.MokuConfiguration{Unapplied: value.Unapplied,
				HarnessID: value.HarnessID, Settings: value.Settings, AppliedSettings: value.AppliedSettings,
				SettingsRevision: value.SettingsRevision, Cwd: value.Cwd})
		},
		ReplaceSession: func(ctx context.Context, old string, value moku.SessionConfiguration) (model.ThreadRecord, error) {
			return r.ReplaceConfiguredMokuThread(ctx, old, core.MokuConfiguration{Unapplied: value.Unapplied,
				HarnessID: value.HarnessID, Settings: value.Settings, AppliedSettings: value.AppliedSettings,
				SettingsRevision: value.SettingsRevision, Cwd: value.Cwd,
				PreserveNote: value.PreserveNote, PreserveHistory: value.PreserveHistory})
		},
		ConfigureSession: func(ctx context.Context, id string, revision int64, value moku.SessionConfiguration) error {
			return r.ConfigureMokuThread(ctx, id, revision, value.HarnessID, value.Settings,
				value.AppliedSettings, value.SettingsRevision, value.Cwd)
		},
		OpenSession: r.OpenMokuThread, CloseSession: r.CloseMokuThread, SendSession: r.SendMokuThread,
		SubscribeCommitted: r.OnThreadCommitted, VoicePreparationContext: r.VoicePreparationContext,
		Voice: voiceHarness{},
	})
	must(err)
	r.SetMoku(c)
	must(c.Start(ctx, plugin.RuntimeStartContext{Reason: "fixture"}))
	created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture",
		Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "retained transcript source"}}}})
	must(err)
	verifyRetainedThreadVoice(ctx, r, directory, created.Record.ID)
	if swift {
		verifySwiftVoice(ctx, r, directory, created.Record.ID)
	}
	verifyVoiceDevices(ctx, r)
}

func verifySwiftVoice(ctx context.Context, r *core.Runtime, root, threadID string) {
	path := filepath.Join(root, "swift-requests.json")
	testCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	command := swiftfixture.Test(testCtx, "--filter", "IntegerWireTests")
	command.Env = append(os.Environ(), "MOKUSEI_SWIFT_INTEGER_REQUESTS="+path, "MOKUSEI_SWIFT_VOICE_THREAD="+threadID)
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	must(command.Run())
	data, err := os.ReadFile(path)
	must(err)
	var fixtures struct {
		Commands []struct {
			Name    string            `json:"name"`
			Channel string            `json:"channel"`
			Args    []json.RawMessage `json:"args"`
		} `json:"commands"`
		Contracts []json.RawMessage `json:"contracts"`
	}
	must(json.Unmarshal(data, &fixtures))
	if len(fixtures.Commands) != 13 || len(fixtures.Contracts) != 5 {
		panic("Swift fixture coverage missing")
	}
	for i, expected := range []int64{0, 1, 9007199254740993, 9223372036854775807, -9223372036854775808} {
		var fields map[string]json.RawMessage
		must(json.Unmarshal(fixtures.Contracts[i], &fields))
		var request threadvoice.Request
		must(model.Unmarshal(raw(map[string]any{"request": map[string]json.RawMessage{"after": fields["after"]}}), &request))
		if request.Request.After != expected {
			panic("voice integer precision lost")
		}
		for _, key := range []string{"draftRevision", "expectedSettingsRevision", "revision", "metadataRevision"} {
			var actual int64
			must(json.Unmarshal(fields[key], &actual))
			if actual != expected {
				panic(key + " integer precision lost")
			}
		}
	}
	for _, fixture := range fixtures.Commands {
		value, err := r.Invoke(ctx, fixture.Channel, fixture.Args)
		if fixture.Name == "thread prepare removed" || fixture.Name == "thread start removed" || fixture.Name == "thread heartbeat removed" {
			voiceError(err, "THREAD_VOICE_REMOVED")
			continue
		}
		if err != nil {
			panic(fmt.Errorf("Swift %s: %w", fixture.Name, err))
		}
		if fixture.Name == "thread history" {
			retainedVoiceHistory(value)
			continue
		}
		if fixture.Name == "thread stop" {
			if r.ServiceVoiceActive() {
				panic("retained thread cleanup started media")
			}
			continue
		}
		result, ok := value.(map[string]any)
		if !ok {
			panic(fmt.Sprintf("unexpected voice result %T", value))
		}
		switch fixture.Name {
		case "prepare":
			if result["sessionId"] != voiceFixtureID || result["ownershipId"] != voiceFixtureID || !r.ServiceVoiceActive() {
				panic("prepare session mismatch")
			}
		case "start":
			if result["sdp"] != "fixture-answer" {
				panic("SDP start path did not complete")
			}
		case "events":
			events, ok := result["events"].([]plugin.VoiceEvent)
			if !ok || len(events) != 2 {
				panic("voice events missing")
			}
		case "advanced poll":
			events, ok := result["events"].([]plugin.VoiceEvent)
			if !ok || len(events) != 1 || events[0].Sequence != 2 {
				panic("cursor did not advance")
			}
		case "initial poll", "max cursor", "retired poll":
			events, ok := result["events"].([]plugin.VoiceEvent)
			if !ok || len(events) != 0 {
				panic(fixture.Name + " must be empty")
			}
		case "stop":
			if r.ServiceVoiceActive() {
				panic("Swift stop retained the global media lease")
			}
		default:
			panic("unexpected Swift voice fixture: " + fixture.Name)
		}
	}
	verifyVoiceCursors(ctx, r, threadID)
	fmt.Println("PASS Swift integer wire -> Go DTOs and Runtime global Moku voice: retained thread history/removal, prepare/poll(0)/SDP start/events/cursor advance/stop/retired poll; exact int64 boundaries")
}

const voiceFixtureID = "11111111-1111-4111-8111-111111111111"

func verifyVoiceDevices(ctx context.Context, r *core.Runtime) {
	const firstOwner = "33333333-3333-4333-8333-333333333333"
	const secondOwner = "44444444-4444-4444-8444-444444444444"
	command := func(device string, fields map[string]any) (map[string]any, error) {
		channel := "moku:voice"
		if fields["action"] == "poll" || fields["action"] == "heartbeat" {
			channel = "moku:voice-events"
		}
		value, err := r.Invoke(model.WithClientDevice(ctx, device), channel, []json.RawMessage{raw(fields)})
		if err != nil {
			return nil, err
		}
		return value.(map[string]any), nil
	}
	first, err := command("ipad-a", map[string]any{"action": "prepare", "requestId": firstOwner})
	must(err)
	busy, err := command("ipad-b", map[string]any{"action": "prepare", "requestId": secondOwner})
	must(err)
	occupied, ok := busy["occupiedOwner"].(map[string]string)
	if !ok || occupied["deviceId"] != "ipad-a" || occupied["ownershipId"] != firstOwner || first["ownershipId"] != firstOwner || !r.ServiceVoiceActive() {
		panic("global voice ownership, explicit occupancy or power activity missing")
	}
	for _, device := range []string{"ipad-b", "ipad-c"} {
		for _, action := range []string{"start", "poll", "heartbeat"} {
			fields := map[string]any{"action": action, "sessionId": first["sessionId"], "ownershipId": firstOwner}
			if action == "start" {
				fields["sdp"] = "fixture-offer"
			}
			if action == "poll" {
				fields["after"] = 0
			}
			_, err = command(device, fields)
			if err == nil {
				panic("other global voice device controlled media: " + action)
			}
		}
		_, err = command(device, map[string]any{"action": "stop", "sessionId": first["sessionId"], "ownershipId": firstOwner})
		must(err)
		if !r.ServiceVoiceActive() {
			panic("other device stopped the global voice owner")
		}
	}
	second, err := command("ipad-b", map[string]any{"action": "prepare", "requestId": secondOwner, "takeover": firstOwner})
	must(err)
	if second["ownershipId"] != secondOwner || !r.ServiceVoiceActive() {
		panic("explicit voice takeover did not install its owner")
	}
	_, err = command("ipad-a", map[string]any{"action": "stop", "sessionId": second["sessionId"], "ownershipId": firstOwner})
	must(err)
	_, err = command("ipad-b", map[string]any{"action": "start", "sessionId": second["sessionId"], "ownershipId": secondOwner, "sdp": "fixture-offer"})
	must(err)
	must(r.RevokeDeviceMedia(ctx, "ipad-a"))
	_, err = command("ipad-a", map[string]any{"action": "heartbeat", "sessionId": first["sessionId"], "ownershipId": firstOwner})
	if err == nil {
		panic("revoked global voice retained ownership")
	}
	if !r.ServiceVoiceActive() {
		panic("revocation released unrelated voice power lease")
	}
	result, err := command("ipad-b", map[string]any{"action": "poll", "sessionId": second["sessionId"], "ownershipId": secondOwner, "after": 0})
	must(err)
	events, ok := result["events"].([]plugin.VoiceEvent)
	if !ok || len(events) != 2 {
		panic("revocation stopped unrelated global media")
	}
	must(r.RevokeDeviceMedia(ctx, "ipad-b"))
	if r.ServiceVoiceActive() {
		panic("last voice device retained host power lease")
	}
	fmt.Println("PASS global Moku voice: explicit device takeover, session+ownership fences, scoped revocation and host activity lifetime")
}

type voiceHarness struct{ harness }

func (voiceHarness) PrepareVoice(context.Context, string) (plugin.VoiceSession, error) {
	return &voiceMedia{}, nil
}

func (voiceHarness) DiscoverMokuTarget(context.Context, plugin.SettingsRequest) (json.RawMessage, plugin.Availability, error) {
	schema, err := plugin.ModelCatalogSchema(map[string]any{"type": "object", "properties": map[string]any{
		"model": map[string]any{"type": "string", "enum": []string{"fixture-model"}}}, "additionalProperties": false},
		[]plugin.ModelCatalogEntry{{ID: "fixture-model"}}, "runtime-voice-fixture", plugin.CatalogSourceEvidence{Complete: true, Basis: "authoritative fixture registry"})
	return schema, plugin.Availability{Available: true}, err
}

func voiceError(err error, code string) {
	var failure *model.Error
	if !errors.As(err, &failure) || failure.Code != code {
		panic(fmt.Sprintf("expected %s, got %v", code, err))
	}
}

func retainedVoiceHistory(value any) {
	result, ok := value.(threadvoice.Result)
	if !ok || result.Supported == nil || *result.Supported || result.Available == nil || *result.Available ||
		result.Messages == nil || len(*result.Messages) != 1 || (*result.Messages)[0].Text != "Retained transcript" {
		panic("thread history lost its read-only transcript contract")
	}
}

func verifyRetainedThreadVoice(ctx context.Context, r *core.Runtime, root, threadID string) {
	digest := sha256.Sum256([]byte(threadID))
	path := filepath.Join(root, "voice-transcripts", fmt.Sprintf("%x.json", digest))
	must(os.MkdirAll(filepath.Dir(path), 0700))
	history := raw([]plugin.VoiceTranscriptMessage{{ID: "retained-message", SessionID: voiceFixtureID,
		Role: "assistant", Text: "Retained transcript", Complete: true, CreatedAt: 1}})
	must(os.WriteFile(path, history, 0600))
	before, err := r.Thread(threadID)
	must(err)
	for _, action := range []string{"prepare", "start", "heartbeat", "history", "stop"} {
		fields := map[string]any{"action": action}
		channel := "thread:voice"
		switch action {
		case "prepare":
			fields["requestId"] = voiceFixtureID
		case "start":
			fields["sessionId"], fields["ownershipId"], fields["sdp"] = voiceFixtureID, voiceFixtureID, "fixture-offer"
		case "heartbeat", "stop":
			fields["sessionId"], fields["ownershipId"] = voiceFixtureID, voiceFixtureID
		}
		if action == "heartbeat" || action == "history" {
			channel = "thread:voice-events"
		}
		value, err := r.Invoke(ctx, channel, []json.RawMessage{raw(map[string]any{"threadId": threadID, "request": fields})})
		if action == "prepare" || action == "start" || action == "heartbeat" {
			voiceError(err, "THREAD_VOICE_REMOVED")
		} else {
			must(err)
			if action == "history" {
				retainedVoiceHistory(value)
			}
		}
	}
	_, err = r.Invoke(ctx, "moku:voice", []json.RawMessage{raw(map[string]any{"action": "prepare",
		"requestId": voiceFixtureID, "superThreadId": threadID, "sourceRevision": 0})})
	voiceError(err, "THREAD_VOICE_REMOVED")
	if r.ServiceVoiceActive() {
		panic("history or rejected thread call acquired a media lease")
	}
	after, err := r.Thread(threadID)
	must(err)
	retained, err := os.ReadFile(path)
	must(err)
	if before.Revision != after.Revision || !bytes.Equal(before.SessionState, after.SessionState) || !bytes.Equal(history, retained) {
		panic("read-only voice commands mutated the source or retained transcript")
	}
	verifyVoiceCursors(ctx, r, threadID)
	fmt.Println("PASS retained thread voice: unchanged history/source, no media lease, removed prepare/start/heartbeat and Overview-only global admission")
}

func verifyVoiceCursors(ctx context.Context, r *core.Runtime, threadID string) {
	// Retained Thread DTOs remain lexically strict even though Moku's safe-number
	// parser accepts whole numeric spellings. Check the decoder error itself:
	// a missing retired owner must not make a malformed cursor appear covered.
	for _, invalid := range []string{"0.0", "1e0", "0.5", "9007199254740992"} {
		request := json.RawMessage(fmt.Sprintf(`{"threadId":%q,"request":{"action":"poll","sessionId":%q,"ownershipId":%q,"after":%s}}`, threadID, voiceFixtureID, voiceFixtureID, invalid))
		_, err := r.Invoke(ctx, "thread:voice-events", []json.RawMessage{request})
		if invalid == "9007199254740992" {
			if err == nil || err.Error() != "invalid voice event cursor" {
				panic(fmt.Sprintf("unsafe thread cursor was not rejected at admission: %v", err))
			}
		} else {
			var invalidNumber *json.UnmarshalTypeError
			if !errors.As(err, &invalidNumber) {
				panic(fmt.Sprintf("thread cursor %s bypassed its integer DTO: %v", invalid, err))
			}
		}
	}
	for _, invalid := range []string{"0.5", "-1", "9007199254740992"} {
		request := json.RawMessage(fmt.Sprintf(`{"action":"poll","sessionId":%q,"ownershipId":%q,"after":%s}`, voiceFixtureID, voiceFixtureID, invalid))
		_, err := r.Invoke(ctx, "moku:voice-events", []json.RawMessage{request})
		voiceError(err, "INVALID_REQUEST")
	}
}

type voiceMedia struct {
	mu              sync.Mutex
	started, closed bool
}

func (*voiceMedia) ID() string                                       { return voiceFixtureID }
func (v *voiceMedia) Closed() bool                                   { v.mu.Lock(); defer v.mu.Unlock(); return v.closed }
func (*voiceMedia) InputGeneration() int64                           { return 0 }
func (*voiceMedia) OnClose(func()) func()                            { return func() {} }
func (*voiceMedia) OnEvent(func(plugin.VoiceEvent)) func()           { return func() {} }
func (*voiceMedia) OnDelegation(func(plugin.VoiceDelegation)) func() { return func() {} }
func (v *voiceMedia) Start(ctx context.Context, offer string) (string, error) {
	if offer != "fixture-offer" {
		return "", fmt.Errorf("unexpected SDP %q", offer)
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.closed {
		return "", fmt.Errorf("media closed before start")
	}
	v.started = true
	return "fixture-answer", ctx.Err()
}
func (v *voiceMedia) Poll(after int64) ([]plugin.VoiceEvent, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	events := []plugin.VoiceEvent{}
	if v.started {
		for _, event := range []plugin.VoiceEvent{{Sequence: 1, Type: "connected"}, {Sequence: 2, Type: "status"}} {
			if event.Sequence > after {
				events = append(events, event)
			}
		}
	}
	return events, nil
}
func (*voiceMedia) Heartbeat()                                      {}
func (*voiceMedia) FenceInput(string)                               {}
func (*voiceMedia) RejectInput(string)                              {}
func (*voiceMedia) Speak(context.Context, plugin.VoiceSpeech) error { return nil }
func (v *voiceMedia) Stop(context.Context) error {
	v.mu.Lock()
	v.closed = true
	v.mu.Unlock()
	return nil
}
