package codex

import (
	"context"
	"errors"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (v *VoiceSession) CloseForConfiguration(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	v.mu.Lock()
	v.configurationRetired = true
	v.mu.Unlock()
	// Freeze the serialized native notification boundary before closing. A
	// previously admitted task wins over a delayed reconnect request.
	v.native.notificationMu.Lock()
	v.native.mu.Lock()
	busy := !v.native.terminal || len(v.native.background) > 0
	v.native.mu.Unlock()
	if busy {
		v.native.notificationMu.Unlock()
		return errors.New("原生任务正在执行，语音配置重连暂未应用")
	}
	err := v.native.Close()
	v.native.notificationMu.Unlock()
	v.mu.Lock()
	if err == nil && v.configurationRequest == nil {
		for _, id := range v.order {
			if !v.projected[id] {
				if v.configurationRequest != nil {
					err = errors.New("多条语音请求仍在交接，无法自动恢复；请查看原始转写")
					break
				}
				request := v.requests[id]
				v.configurationRequest = &request
				v.projected[id] = true
			}
		}
	}
	v.mu.Unlock()
	v.configurationRejected(err)
	return err
}

func (v *VoiceSession) OnConfigurationRecovery(callback func(plugin.VoiceDelegation, error)) func() {
	v.mu.Lock()
	if v.configurationListeners == nil {
		v.configurationListeners = map[string]func(plugin.VoiceDelegation, error){}
	}
	id := uid()
	v.configurationListeners[id] = callback
	v.mu.Unlock()
	return func() { v.mu.Lock(); delete(v.configurationListeners, id); v.mu.Unlock() }
}

func (v *VoiceSession) configurationRejected(cleanupErr error) {
	v.configurationMu.Lock()
	defer v.configurationMu.Unlock()
	v.mu.Lock()
	request := v.configurationRequest
	v.configurationRequest = nil
	v.configurationRetired = true
	// Process drain is stronger evidence than a realtime/stop response. There
	// is no live peer left to stop, and reconnect must not prewarm the old model.
	if cleanupErr == nil {
		v.remoteClosed = true
	}
	callbacks := []func(plugin.VoiceDelegation, error){}
	for _, callback := range v.configurationListeners {
		callbacks = append(callbacks, callback)
	}
	v.mu.Unlock()
	if request != nil {
		for _, callback := range callbacks {
			callback(*request, cleanupErr)
		}
	}
	if cleanupErr != nil {
		v.fail(cleanupErr)
		return
	}
	_ = v.Close()
}
