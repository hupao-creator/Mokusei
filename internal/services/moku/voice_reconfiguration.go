package moku

import (
	"context"
	"errors"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type voiceReconfiguration struct {
	owner, device, ownership, session string
	ready                             chan struct{}
	pending                           *plugin.VoiceDelegation
	err                               error
}

// A native realtime owner cannot replace its model/tool configuration while
// preserving its peer. Poll asks the same authenticated device to reconnect at
// an idle input boundary; it never starts media or moves another device's lease.
func (v *voiceController) configurationReconnect(ctx context.Context, request mokuVoiceCommand, device string) (reconnect bool, err error) {
	v.mu.Lock()
	retired := v.reconfiguration
	if retired != nil && retired.device == device && retired.ownership == request.OwnershipID && retired.session == request.SessionID && v.retiredID == request.SessionID {
		ready := retired.ready == nil && retired.err == nil
		v.mu.Unlock()
		// The old media has already retired. Do not let a slow settings save
		// turn its closed event into an explicit end of the retained call.
		return ready, ctx.Err()
	}
	v.mu.Unlock()
	// Poll owns media heartbeats. A slow native settings save must not stall
	// those heartbeats; this advisory idle check can wait for the next poll.
	probe, cancel := context.WithTimeout(ctx, 25*time.Millisecond)
	defer cancel()
	err = v.c.admitSettings(probe, func(ctx context.Context) error {
		var readErr error
		reconnect, readErr = v.configurationReconnectLocked(ctx, request, device)
		return readErr
	})
	if errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
		return false, nil
	}
	return
}

