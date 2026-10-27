package codex

import (
	"context"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"testing"
)

func feedbackFixture() *VoiceSession {
	return &VoiceSession{id: "voice", phase: "live", requests: map[string]plugin.VoiceDelegation{}, transcripts: map[string]Map{}, deliveries: map[string]bool{}}
}
func feedbackTranscript(t *testing.T, v *VoiceSession, role, text string) plugin.VoiceEvent {
	t.Helper()
	v.notification("thread/realtime/transcript/done", Map{"role": role, "text": text})
	events, err := v.Poll(0)
	if err != nil || len(events) == 0 {
		t.Fatalf("missing transcript event: %v", err)
	}
	return events[len(events)-1]
}
func feedbackHandoff(v *VoiceSession, id, text string) {
	v.notification("thread/realtime/itemAdded", Map{"item": Map{"type": "handoff_request", "handoff_id": id, "input_transcript": text}})
}
func TestVoiceFeedbackDuplicateTextBeforeHandoffIsAmbiguous(t *testing.T) {
	v := feedbackFixture()
	a := feedbackTranscript(t, v, "user", "same request")
	b := feedbackTranscript(t, v, "user", "same request")
	if a.ItemID == b.ItemID {
		t.Fatal("fixture failed to create distinct ASR items")
	}
	feedbackHandoff(v, "request-a", "same request")
	if item := v.replyItemLocked("request-a", v.InputGeneration()); item != "" {
		t.Fatalf("ambiguous request would label a Moku answer with ASR %q", item)
	}
	if reply := feedbackTranscript(t, v, "assistant", "Accepted"); reply.ReplyToItemID != "" {
		t.Fatalf("ambiguous A feedback acquired an ASR identity: got %q, B=%q", reply.ReplyToItemID, b.ItemID)
	}
	// Later ASR must not cause an ambiguous request to acquire a guessed identity.
	feedbackTranscript(t, v, "user", "different request")
	if v.replyItemLocked("request-a", v.InputGeneration()) != "" {
		t.Fatal("ambiguous Moku answer binding changed after admission")
	}
	if reply := feedbackTranscript(t, v, "assistant", "Second segment"); reply.ReplyToItemID != "" {
		t.Fatal("ambiguous binding changed after admission")
	}
}
func TestVoiceFeedbackLateSecondAssistantSegmentCannotConsumeNewASR(t *testing.T) {
	v := feedbackFixture()
	feedbackTranscript(t, v, "user", "request A")
	feedbackTranscript(t, v, "assistant", "First segment for A")
	b := feedbackTranscript(t, v, "user", "request B")
	if reply := feedbackTranscript(t, v, "assistant", "Late second segment for A"); reply.ReplyToItemID != "" {
		t.Fatalf("unidentified assistant segment guessed a reply: got %q, B=%q", reply.ReplyToItemID, b.ItemID)
	}
}
func TestVoiceFeedbackUniqueHandoffBindingDoesNotFollowNewASR(t *testing.T) {
	v := feedbackFixture()
	a := feedbackTranscript(t, v, "user", "request")
	feedbackHandoff(v, "request-a", "request")
	b := feedbackTranscript(t, v, "user", "request")
	reply := feedbackTranscript(t, v, "assistant", "Accepted A")
	if reply.ReplyToItemID != "" || v.replyItemLocked("request-a", v.InputGeneration()) != a.ItemID || a.ItemID == b.ItemID {
		t.Fatal("verified handoff did not retain its original ASR identity")
	}
}

func TestVoiceFeedbackBindingPrecedesReentrantInputUpdates(t *testing.T) {
	v := feedbackFixture()
	a := feedbackTranscript(t, v, "user", "request")
	updated := false
	newer := ""
	v.listeners = map[string]func(plugin.VoiceEvent){"fixture": func(event plugin.VoiceEvent) {
		if event.Type != "input" || updated {
			return
		}
		updated = true
		newer = feedbackTranscript(t, v, "user", "request").ItemID
		v.FenceInput("typed-input")
	}}
	feedbackHandoff(v, "request-a", "request")
	if item := v.replyItemLocked("request-a", v.InputGeneration()); item != a.ItemID || item == newer {
		t.Fatal("handoff acquired ASR identity from callbacks published after its admission")
	}
}

