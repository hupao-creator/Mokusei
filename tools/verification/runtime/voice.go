package main

// This replay feeds real Swift encodedData bytes through Runtime.Invoke and its
// production threadvoice.Request decoder, with only discussion/media synthetic.
import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
)

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
	if len(fixtures.Commands) != 9 || len(fixtures.Contracts) != 5 {
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
		for _, key := range []string{"expectedSettingsRevision", "revision", "metadataRevision"} {
			var actual int64
			must(json.Unmarshal(fields[key], &actual))
			if actual != expected {
				panic(key + " integer precision lost")
			}
		}
	}
	for _, fixture := range fixtures.Commands {
		value, err := r.Invoke(ctx, fixture.Channel, fixture.Args)
		if err != nil {
			panic(fmt.Errorf("Swift %s: %w", fixture.Name, err))
		}
		result, ok := value.(threadvoice.Result)
		if !ok {
			panic(fmt.Sprintf("unexpected voice result %T", value))
		}
		switch fixture.Name {
		case "history":
			if result.Available == nil || !*result.Available {
				panic("discussion unavailable")
			}
		case "prepare":
			if result.SessionID != voiceFixtureID {
				panic("prepare session mismatch")
			}
		case "start":
			if result.SDP != "fixture-answer" {
				panic("SDP start path did not complete")
			}
		case "events":
			if result.Events == nil || len(*result.Events) != 2 {
				panic("voice events missing")
			}
		case "advanced poll":
			if result.Events == nil || len(*result.Events) != 1 || (*result.Events)[0].Sequence != 2 {
				panic("cursor did not advance")
			}
		case "initial poll", "max cursor", "retired poll":
			if result.Events == nil || len(*result.Events) != 0 {
				panic(fixture.Name + " must be empty")
			}
		}
	}
	// Preserve the strict server contract: accepting decimal cursors server-side
	// would conceal the Swift wire regression and allow unintended coercions.
	for _, invalid := range []string{"0.0", "1e0", "0.5", "9007199254740992"} {
		request := json.RawMessage(fmt.Sprintf(`{"threadId":%q,"request":{"action":"poll","sessionId":%q,"ownershipId":%q,"after":%s}}`, threadID, voiceFixtureID, voiceFixtureID, invalid))
		if _, err := r.Invoke(ctx, "thread:voice-events", []json.RawMessage{request}); err == nil {
			panic("invalid cursor admitted: " + invalid)
		}
	}
	fmt.Println("PASS Swift integer wire -> Go DTOs and Runtime voice: history/prepare/poll(0)/SDP start/events/cursor advance/stop/retired poll; exact int64 boundaries")
}

const voiceFixtureID = "11111111-1111-4111-8111-111111111111"

func verifyVoiceDevices(ctx context.Context, r *core.Runtime, threadID string) {
	const firstOwner = "33333333-3333-4333-8333-333333333333"
	const secondOwner = "44444444-4444-4444-8444-444444444444"
	command := func(device string, fields map[string]any) (threadvoice.Result, error) {
		channel := "thread:voice"
		if fields["action"] == "poll" || fields["action"] == "heartbeat" {
			channel = "thread:voice-events"
		}
		value, err := r.Invoke(model.WithClientDevice(ctx, device), channel,
			[]json.RawMessage{raw(map[string]any{"threadId": threadID, "request": fields})})
		if err != nil {
			return threadvoice.Result{}, err
		}
		return value.(threadvoice.Result), nil
	}
	first, err := command("ipad-a", map[string]any{"action": "prepare", "requestId": firstOwner})
	must(err)
	second, err := command("ipad-b", map[string]any{"action": "prepare", "requestId": secondOwner})
	must(err)
	if first.OwnershipID != firstOwner || second.OwnershipID != secondOwner || !r.ServiceVoiceActive() {
		panic("thread voice device ownership or power activity missing")
	}
	for _, device := range []string{"ipad-a", "ipad-c"} {
		_, err = command(device, map[string]any{"action": "heartbeat", "sessionId": second.SessionID, "ownershipId": secondOwner})
		if err == nil {
			panic("other thread voice device renewed media")
		}
		_, err = command(device, map[string]any{"action": "stop", "sessionId": second.SessionID, "ownershipId": secondOwner})
		must(err)
	}
	_, err = command("ipad-b", map[string]any{"action": "start", "sessionId": second.SessionID, "ownershipId": secondOwner, "sdp": "fixture-offer"})
	must(err)
	must(r.RevokeDeviceMedia(ctx, "ipad-a"))
	_, err = command("ipad-a", map[string]any{"action": "heartbeat", "sessionId": first.SessionID, "ownershipId": firstOwner})
	if err == nil {
		panic("revoked thread voice retained ownership")
	}
	if !r.ServiceVoiceActive() {
		panic("revocation released unrelated voice power lease")
	}
	result, err := command("ipad-b", map[string]any{"action": "poll", "sessionId": second.SessionID, "ownershipId": secondOwner, "after": 0})
	must(err)
	if result.Events == nil || len(*result.Events) != 2 {
		panic("revocation stopped unrelated thread media")
	}
	must(r.RevokeDeviceMedia(ctx, "ipad-b"))
	if r.ServiceVoiceActive() {
		panic("last voice device retained host power lease")
	}
	fmt.Println("PASS thread voice: per-device discussions, session+ownership fences, independent revocation and host activity lifetime")
}

type voiceDiscussion struct{}

func (harness) PrepareDiscussion(context.Context, plugin.DiscussionRequest) (plugin.Discussion, error) {
	return voiceDiscussion{}, nil
}
func (harness) PrepareVoice(context.Context, string) (plugin.VoiceSession, error) {
	panic("native discussion should own voice")
}
func (voiceDiscussion) Ask(context.Context, string) (string, error) { return "fixture answer", nil }
func (voiceDiscussion) Close() error                                { return nil }
func (voiceDiscussion) PrepareNativeVoice(context.Context, []plugin.ContextEntry) (plugin.VoiceSession, error) {
	return &voiceMedia{}, nil
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