func (v *voiceController) configurationReconnectLocked(ctx context.Context, request mokuVoiceCommand, device string) (bool, error) {
	current, err := v.c.current()
	if err != nil {
		return false, err
	}
	if live(current) {
		return false, nil
	}
	v.mu.Lock()
	lease, reconnect := v.active, v.reconfiguration
	if reconnect != nil && reconnect.device == device && reconnect.ownership == request.OwnershipID && reconnect.session == request.SessionID {
		ready := reconnect.ready == nil && reconnect.err == nil && !v.hasPendingSpeechLocked(reconnect.owner)
		v.mu.Unlock()
		return ready, nil
	}
	v.mu.Unlock()
	if lease == nil || !lease.native || lease.id != request.SessionID || lease.requestID != request.OwnershipID || lease.device != device {
		return false, nil
	}
	if current.ID != lease.owner {
		return false, nil
	}
	settings, _, err := v.c.config.Settings()
	if err != nil {
		return false, err
	}
	v.c.mu.Lock()
	applied := v.c.applied
	pending := applied != nil && !sameMokuSettings(applied.AppliedSettings, settings)
	v.c.mu.Unlock()
	if !pending {
		return false, nil
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.active != lease || lease.ctx.Err() != nil || v.hasPendingSpeechLocked(lease.owner) {
		return false, nil
	}
	v.ensureReconfigurationLocked(lease)
	return true, ctx.Err()
}

func (v *voiceController) ensureReconfigurationLocked(lease *mokuVoiceLease) *voiceReconfiguration {
	if v.reconfiguration == nil || v.reconfiguration.ownership != lease.requestID {
		v.reconfiguration = &voiceReconfiguration{owner: lease.owner, device: lease.device, ownership: lease.requestID, session: lease.id}
	}
	return v.reconfiguration
}

func (v *voiceController) rejectStaleNativeConfiguration(lease *mokuVoiceLease) error {
	current, err := v.c.current()
	if err != nil {
		return err
	}
	// A native background owner still belongs to the admitted configuration.
	// Its new foreground work must not close the process underneath that work.
	if current.Observation.BackgroundWork != nil {
		return nil
	}
	settings, _, err := v.c.config.Settings()
	if err != nil {
		return err
	}
	v.c.mu.Lock()
	applied := v.c.applied
	pending := applied != nil && !sameMokuSettings(applied.AppliedSettings, settings)
	v.c.mu.Unlock()
	v.mu.Lock()
	if v.reconfiguration != nil && v.reconfiguration.ownership == lease.requestID {
		pending = true
	}
	if !pending {
		v.mu.Unlock()
		return nil
	}
	defer v.mu.Unlock()
	retiring := v.reconfiguration != nil && v.reconfiguration.ownership == lease.requestID && v.retiredLease == lease
	if !retiring && (v.active != lease || lease.ctx.Err() != nil) {
		return errors.New("Voice owner 已失效")
	}
	reconnect := v.ensureReconfigurationLocked(lease)
	if reconnect.ready == nil {
		reconnect.ready = make(chan struct{})
	}
	return plugin.ErrMokuConfigurationPending
}

func (v *voiceController) recoveredNativeConfiguration(lease *mokuVoiceLease, request plugin.VoiceDelegation, cleanupErr error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	reconnect := v.reconfiguration
	if reconnect == nil || reconnect.ownership != lease.requestID {
		return
	}
	if cleanupErr != nil {
		reconnect.err = cleanupErr
	}
	if cleanupErr == nil && reconnect.err == nil {
		if reconnect.pending != nil && *reconnect.pending != request {
			reconnect.err = errors.New("多条语音请求仍在交接，未自动重送；请查看原始转写")
		} else {
			copy := request
			reconnect.pending = &copy
		}
	}
	if reconnect.ready != nil {
		close(reconnect.ready)
		reconnect.ready = nil
	}
}

func (v *voiceController) waitConfigurationRecovery(ctx context.Context, reconnect *voiceReconfiguration) error {
	if reconnect == nil {
		return nil
	}
	v.mu.Lock()
	ready := reconnect.ready
	v.mu.Unlock()
	if ready != nil {
		select {
		case <-ready:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.reconfiguration != reconnect {
		return model.NewError("VOICE_OWNERSHIP_CHANGED", "语音重连已取消")
	}
	return reconnect.err
}

func (v *voiceController) resumeConfigurationInput(lease *mokuVoiceLease) {
	v.mu.Lock()
	request := lease.resume
	lease.resume = nil
	v.mu.Unlock()
	if request == nil {
		return
	}
	v.c.launch(func(ctx context.Context) {
		waitCtx, finish := voiceLeaseContext(ctx, lease)
		err := takeVoiceQueue(waitCtx, v.admissions)
		finish()
		if err != nil {
			return
		}
		defer func() { v.admissions <- struct{}{} }()
		v.mu.Lock()
		active := v.active == lease && lease.ctx.Err() == nil
		v.mu.Unlock()
		if !active || lease.session.Closed() {
			return
		}
		lease.session.FenceInput(request.ID)
		// The fresh media has no native handoff with the retired ID. Bind speech
		// to this accepted input generation without inventing a native handoff.
		delivery := &voiceDelivery{owner: lease.owner, session: lease.session, deliveryID: lease.id + ":" + request.ID, generation: lease.session.InputGeneration(), lease: lease}
		err = v.c.submit(ctx, SubmitRequest{Input: voiceTextInput(request.Text)}, delivery, request.Context)
		v.c.report("voice-configuration-input", err)
		if err != nil && !lease.session.Closed() {
			speechCtx, cancel := voiceLeaseContext(ctx, lease)
			defer cancel()
			v.c.report("voice-configuration-speech", lease.session.Speak(speechCtx, plugin.VoiceSpeech{DeliveryID: delivery.deliveryID + ":failed", Generation: delivery.generation, RequireReceipt: lease.native, Text: "配置已更新，但刚才的请求未能被 Moku 接受：" + err.Error()}))
		}
	})
}

func (v *voiceController) discardReconfigurationLocked() {
	if reconnect := v.reconfiguration; reconnect != nil {
		if reconnect.ready != nil {
			close(reconnect.ready)
			reconnect.ready = nil
		}
		if v.preparation != nil && v.preparation.reconnect == reconnect {
			v.preparation.cancel()
		}
		v.reconfiguration = nil
	}
}

func (v *voiceController) closeConfigurationOwner(ctx context.Context, reconnect *voiceReconfiguration) error {
	v.mu.Lock()
	lease := v.active
	if lease == nil {
		lease = v.retiredLease
	}
	v.mu.Unlock()
	if lease == nil || lease.requestID != reconnect.ownership || lease.device != reconnect.device {
		return model.NewError("VOICE_OWNERSHIP_CHANGED", "语音重连所有权已变化")
	}
	closer, ok := lease.session.(plugin.VoiceConfigurationCloser)
	if !ok {
		return errors.New("此原生语音不支持安全配置重连")
	}
	err := closer.CloseForConfiguration(ctx)
	v.mu.Lock()
	unsubscribe := lease.unsubscribeRecovery
	lease.unsubscribeRecovery = nil
	v.mu.Unlock()
	if unsubscribe != nil {
		unsubscribe()
	}
	return err
}
