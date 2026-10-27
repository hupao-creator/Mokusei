package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// Setup and cleanup stay outside the caller's measured/profiled operation range.
// Only public Store APIs are used, so the same fixture runs against the baseline.
func prepareStoreScenario(ctx context.Context, name string, records int) (operation func(context.Context) error, close func() error, err error) {
	if records < 1 {
		return nil, nil, errors.New("store scenarios require at least one historical event")
	}
	switch name {
	case "store-noop", "store-lifecycle-append", "store-work-read":
	default:
		return nil, nil, fmt.Errorf("unknown store scenario %q", name)
	}
	root, err := os.MkdirTemp("", "mokusei-performance-store-")
	if err != nil {
		return nil, nil, err
	}
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		_ = os.RemoveAll(root)
		return nil, nil, err
	}
	close = func() error {
		if err := db.Close(); err != nil {
			return err
		}
		return os.RemoveAll(root)
	}
	event := func(index int) store.Event {
		return store.Event{
			ID: fmt.Sprintf("history-%09d", index), CreatedAt: int64(index), Type: "entity.updated",
			Subject: store.Subject{Kind: "thread", ID: "fixture", TypeID: "fixture"}, Source: "fixture",
			Data: json.RawMessage(`{"value":"historical lifecycle fact"}`),
		}
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		for index := range records {
			if err := tx.AppendEvent(event(index)); err != nil {
				return err
			}
		}
		return tx.SetWork("fixture", "", store.Work{ID: "batch", EventIDs: []string{event(0).ID}})
	})
	if err != nil {
		return nil, nil, errors.Join(err, close())
	}
	switch name {
	case "store-noop":
		operation = db.Flush
	case "store-lifecycle-append":
		next := records
		operation = func(ctx context.Context) error {
			_, err := db.Update(ctx, func(tx *store.Tx) error { return tx.AppendEvent(event(next)) })
			if err == nil {
				next++
			}
			return err
		}
	case "store-work-read":
		operation = func(ctx context.Context) error {
			_, err := db.Update(ctx, func(tx *store.Tx) error {
				for range 32 {
					work, exists, err := tx.Work("fixture")
					if err != nil {
						return err
					}
					if !exists || work.ID != "batch" || len(work.EventIDs) != 1 {
						return errors.New("historical lifecycle work changed")
					}
				}
				return nil
			})
			return err
		}
	}
	return operation, close, nil
}
