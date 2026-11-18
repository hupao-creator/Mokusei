package codex

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"testing/synctest"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
	"github.com/hupao-creator/Mokusei/tools/verification/pbt/rapidcheck"
	"pgregory.net/rapid"
)

// PBT-CODEX-CATALOG: settings and default-model reads share this freshness
// boundary. The probe's serial number stands in for its native enumeration.
func TestNativeCatalogWriteProperties(t *testing.T) {
	rapidcheck.Check(t, func(rt *rapid.T) {
		home := t.TempDir()
		minor := rapid.IntRange(0, 999).Draw(rt, "minor")
		patch := rapid.IntRange(0, 99).Draw(rt, "patch")
		version := fmt.Sprintf("0.%d.%d", minor, patch)
		client := rapid.SampledFrom([]string{version, fmt.Sprintf("0.%d.%d", minor, patch+1)}).Draw(rt, "writer")
		phase := rapid.SampledFrom([]string{"before", "during", "after"}).Draw(rt, "write")
		valid := rapid.Bool().Draw(rt, "validTimestamp")
		var observed [3]int
		var err error
		synctest.Test(t, func(_ *testing.T) {
			observed, err = observeCatalogWrite(home, version, client, phase, valid)
		})
		if err != nil {
			rt.Fatal(err)
		}
		want := [3]int{1, 1, 1}
		if valid && client == version && phase != "before" {
			want = [3]int{1, 2, 2}
		}
		if observed != want {
			rt.Fatalf("native enumerations %v, want %v", observed, want)
		}
	})
}

func observeCatalogWrite(home, version, writer, phase string, valid bool) ([3]int, error) {
	var cache discovery.Cache[int]
	defer cache.Close()
	var observed [3]int
	path := filepath.Join(home, "models_cache.json")
	write := func() error {
		// The native payload date can be old. A compatible file's write time
		// determines whether it can invalidate this particular observation.
		date := "2000-01-01T00:00:00Z"
		if !valid {
			date = "unavailable"
		}
		data := fmt.Sprintf(`{"client_version":%q,"fetched_at":%q}`, writer, date)
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			return err
		}
		now := time.Now()
		return os.Chtimes(path, now, now)
	}
	if phase == "before" {
		if err := write(); err != nil {
			return observed, err
		}
	}
	probes := 0
	for i := range observed {
		time.Sleep(time.Second) // Virtual time separates the write, probe start and publication.
		hint := matchingNativeCatalogWrite(home, "codex-cli "+version)
		value, err := cache.GetFreshAfter(context.Background(), "settings", false, 5*time.Minute, time.Minute, hint,
			func(context.Context) (int, error) {
				probes++
				if probes == 1 && phase == "during" {
					time.Sleep(time.Second)
					if err := write(); err != nil {
						return 0, err
					}
					time.Sleep(time.Second)
				}
				return probes, nil
			})
		if err != nil {
			return observed, err
		}
		observed[i] = value
		if i == 0 && phase == "after" {
			time.Sleep(time.Second)
			if err := write(); err != nil {
				return observed, err
			}
		}
	}
	return observed, nil
}
