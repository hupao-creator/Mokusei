package moku

import "context"

// ServiceVoiceActive includes preparation and teardown so the host does not
// relinquish its power assertion while media still owns audio resources.
func (c *Coordinator) ServiceVoiceActive() bool {
	c.voice.mu.Lock()
	defer c.voice.mu.Unlock()
	return c.voice.preparation != nil || c.voice.active != nil || len(c.voice.teardowns) > 0
}

// RevokeDeviceMedia retires only the authenticated device's current generation.
// Already admitted ordinary work has an independent lifetime.
func (c *Coordinator) RevokeDeviceMedia(ctx context.Context, device string) error {
	v := c.voice
	v.mu.Lock()
	preparation, lease := v.preparation, v.active
	if v.retiredDevice == device {
		v.retired, v.retiredID, v.retiredDevice, v.retiredOwnership = nil, "", "", ""
	}
	v.mu.Unlock()
	if preparation != nil && preparation.device == device {
		preparation.cancel()
	}
	if lease != nil && lease.device == device {
		v.retire(lease)
	}
	if err := takeVoiceQueue(ctx, v.commands); err != nil {
		return err
	}
	v.commands <- struct{}{}
	return v.waitTeardowns(ctx)
}
