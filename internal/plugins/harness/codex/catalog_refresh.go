package codex

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
)

// T3 Code gives ChatGPT startup discovery a short window to observe the native
// cache refresh and enumerate again. The timestamp is only a refresh hint: other
// native clients share this file, and it does not certify account or provenance.
// This runs inside cold/background probes, never before returning a warm catalog.
func refreshRoutingModels(ctx context.Context, server *AppServer, started time.Time, initial []Map) ([]Map, string) {
	refresh, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	subscription, err := HasNativeSubscription(refresh, server)
	if err != nil {
		return initial, "account-kind lookup unavailable; retained first native enumeration"
	}
	if !subscription {
		return initial, "ChatGPT refresh hint not applicable"
	}
	path := filepath.Join(ceCodexHome(ceEnvironment(server.launch.Environment)), "models_cache.json")
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	lastStamp := ""
	for {
		stamp := discovery.Identity(nil, path)
		if stamp != lastStamp && nativeCatalogRefreshed(path, started) {
			models, err := ListModels(refresh, server)
			if err == nil && len(models) > 0 {
				return models, "native refresh hint observed; second enumeration succeeded (not source attestation)"
			}
			// Even a later-page failure must not destroy the first complete
			// enumeration. No partial second result is ever published.
			return initial, "refresh reread failed or returned empty; retained first native enumeration"
		}
		lastStamp = stamp
		select {
		case <-refresh.Done():
			return initial, "native refresh hint not observed within budget; retained first native enumeration"
		case <-ticker.C:
		}
	}
}

func nativeCatalogRefreshed(path string, started time.Time) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 8*1024*1024 {
		return false
	}
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	var stamp struct {
		FetchedAt string `json:"fetched_at"`
	}
	if json.NewDecoder(io.LimitReader(file, 8*1024*1024)).Decode(&stamp) != nil {
		return false
	}
	at, err := time.Parse(time.RFC3339Nano, stamp.FetchedAt)
	return err == nil && !at.Before(started)
}
