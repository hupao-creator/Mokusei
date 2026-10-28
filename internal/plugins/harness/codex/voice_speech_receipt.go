package codex

import (
	"context"
	"errors"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type voiceSpeechReceipt struct {
	generation   int64
	acknowledged bool
	closed       bool
	done         chan struct{}
}

func (v *VoiceSession) ConfirmSpeech(ctx context.Context, deliveryID string, generation int64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if !v.deliveries[deliveryID] {
		return errors.New("Unknown voice delivery")
	}
	receipt := v.speechReceipts[deliveryID]
	if receipt == nil || receipt.generation != generation || generation != v.generation {
		return nil
	}
	if !receipt.closed {
		receipt.closed = true
		receipt.acknowledged = true
		close(receipt.done)
	}
	return nil
}

func (v *VoiceSession) awaitSpeechReceipt(ctx context.Context, speech plugin.VoiceSpeech) error {
	v.mu.Lock()
	if v.phase != "live" || speech.Generation != v.generation {
		v.mu.Unlock()
		return context.Canceled
	}
	if v.speechReceipts == nil {
		v.speechReceipts = map[string]*voiceSpeechReceipt{}
	}
	receipt := &voiceSpeechReceipt{generation: speech.Generation, done: make(chan struct{})}
	v.speechReceipts[speech.DeliveryID] = receipt
	v.mu.Unlock()
	defer func() { v.mu.Lock(); delete(v.speechReceipts, speech.DeliveryID); v.mu.Unlock() }()
	v.publish(plugin.VoiceEvent{Type: "speech-ready", Generation: &speech.Generation, DeliveryID: speech.DeliveryID})
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-v.lifetime.Done():
		return v.lifetime.Err()
	case <-deadline.C:
		return errors.New("语音播放确认超时")
	case <-receipt.done:
	}
	v.mu.Lock()
	current := receipt.acknowledged && speech.Generation == v.generation && v.phase == "live"
	v.mu.Unlock()
	if !current {
		return context.Canceled
	}
	return nil
}
