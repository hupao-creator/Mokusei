package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/tools/verification/applicationhost/listfixture"
)

func verifyCollectionFanout(ctx context.Context) error {
	for _, size := range []int{16, 256} {
		if err := collectionFanout(ctx, size); err != nil {
			return fmt.Errorf("catalog/index fanout N=%d: %w", size, err)
		}
	}
	return nil
}

func collectionFanout(ctx context.Context, size int) (err error) {
	directory, err := os.MkdirTemp("", "mokusei-collection-fanout-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, db.Close()) }()
	if _, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("settings", model.DefaultSettings(nil)) }); err != nil {
		return err
	}
	var indexes, projections atomic.Int64
	host, err := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{listfixture.Application{IndexCalls: &indexes, ProjectCalls: &projections}}})
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, host.Stop(ctx)) }()
	prefix := "application:" + listfixture.CollectionID + ":"
	record := func(id, bucket string, revision int64) model.VersionedRecord {
		value, _ := json.Marshal(map[string]string{"bucket": bucket, "html": strings.Repeat("unrelated retained document ", 1024)})
		return model.VersionedRecord{ID: id, Revision: revision, CreatedAt: 1, UpdatedAt: revision, Value: value}
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		for n := range size {
			id := fmt.Sprintf("record-%03d", n)
			if err := tx.Put(prefix+id, record(id, id, 1)); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	initial := db.Snapshot()
	if _, err = host.CatalogSnapshot(ctx, initial); err != nil {
		return err
	}
	checkIndex := func(key string, count int, want []string) error {
		got, err := listfixture.QueryIndex(ctx, host, key)
		if err != nil {
			return err
		}
		if got.Count != count || !slices.Equal(got.IDs, want) {
			return fmt.Errorf("index %s: got %+v, want count=%d ids=%v", key, got, count, want)
		}
		return nil
	}
	if err = checkIndex("record-000", size, []string{"record-000"}); err != nil {
		return err
	}
	if indexes.Load() != int64(size) || projections.Load() != int64(size) {
		return errors.New("initial catalog/index did not project each source exactly once")
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("telemetry:unrelated", 1) })
	if err != nil {
		return err
	}
	patch, err := host.CatalogChanges(ctx, initial, db.Snapshot())
	if err != nil {
		return err
	}
	if patch != nil {
		return errors.New("telemetry produced a catalog patch")
	}
	if err = checkIndex("record-000", size, []string{"record-000"}); err != nil {
		return err
	}
	if indexes.Load() != int64(size) || projections.Load() != int64(size) {
		return errors.New("telemetry reprojected unrelated records")
	}
	previous := db.Snapshot()
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put(prefix+"record-000", record("record-000", "changed", 2)) })
	if err != nil {
		return err
	}
	patch, err = host.CatalogChanges(ctx, previous, db.Snapshot())
	if err != nil {
		return err
	}
	if patch == nil || len(patch.Upserts) != 1 || patch.Order != nil || len(patch.RemovedIDs) != 0 {
		return errors.New("point update did not produce one isolated upsert")
	}
	if err = checkIndex("record-000", size, nil); err != nil {
		return err
	}
	if err = checkIndex("changed", size, []string{"record-000"}); err != nil {
		return err
	}
	if indexes.Load() != int64(size+1) || projections.Load() != int64(size+1) {
		return errors.New("point update reprojected unrelated records")
	}
	patch.Upserts[0].View[0] = '!'
	patch, err = host.CatalogChanges(ctx, previous, db.Snapshot())
	if err != nil {
		return err
	}
	if !json.Valid(patch.Upserts[0].View) || projections.Load() != int64(size+1) {
		return errors.New("caller mutated the private catalog cache")
	}
	previous = db.Snapshot()
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Delete(prefix + "record-000") })
	if err != nil {
		return err
	}
	patch, err = host.CatalogChanges(ctx, previous, db.Snapshot())
	if err != nil {
		return err
	}
	if patch == nil || !slices.Equal(patch.RemovedIDs, []string{"record-000"}) || len(patch.Upserts) != 0 {
		return errors.New("deletion lost catalog identity")
	}
	if err = checkIndex("changed", size-1, nil); err != nil {
		return err
	}
	if indexes.Load() != int64(size+1) || projections.Load() != int64(size+1) {
		return errors.New("deletion decoded unrelated records")
	}
	// A retained snapshot remains coherent even after cache installation for a
	// newer view; the cache may never substitute a current record into the old one.
	old, err := host.CatalogSnapshot(ctx, initial)
	if err != nil {
		return err
	}
	if len(old) != size || old[0].Revision != 1 {
		return errors.New("catalog cache corrupted a retained snapshot")
	}
	return nil
}
