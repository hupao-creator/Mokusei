package codex

import (
	"context"
	"errors"
	"time"
)

var errNativeVoiceAdmissionCancelled = errors.New("native voice input cancelled before execution admission")

func (v *VoiceSession) cancelNativeAdmission(turnID string) {
	v.mu.Lock()
	done := v.nativeCancellationDone
	v.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		_, err := v.native.server.Call(ctx, "turn/interrupt", Map{"threadId": v.threadID, "turnId": turnID})
		v.mu.Lock()
		v.nativeCancellationErr = err
		close(done)
		v.mu.Unlock()
	}()
}

// Ending media cancels a still-waiting native input, while already admitted
// work retains its handle lifetime. Stop joins the cancellation acknowledgement
// without treating deliberate cancellation as a broken protocol channel.
func (v *VoiceSession) waitCancelledNativeAdmission(ctx context.Context) error {
	v.mu.Lock()
	admission := v.nativeAdmissionDone
	v.mu.Unlock()
	if admission != nil {
		select {
		case <-admission:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	v.mu.Lock()
	cancellation := v.nativeCancellationDone
	v.mu.Unlock()
	if cancellation != nil {
		select {
		case <-cancellation:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.nativeCancellationErr
}
