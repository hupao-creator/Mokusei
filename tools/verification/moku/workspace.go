package main

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

func replayWorkspaceWithoutAccounts() {
	var calls atomic.Int32
	host := plugin.HostContext{Environment: func(context.Context) (map[string]string, error) {
		calls.Add(1)
		return nil, errors.New("workspace must not discover credentials")
	}, ResolveExecutable: func(context.Context, string, string, string) (string, error) {
		calls.Add(1)
		return "", errors.New("workspace must not start native processes")
	}}
	harnesses := []plugin.Harness{codex.New(host), claude.New(host), pi.New(host), opencode.New(host)}
	for _, h := range harnesses {
		contributor, contributes := h.(plugin.MokuContextContributor)
		if !contributes {
			continue
		}
		for _, purpose := range []string{"workspace", "unrecognized"} {
			text, err := contributor.MokuContext(mokuReplayContext(), purpose, plugin.SettingsRequest{}, nil)
			mokuReplayMust(err)
			mokuReplayCheck(text == "", "non-telemetry context exposed account information")
		}
		cancelled, cancel := context.WithCancel(mokuReplayContext())
		cancel()
		_, err := contributor.MokuContext(cancelled, "workspace", plugin.SettingsRequest{}, nil)
		mokuReplayCheck(errors.Is(err, context.Canceled), "workspace swallowed cancellation")
		if closer, ok := h.(plugin.Closer); ok {
			mokuReplayMust(closer.Close())
		}
	}
	mokuReplayCheck(calls.Load() == 0, "workspace queried native environment/accounts")
	fmt.Println("PASS workspace purpose: Harnesses omit or return empty context without environment, executable, credentials or quota I/O; cancellation preserved")
}
