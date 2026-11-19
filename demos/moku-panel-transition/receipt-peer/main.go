// The native Composer replay uses the production HTTP executor and ReceiptStore.
// Only the business handler and the timing of its result are fixtures.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type host struct {
	calls *os.File
	forks atomic.Uint64
}

func (*host) HasChannel(channel string) bool {
	switch channel {
	case "thread:fork", "thread:follow-up", "moku:submit", "harness:detect-installations":
		return true
	}
	return false
}

func (*host) SubscribeMutations(func(json.RawMessage)) func() { return func() {} }

func (*host) ReadThreadContent(context.Context, string, transport.ContentScope, *int64) (*transport.ContentSnapshot, error) {
	return nil, fmt.Errorf("unexpected content read")
}

func (h *host) Invoke(ctx context.Context, channel string, args []json.RawMessage) (any, error) {
	if channel == "harness:detect-installations" {
		return []any{}, nil
	}
	if err := json.NewEncoder(h.calls).Encode(map[string]any{"channel": channel, "args": args}); err != nil {
		return nil, err
	}
	for {
		mode, err := os.ReadFile("mode")
		if err != nil {
			return nil, err
		}
		switch string(mode) {
		case "lose":
		case "lose-fork":
			if channel != "thread:fork" {
				return nil, fmt.Errorf("unexpected %s before fork", channel)
			}
		case "lose-followup":
			if channel == "thread:fork" {
				return h.branch(), nil
			}
		case "reject", "direct-reject":
			return nil, model.NewError("REJECTED", "Fixture rejected the input")
		case "execution-changed":
			var request struct {
				ExpectedExecutionID string `json:"expectedExecutionId"`
			}
			if err := json.Unmarshal(args[0], &request); err != nil {
				return nil, err
			}
			if request.ExpectedExecutionID != "" {
				return nil, model.NewError("EXECUTION_CHANGED", "Fixture checkpoint changed")
			}
			fallthrough
		case "accepted":
			if channel == "thread:fork" {
				return h.branch(), nil
			}
			return map[string]string{"executionId": "E"}, nil
		default:
			return nil, fmt.Errorf("unexpected fixture mode %q", mode)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func (h *host) branch() map[string]string {
	return map[string]string{"threadId": fmt.Sprintf("fixture-branch-%d", h.forks.Add(1))}
}

func run() error {
	dir, err := os.Getwd()
	if err != nil || filepath.Base(dir) != "workspace" || !strings.HasPrefix(filepath.Base(filepath.Dir(dir)), "mokusei-native-replay-") {
		return fmt.Errorf("receipt peer requires a disposable native replay workspace")
	}
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(dir, "server-profile"), HomeDir: dir})
	if err != nil {
		return err
	}
	owner, err := profile.Acquire(p)
	if err != nil {
		return err
	}
	defer owner.Release()
	calls, err := os.OpenFile("handler-calls.jsonl", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer calls.Close()
	server, err := transport.Start(transport.Options{Profile: p, Epoch: owner.Epoch, Host: &host{calls: calls}})
	if err != nil {
		return err
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Close(ctx)
	}()
	if err := json.NewEncoder(os.Stdout).Encode(server.Connection); err != nil {
		return err
	}
	_, err = io.Copy(io.Discard, os.Stdin)
	return err
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
