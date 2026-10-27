package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func verifySettingsPerformance(ctx context.Context, root string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["MOKUSEI_SETTINGS_PERFORMANCE"] = root
	catalog := codex.NewCatalog(func(ctx context.Context, cwd, _ string) (*codex.AppServer, error) {
		return codex.StartAppServer(ctx, codex.LaunchOptions{Executable: executable, Cwd: cwd, Environment: environmentList(env)})
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
					_, err = catalog.LoadExecutionDefaults(ctx, root, "")
				} else {
					_, err = catalog.LoadPresentation(ctx, root, "", false)
				}
				failures <- err
			}()
		}
		workers.Wait()
		close(failures)
		for err := range failures {
			if err != nil {
				return err
			}
		}
		files, err := filepath.Glob(filepath.Join(root, "start-*"))
		if err != nil {
			return err
		}
		fmt.Printf("Codex settings %s: readers=8 nativeStartsTotal=%d elapsedMs=%.2f\n", phase, len(files), float64(time.Since(started))/float64(time.Millisecond))
	}
	return nil
}
