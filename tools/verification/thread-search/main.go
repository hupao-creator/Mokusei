// Integration replay of keyword retrieval through production Runtime and SQLite.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadattention"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
	"os"
	"path/filepath"
	"time"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func assert(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func raw(value any) json.RawMessage { b, e := json.Marshal(value); must(e); return b }
func wait(label string, predicate func() bool) {
	deadline := time.Now().Add(12 * time.Second)
	for !predicate() {
		if time.Now().After(deadline) {
			panic("timeout: " + label)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

type harness struct{ plugin.Harness }

func (harness) Descriptor() plugin.HarnessDescriptor     { return plugin.HarnessDescriptor{ID: "fixture"} }
func (harness) DefaultSettings() json.RawMessage         { return raw(map[string]any{}) }
func (harness) SessionState() plugin.SessionStateAdapter { return adapter{} }
func (harness) Settings() plugin.HarnessSettings         { return settings{} }
func (harness) Open(context.Context, plugin.OpenContext) (plugin.Handle, error) {
	return nil, errors.New("fixture must never launch native sessions")
}

type settings struct{ plugin.HarnessSettings }

func (settings) Normalize(v json.RawMessage) (json.RawMessage, error) { return v, nil }

type adapter struct{ plugin.SessionStateAdapter }

func (adapter) ProjectRenderer(v json.RawMessage, _ model.RendererScope) (json.RawMessage, error) {
	return v, nil
}
func (adapter) SearchText(v json.RawMessage) (string, error) {
	var data struct {
		Text string `json:"text"`
	}
	e := json.Unmarshal(v, &data)
	return data.Text, e
}
func (adapter) ReadContext(v json.RawMessage) (json.RawMessage, error) { return v, nil }
func (adapter) Project(v json.RawMessage) (model.PublicObservation, error) {
	return model.PublicObservation{}, nil
}

func thread(id, title, text string) model.ThreadRecord {
	return model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "fixture", Revision: 0, CreatedAt: 1, UpdatedAt: 1, Cwd: "/synthetic/项目", Settings: raw(map[string]any{}), SessionState: raw(map[string]any{"text": text, "private": "NEVER_UPLOAD"})}, Title: title, Tags: []string{"Maintenance"}, TagEmojis: map[string]string{"Maintenance": "🔧"}}
}
func seed(s *store.Store, threads ...model.ThreadRecord) {
	_, e := s.Update(context.Background(), func(tx *store.Tx) error {
		ids := tx.Order("threads")
		for _, t := range threads {
			if !tx.Has("thread:" + t.ID) {
				ids = append(ids, t.ID)
			}
			if e := tx.Put("thread:"+t.ID, t); e != nil {
				return e
			}
		}
		return tx.SetOrder("threads", ids)
	})
	must(e)
}
func invoke(r *core.Runtime, channel string, input ...any) any {
	args := []json.RawMessage{}
	for _, v := range input {
		args = append(args, raw(v))
	}
	out, e := r.Invoke(context.Background(), channel, args)
	must(e)
	return out
}
func status(r *core.Runtime) threadsearch.Status {
	return invoke(r, "search:status").(threadsearch.Status)
}
func start(r *core.Runtime) {
	wait("automatic keyword index", func() bool { s := status(r); return !s.Working && s.PendingDocuments == 0 })
}
func query(r *core.Runtime, text string, refs ...model.ThreadRef) threadsearch.QueryResult {
	return invoke(r, "search:query", threadsearch.QueryRequest{Query: text, Threads: refs}).(threadsearch.QueryResult)
}
func refs(ids ...string) []model.ThreadRef {
	out := []model.ThreadRef{}
	for _, id := range ids {
		out = append(out, model.ThreadRef{ThreadID: id, TypeID: "agent"})
	}
	return out
}

func main() {
	ctx := context.Background()
	verifyTextAdapters()
	directory, err := os.MkdirTemp("", "mokusei-keyword-search-")
	must(err)
	defer os.RemoveAll(directory)
	assetPath := filepath.Join(directory, "search-models", "retired-model")
	must(os.MkdirAll(filepath.Dir(assetPath), 0700))
	must(os.WriteFile(assetPath, []byte("existing asset"), 0600))
	path := filepath.Join(directory, "state.sqlite")
	db, err := store.Open(path)
	must(err)
	defer func() { db.Close() }()
	seed(db, thread("body", "Maintenance", "离线删除与后台清理"), thread("literal", "exact-ID-42", "different subject"))
	sourceHash, _ := db.Snapshot().RecordHash("thread:body")
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("search-config", map[string]any{"pipeline": "retired-vector-space", "revision": 7, "epoch": 2, "enabled": false, "indexPaused": true}); err != nil {
			return err
		}
		if err := tx.Put("search-usage", map[string]int{"requests": 200}); err != nil {
			return err
		}
		return tx.Put("search-document:old", map[string]any{"vector": []int{1, 2}})
	})
	must(err)
	openRuntime := func() *core.Runtime {
		r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory, DefaultCwd: directory})
		must(err)
		return r
	}
	r := openRuntime()
	migratedHash, _ := db.Snapshot().RecordHash("thread:body")
	assert(sourceHash == migratedHash && !db.Snapshot().Has("search-usage") && !db.Snapshot().Has("search-document:old"), "migration preserves source and removes only derived records")
	assert(status(r).Config.Revision == 8, "legacy configuration advances revision")
	for _, channel := range []string{"search:model", "search:index", "search:configure"} {
		_, err := r.Invoke(ctx, channel, []json.RawMessage{raw(map[string]any{})})
		assert(err != nil, "retired operation must be rejected: "+channel)
	}
	start(r)
	result := query(r, "离线删除", refs("body", "literal")...)
	assert(result.Mode == "keyword" && len(result.Hits) == 1 && result.Hits[0].Ref.ThreadID == "body", "Chinese body substring")
	assert(len(query(r, "清空历史", refs("body")...).Hits) == 0, "no paraphrase-only results")
	assert(len(query(r, "离线删除", refs("literal")...).Hits) == 0, "candidate scope")
	assert(len(query(r, "离线删除 后台", refs("body")...).Hits) == 1, "body AND terms")
	assert(query(r, "exact-ID-42", refs("body", "literal")...).Hits[0].Ref.ThreadID == "literal", "identifier match")
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("attention-thread:body", threadattention.Thread{Hidden: true, Revision: 1}); err != nil {
			return err
		}
		return tx.Put("attention-hidden:body", true)
	})
	must(err)
	assert(len(query(r, "离线删除", refs("body")...).Hits) == 1 && db.Snapshot().Has("attention-hidden:body"), "collapsed card remains hidden and body-indexed on search hit")
	invoke(r, "thread:record-visit", model.Object{"threadId": "body", "visitId": "aa000000-0000-4000-8000-000000000001", "elapsed": 0, "foreground": true, "completedExecution": "", "alreadyVisible": false, "searchOpen": true})
	assert(!db.Snapshot().Has("attention-hidden:body"), "opening the search hit restores the ordinary card")
	must(r.SetArchived(ctx, "body", true))
	assert(len(query(r, "离线删除", refs("body")...).Hits) == 0, "archive immediately excludes body")
	must(r.SetArchived(ctx, "body", false))
	seed(db, thread("body", "Maintenance", "更新后的关键词"))
	start(r)
	assert(len(query(r, "更新后的", refs("body")...).Hits) == 1 && len(query(r, "离线删除", refs("body")...).Hits) == 0, "changed body replaces old index and cached result")
	must(r.Close(ctx))
	must(db.Close())
	db, err = store.Open(path)
	must(err)
	r = openRuntime()
	defer r.Close(ctx)
	assert(len(query(r, "更新后的", refs("body")...).Hits) == 1, "keyword index survives reopen")
	must(r.ClearHistory(ctx))
	assert(len(db.Snapshot().Keys("search-document:")) == 0 && len(query(r, "更新后的", refs("body")...).Hits) == 0, "history clear removes derived text and cached hits")
	asset, err := os.ReadFile(assetPath)
	must(err)
	assert(string(asset) == "existing asset", "existing model files remain untouched")
	verifyMaintenanceFanout(ctx, directory)
	verifyApplications(ctx, directory)
	verifyDiagnostics(ctx, filepath.Join(directory, "diagnostics"))
	fmt.Println("PASS keyword Runtime/SQLite: legacy migration, source preservation, retired APIs, Chinese body/AND/scope, archive, updates, reopen, history clear and application/Report text")
}
