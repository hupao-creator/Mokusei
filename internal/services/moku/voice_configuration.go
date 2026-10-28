package moku

import "context"

// A relay belongs to the Moku conversation, independently of its task engine.
// Reopening that engine must retain the media lease and its pending speech;
// native media instead belongs to the handle being replaced.
func (v *voiceController) stopForConfiguration(ctx context.Context, owner string) error {
	v.mu.Lock()
	lease := v.active
	keepRelay := lease != nil && lease.owner == owner && !lease.native
	v.mu.Unlock()
	if keepRelay {
		return v.waitTeardowns(ctx)
	}
	return v.stop(ctx)
}

func (v *voiceController) ownsNative(owner string) bool {
	v.mu.Lock()
	lease := v.active
	native := lease != nil && lease.owner == owner && lease.native
	v.mu.Unlock()
	return native && v.owns(owner)
}
