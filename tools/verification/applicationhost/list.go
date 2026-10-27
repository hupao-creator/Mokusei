package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/tools/verification/applicationhost/listfixture"
)

func verifyCollectionList(ctx context.Context) (err error) {
	root, err := os.MkdirTemp("", "mokusei-application-list-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, db.Close()) }()
	if _, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("settings", model.DefaultSettings(nil)) }); err != nil {
		return err
	}
	host, err := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{listfixture.Application{}}})
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, host.Stop(context.Background())) }()
	orderKey := "application:" + listfixture.CollectionID
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		for _, id := range []string{"b", "e", "c", "a", "d"} {
			record := model.VersionedRecord{ID: id, Revision: 1, CreatedAt: fixtureAt, UpdatedAt: fixtureAt, Value: json.RawMessage(`{}`)}
			if err := tx.Put(orderKey+":"+id, record); err != nil {
				return err
			}
		}
		return tx.SetOrder(orderKey, []string{"c", "absent", "a"})
	})
	if err != nil {
		return err
	}
	for _, fixture := range []struct {
		order []string
		want  []string
	}{
		{[]string{"c", "absent", "a"}, []string{"c", "a", "b", "d", "e"}},
		{[]string{"e", "d", "c", "b", "a"}, []string{"e", "d", "c", "b", "a"}},
		{[]string{}, []string{"a", "b", "c", "d", "e"}},
	} {
		if _, err = db.Update(ctx, func(tx *store.Tx) error { return tx.SetOrder(orderKey, fixture.order) }); err != nil {
			return err
		}
		got, err := listfixture.Query(ctx, host)
		if err != nil {
			return err
		}
		if !slices.Equal(got, fixture.want) {
			return fmt.Errorf("collection list order %v: got %v, want %v", fixture.order, got, fixture.want)
		}
	}
	return nil
}
