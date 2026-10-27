package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// Both scenarios use the existing public Runtime APIs so the same fixture can
// exercise the baseline. Notification samples wait for the durable UpdateThread
// and synchronous OnThreadCommitted callbacks. They do not drain the asynchronous
// publisher; its work can overlap measurement, so these are neither isolated
// clone measurements nor complete publication measurements.
func prepareRuntimeScenario(ctx context.Context, name string, records int) (operation func(context.Context) error, close func() error, err error) {
	if records < 1 {
		return nil, nil, errors.New("runtime scenarios require at least one record")
	}
	if name != "runtime-list" && name != "runtime-notify" {
		return nil, nil, fmt.Errorf("unknown runtime scenario %q", name)
	}
	root, err := os.MkdirTemp("", "mokusei-performance-runtime-")
	if err != nil {
		return nil, nil, err
	}
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		_ = os.RemoveAll(root)
		return nil, nil, err
	}
	var runtime *core.Runtime
	close = func() error {
		if runtime != nil {
			if err := runtime.Close(context.Background()); err != nil {
				return err
			}
		}
		if err := db.Close(); err != nil {
			return err
		}
		return os.RemoveAll(root)
	}
	count, historyCount := records, 1
	if name == "runtime-notify" {
		count, historyCount = 1, records
	}
	// A history entry has a fixed payload. --records controls thread count for
	// enumeration and session-history entries for notification.
	history := make([]string, historyCount)
	for index := range history {
		history[index] = strings.Repeat("native history ", 16)
	}
	state, err := json.Marshal(map[string]any{"messages": history})
	if err != nil {
		return nil, nil, errors.Join(err, close())
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		order := make([]string, count)
		for index := range count {
			id := fmt.Sprintf("thread-%09d", index)
			order[index] = id
			thread := model.ThreadRecord{SessionRecord: model.SessionRecord{
				ID: id, HarnessID: "fixture", SessionState: state, Settings: json.RawMessage(`{}`),
				Cwd: root, CreatedAt: 1, UpdatedAt: 1,
			}, Title: "Fixture", Tags: []string{}, TagEmojis: map[string]string{}}
			if err := tx.Put("thread:"+id, thread); err != nil {
				return err
			}
		}
		return tx.SetOrder("threads", order)
	})
	if err != nil {
		return nil, nil, errors.Join(err, close())
	}
	runtime, err = core.New(ctx, core.Config{Store: db, DataDir: root, DefaultCwd: root})
	if err != nil {
		return nil, nil, errors.Join(err, close())
	}
	if name == "runtime-list" {
		operation = func(ctx context.Context) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			threads, err := runtime.Threads()
			if err == nil && len(threads) != count {
				return errors.New("thread enumeration changed")
			}
			return err
		}
	} else {
		var notifications int
		unsubscribe := runtime.OnThreadCommitted(func(thread model.ThreadRecord) {
			if thread.ID == "thread-000000000" && len(thread.SessionState) == len(state) {
				notifications++
			}
		})
		cleanup := close
		close = func() error { unsubscribe(); return cleanup() }
		operation = func(ctx context.Context) error {
			before := notifications
			if err := runtime.UpdateThread(ctx, "thread-000000000", func(*model.ThreadRecord) error { return nil }); err != nil {
				return err
			}
			if notifications != before+1 {
				return errors.New("committed-thread notification missing")
			}
			return nil
		}
	}
	return operation, close, nil
}
