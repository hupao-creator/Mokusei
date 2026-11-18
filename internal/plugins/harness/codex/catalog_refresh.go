package codex

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
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
	stamp := readNativeCatalogStamp(path)
	return !stamp.fetchedAt.IsZero() && !stamp.fetchedAt.Before(started)
}

// A different client version can overwrite the shared cache even when our
// last enumeration is usable. Only a compatible write prompts a fresh read.
func matchingNativeCatalogWrite(home, version string) time.Time {
	parsed := ceParseVersion(version)
	if parsed == nil {
		return time.Time{}
	}
	stamp := readNativeCatalogStamp(filepath.Join(home, "models_cache.json"))
	if stamp.clientVersion != strings.Join(parsed.numbers[:], ".") {
		return time.Time{}
	}
	return stamp.modifiedAt
}

type nativeCatalogStamp struct {
	clientVersion string
	fetchedAt     time.Time
	modifiedAt    time.Time
}

func readNativeCatalogStamp(path string) nativeCatalogStamp {
	const limit = 8 * 1024 * 1024
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nativeCatalogStamp{}
	}
	file, err := os.Open(path)
	if err != nil {
		return nativeCatalogStamp{}
	}
	defer file.Close()
	info, err = file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nativeCatalogStamp{}
	}
	var stamp struct {
		FetchedAt     string `json:"fetched_at"`
		ClientVersion string `json:"client_version"`
	}
	if json.NewDecoder(io.LimitReader(file, limit)).Decode(&stamp) != nil {
		return nativeCatalogStamp{}
	}
	at, err := time.Parse(time.RFC3339Nano, stamp.FetchedAt)
	if err != nil {
		return nativeCatalogStamp{}
	}
	return nativeCatalogStamp{clientVersion: stamp.ClientVersion, fetchedAt: at, modifiedAt: info.ModTime()}
}