func TestVoiceFeedbackLateSegmentAfterNextHandoffHasNoRequestIdentity(t *testing.T) {
	v := feedbackFixture()
	feedbackTranscript(t, v, "user", "request A")
	feedbackHandoff(v, "request-a", "request A")
	feedbackTranscript(t, v, "assistant", "First segment for A")
	b := feedbackTranscript(t, v, "user", "request B")
	feedbackHandoff(v, "request-b", "request B")
	if reply := feedbackTranscript(t, v, "assistant", "Late second segment for A"); reply.ReplyToItemID != "" {
		t.Fatalf("flat assistant segment acquired B's identity: %q", reply.ReplyToItemID)
	}
	if v.replyItemLocked("request-b", v.InputGeneration()) != b.ItemID || v.replyItemLocked("", v.InputGeneration()) != "" {
		t.Fatal("only the explicit request may resolve a Moku answer")
	}
}

func TestVoiceFeedbackHandoffBeforeFinalBindsFrozenASR(t *testing.T) {
	v := feedbackFixture()
	v.notification("thread/realtime/transcript/delta", Map{"role": "user", "delta": "partial"})
	partial := v.events[len(v.events)-1]
	feedbackHandoff(v, "request-before-final", "complete request")
	input := v.events[len(v.events)-1]
	final := feedbackTranscript(t, v, "user", "complete request")
	request := v.requests["request-before-final"]
	if input.Type != "input" || input.InputID != "" || input.Generation == nil || *input.Generation != request.Generation {
		t.Fatal("native handoff lost its generation boundary")
	}
	if partial.ItemID != final.ItemID || partial.Generation == nil || final.Generation == nil || *partial.Generation != request.Generation-1 || *final.Generation != *partial.Generation {
		t.Fatal("partial/final did not retain their pre-handoff ASR identity")
	}
	if v.replyItemLocked(request.ID, request.Generation) != partial.ItemID {
		t.Fatal("exact final did not bind the ASR frozen before handoff")
	}
}

func feedbackPartial(v *VoiceSession, text string) plugin.VoiceEvent {
	v.notification("thread/realtime/transcript/delta", Map{"role": "user", "delta": text})
	return v.events[len(v.events)-1]
}

// The JSON-RPC replay checks actual appendSpeech. Unit tests stop before that
// audio seam while retaining Speak's production answer publication and gates.
func feedbackSpeakWithoutAudio(t *testing.T, v *VoiceSession, speech plugin.VoiceSpeech) {
	t.Helper()
	if v.listeners == nil {
		v.listeners = make(map[string]func(plugin.VoiceEvent))
	}
	v.listeners["suppress-audio"] = func(event plugin.VoiceEvent) {
		if event.Type == "answer" {
			v.mu.Lock()
			v.phase = "prepared"
			v.mu.Unlock()
		}
	}
	if err := v.Speak(context.Background(), speech); err != nil {
		t.Fatal(err)
	}
	delete(v.listeners, "suppress-audio")
	v.phase = "live"
}

func TestVoiceFeedbackBeforeFinalRepublishesIdentityWithoutSpeech(t *testing.T) {
	v := feedbackFixture()
	partial := feedbackPartial(v, "partial")
	feedbackHandoff(v, "request-a", "complete request")
	speech := plugin.VoiceSpeech{DeliveryID: "delivery-a", DelegationID: "request-a", Generation: v.InputGeneration(), Text: "Real feedback"}
	feedbackSpeakWithoutAudio(t, v, speech)
	initial := v.events[len(v.events)-1]
	if initial.Type != "answer" || initial.ReplyToItemID != "" {
		t.Fatal("feedback before final guessed an ASR identity")
	}
	feedbackTranscript(t, v, "user", "complete request")
	resolved := v.events[len(v.events)-1]
	if resolved.Type != "answer" || resolved.ReplyToItemID != partial.ItemID || resolved.DeliveryID != initial.DeliveryID || resolved.Generation == nil || *resolved.Generation != speech.Generation || resolved.Text == nil || *resolved.Text != speech.Text {
		t.Fatal("final did not attach frozen ASR identity to the already published answer")
	}
	if len(v.pendingTranscripts) != 0 || len(v.pendingAnswers) != 0 {
		t.Fatal("resolved handoff retained pending state")
	}
	before := len(v.events)
	feedbackSpeakWithoutAudio(t, v, speech)
	if len(v.events) != before {
		t.Fatal("identity repair replayed a delivered answer")
	}
}

