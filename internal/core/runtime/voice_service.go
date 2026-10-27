package runtime

import (
	"context"
	"errors"
)

func (r *Runtime) ServiceVoiceActive() bool {
	r.mu.Lock()
	moku := r.config.Moku
	r.mu.Unlock()
	if activity, ok := moku.(interface{ ServiceVoiceActive() bool }); ok && activity.ServiceVoiceActive() {
		return true
	}
	return r.voiceManager().Active()
}

func (r *Runtime) RevokeDeviceMedia(ctx context.Context, device string) error {
	r.mu.Lock()
	moku := r.config.Moku
	r.mu.Unlock()
	var mokuErr error
	if media, ok := moku.(interface {
		RevokeDeviceMedia(context.Context, string) error
	}); ok {
		mokuErr = media.RevokeDeviceMedia(ctx, device)
	}
	return errors.Join(mokuErr, r.voiceManager().RevokeDevice(ctx, device))
}
