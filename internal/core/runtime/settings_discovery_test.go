package runtime

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type installationFixture struct {
	plugin.Harness
	detect func(context.Context) (plugin.Installation, error)
}

func (h installationFixture) Detect(ctx context.Context, _ string) (plugin.Installation, error) {
	return h.detect(ctx)
}

func TestAutomaticInstallationReadsAreIndependentAndDoNotRefreshEnvironment(t *testing.T) {
	var refreshes atomic.Int32
	entered := make(chan struct{}, 1)
	r := &Runtime{config: Config{Harnesses: map[string]plugin.Harness{
		"fast": installationFixture{detect: func(context.Context) (plugin.Installation, error) {
			return plugin.Installation{Status: "installed"}, nil
		}},
		"slow": installationFixture{detect: func(ctx context.Context) (plugin.Installation, error) {
			entered <- struct{}{}
			<-ctx.Done()
			return plugin.Installation{}, ctx.Err()
		}},
	}, RefreshEnvironment: func(context.Context) error { refreshes.Add(1); return nil }}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	slow := make(chan error, 1)
	go func() { _, err := r.DetectInstallation(ctx, "slow"); slow <- err }()
	<-entered
	fastCtx, stop := context.WithTimeout(context.Background(), time.Second)
	defer stop()
	for range 8 {
		value, err := r.DetectInstallation(fastCtx, "fast")
		if err != nil || value.Status != "installed" {
			t.Fatal("slow Harness blocked fast installation", err)
		}
	}
	if refreshes.Load() != 0 {
		t.Fatal("automatic reads refreshed login shell")
	}
	cancel()
	<-slow
	delete(r.config.Harnesses, "slow")
	if _, err := r.DetectInstallations(context.Background()); err != nil {
		t.Fatal(err)
	}
	if refreshes.Load() != 1 {
		t.Fatal("explicit recovery did not refresh environment exactly once")
	}
}
