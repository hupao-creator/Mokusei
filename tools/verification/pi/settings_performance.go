package main

import (
	"context"
	"fmt"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

func verifySettingsSharing(ctx context.Context, assert bool) {
	options := fixtureOptions("settings-sharing")
	adapter := pi.New(plugin.HostContext{
		Environment:       func(context.Context) (map[string]string, error) { return options.Env, nil },
		ResolveExecutable: func(context.Context, string, string, string) (string, error) { return options.ExecutablePath, nil },
	})
	for _, phase := range []string{"cold", "warm"} {
		started := time.Now()
		var workers sync.WaitGroup
		failures := make(chan error, 8)
		for i := range 8 {
			workers.Add(1)
			go func() {
				defer workers.Done()
				var err error
				if i%2 == 0 {
					_, err = adapter.Probe(ctx, plugin.SettingsRequest{Settings: adapter.DefaultSettings(), Cwd: options.Cwd}, "settings")
				} else {
					_, err = adapter.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{Settings: adapter.DefaultSettings(), Cwd: options.Cwd})
				}
				failures <- err
			}()
		}
		workers.Wait()
		close(failures)
		for err := range failures {
			check(err == nil, "settings sharing: "+fmt.Sprint(err))
		}
		files, err := filepath.Glob(filepath.Join(fixtureRoot, "settings-start-*"))
		check(err == nil, "count settings processes")
		fmt.Printf("Pi settings %s: readers=8 nativeStartsTotal=%d elapsedMs=%.2f\n", phase, len(files), float64(time.Since(started))/float64(time.Millisecond))
		if assert {
			check(len(files) == 1, "state/catalog readers did not share one native process")
		}
	}
}
