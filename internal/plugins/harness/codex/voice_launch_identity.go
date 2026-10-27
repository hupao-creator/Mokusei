package codex

import (
	"context"
	"crypto/sha256"
	"encoding/json"
)

// Prewarmed isolated homes contain copied credentials/configuration. Revalidate
// their source inputs before reuse, including native authentication and effective configuration.
func (h *Handle) voiceLaunchIdentity(ctx context.Context, o *NativeOptions, executable string) ([32]byte, error) {
	env, err := h.adapter.environment(ctx)
	if err != nil {
		return [32]byte{}, err
	}
	key, err := launchCatalogKey(executable, env, o.Cwd)
	if err != nil {
		return [32]byte{}, err
	}
	data, err := json.Marshal([]any{key, o.Cwd, o.ToolMode})
	if err != nil {
		return [32]byte{}, err
	}
	return sha256.Sum256(data), nil
}
