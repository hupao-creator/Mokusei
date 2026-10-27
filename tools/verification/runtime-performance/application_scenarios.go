package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/tools/verification/applicationhost/listfixture"
)

// The replay and measured query use the same public application fixture. Setup
// is excluded from measurement, including SQLite seeding and host registration.
func prepareApplicationScenario(ctx context.Context, name string, records int) (operation func(context.Context) error, close func() error, err error) {
	if name != "application-list" || records < 1 {
		return nil, nil, fmt.Errorf("invalid application scenario %q with %d records", name, records)
	}
	root, err := os.MkdirTemp("", "mokusei-performance-application-")
	if err != nil {
		return nil, nil, err
	}
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		_ = os.RemoveAll(root)
		return nil, nil, err
	}
	var host *applicationhost.Host
	close = func() error {
		if host != nil {
			if err := host.Stop(context.Background()); err != nil {
				return err
			}
		}
		if err := db.Close(); err != nil {
			return err
		}
		return os.RemoveAll(root)
	}
	if _, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("settings", model.DefaultSettings(nil)) }); err != nil {
		return nil, nil, errors.Join(err, close())
	}
	host, err = applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{listfixture.Application{}}})
	if err != nil {
		return nil, nil, errors.Join(err, close())
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		ids := make([]string, records)
		for index := range records {
			id := fmt.Sprintf("record-%09d", index)
			ids[records-index-1] = id
			record := model.VersionedRecord{ID: id, Revision: 1, CreatedAt: 1, UpdatedAt: 1, Value: json.RawMessage(`{"text":"collection fixture"}`)}
			if err := tx.Put("application:"+listfixture.CollectionID+":"+id, record); err != nil {
				return err
			}
		}
		return tx.SetOrder("application:"+listfixture.CollectionID, ids)
	})
	if err != nil {
		return nil, nil, errors.Join(err, close())
	}
	operation = func(ctx context.Context) error {
		ids, err := listfixture.Query(ctx, host)
		if err != nil {
			return err
		}
		if len(ids) != records || ids[0] != fmt.Sprintf("record-%09d", records-1) || ids[len(ids)-1] != "record-000000000" {
			return errors.New("collection list lost records or ordering")
		}
		return nil
	}
	return operation, close, nil
}