func TestVoiceFeedbackPendingFinalMismatchCannotBindLaterSameText(t *testing.T) {
	v := feedbackFixture()
	feedbackPartial(v, "partial")
	feedbackHandoff(v, "request-a", "complete request")
	feedbackSpeakWithoutAudio(t, v, plugin.VoiceSpeech{DeliveryID: "delivery-a", DelegationID: "request-a", Generation: v.InputGeneration(), Text: "Real feedback"})
	feedbackTranscript(t, v, "user", "different final")
	feedbackTranscript(t, v, "user", "complete request")
	if v.replyItemLocked("request-a", v.InputGeneration()) != "" || len(v.pendingTranscripts) != 0 || len(v.pendingAnswers) != 0 {
		t.Fatal("a mismatching final let later ASR acquire old feedback")
	}
}

func TestVoiceFeedbackNoExistingASRCannotBindLaterSameText(t *testing.T) {
	v := feedbackFixture()
	feedbackHandoff(v, "request-a", "complete request")
	feedbackTranscript(t, v, "user", "complete request")
	if v.replyItemLocked("request-a", v.InputGeneration()) != "" || len(v.pendingTranscripts) != 0 {
		t.Fatal("an ASR first seen after handoff acquired old feedback")
	}
}

func TestVoiceFeedbackExistingExactASRPreventsPendingNewerASR(t *testing.T) {
	v := feedbackFixture()
	a := feedbackTranscript(t, v, "user", "request A")
	b := feedbackPartial(v, "partial B")
	feedbackHandoff(v, "request-a", "request A")
	feedbackTranscript(t, v, "user", "request A")
	if a.ItemID == b.ItemID || v.replyItemLocked("request-a", v.InputGeneration()) != a.ItemID || len(v.pendingTranscripts) != 0 {
		t.Fatal("a newer ASR in the same generation stole an older exact request")
	}
}

func TestVoiceFeedbackAmbiguousExactASRPreventsPendingBinding(t *testing.T) {
	v := feedbackFixture()
	feedbackTranscript(t, v, "user", "same request")
	feedbackPartial(v, "same request")
	feedbackHandoff(v, "request-a", "same request")
	feedbackTranscript(t, v, "user", "same request")
	if v.replyItemLocked("request-a", v.InputGeneration()) != "" || len(v.pendingTranscripts) != 0 {
		t.Fatal("a final converted ambiguous exact ASR into a guessed binding")
	}
}

func TestVoiceFeedbackPendingIgnoresASRFromEarlierGeneration(t *testing.T) {
	v := feedbackFixture()
	feedbackPartial(v, "partial")
	v.FenceInput("typed")
	feedbackHandoff(v, "request-a", "complete request")
	feedbackTranscript(t, v, "user", "complete request")
	if v.replyItemLocked("request-a", v.InputGeneration()) != "" || len(v.pendingTranscripts) != 0 {
		t.Fatal("a handoff captured unfinished ASR from an earlier generation")
	}
}

func TestVoiceFeedbackPendingIdentityPrecedesReentrantFinalAndFence(t *testing.T) {
	v := feedbackFixture()
	a := feedbackPartial(v, "partial")
	updated := false
	newer := ""
	v.listeners = map[string]func(plugin.VoiceEvent){"fixture": func(event plugin.VoiceEvent) {
		if event.Type != "input" || updated {
			return
		}
		updated = true
		feedbackTranscript(t, v, "user", "complete request")
		newer = feedbackTranscript(t, v, "user", "complete request").ItemID
		v.FenceInput("typed-input")
	}}
	feedbackHandoff(v, "request-a", "complete request")
	if item := v.replyItemLocked("request-a", v.InputGeneration()); item != a.ItemID || item == newer {
		t.Fatal("reentrant final/fence changed the ASR identity frozen at handoff")
	}
}

func TestVoiceFeedbackFinalDuringAnswerPublicationRepairsIdentity(t *testing.T) {
	v := feedbackFixture()
	a := feedbackPartial(v, "partial")
	feedbackHandoff(v, "request-a", "complete request")
	updated := false
	v.listeners = map[string]func(plugin.VoiceEvent){"fixture": func(event plugin.VoiceEvent) {
		if event.Type == "answer" && !updated {
			updated = true
			feedbackTranscript(t, v, "user", "complete request")
		}
	}}
	feedbackSpeakWithoutAudio(t, v, plugin.VoiceSpeech{DeliveryID: "delivery-a", DelegationID: "request-a", Generation: v.InputGeneration(), Text: "Real feedback"})
	resolved := v.events[len(v.events)-1]
	if resolved.Type != "answer" || resolved.ReplyToItemID != a.ItemID || resolved.DeliveryID != "delivery-a" || len(v.pendingAnswers) != 0 {
		t.Fatal("a final during publication lost the already delivered answer")
	}
}
