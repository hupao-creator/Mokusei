// Seed exclusively owned Overview replay data before the real app starts.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

type fixtureRow struct {
	ID       string   `json:"threadId"`
	Cwd      string   `json:"cwd"`
	Title    string   `json:"title"`
	Tags     []string `json:"tags"`
	Archived bool     `json:"archived"`
}

func main() {
	if err := seed(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func seed() error {
	if len(os.Args) != 3 || !filepath.IsAbs(os.Args[1]) || !filepath.IsAbs(os.Args[2]) {
		return errors.New("usage: overview-interaction /absolute/new/profile /absolute/fixture.json")
	}
	raw, err := os.ReadFile(os.Args[2])
	if err != nil {
		return err
	}
	var fixture struct {
		Rows []fixtureRow `json:"rows"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		return err
	}
	if len(fixture.Rows) < 1 || len(fixture.Rows) > 100 {
		return errors.New("fixture must contain 1–100 records")
	}
	seen := map[string]bool{}
	for _, row := range fixture.Rows {
		if row.ID == "" || seen[row.ID] || row.Title == "" || !filepath.IsAbs(row.Cwd) || len(row.Tags) == 0 {
			return errors.New("invalid fixture record")
		}
		seen[row.ID] = true
		info, err := os.Stat(row.Cwd)
		if err != nil || !info.IsDir() {
			return fmt.Errorf("fixture cwd is not an existing directory: %s", row.Cwd)
		}
	}
	// Exclusive mkdir is the ownership gate: never seed an existing user profile.
	root := os.Args[1]
	if err := os.Mkdir(root, 0700); err != nil {
		return err
	}
	db, err := store.Open(filepath.Join(root, "mokusei-go-state-v1", "state.sqlite"))
	if err != nil {
		return err
	}
	at := time.Now().UnixMilli()
	native, err := json.Marshal(codex.EmptyState(at))
	if err != nil {
		return errors.Join(err, db.Close())
	}
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		ids := make([]string, 0, len(fixture.Rows))
		for i, row := range fixture.Rows {
			emojis := map[string]string{}
			for _, tag := range row.Tags {
				emojis[tag] = "🔁"
			}
			record := model.ThreadRecord{SessionRecord: model.SessionRecord{
				ID: row.ID, HarnessID: "codex", SessionState: native, Settings: json.RawMessage(`{}`),
				Cwd: row.Cwd, CreatedAt: at + int64(i), UpdatedAt: at + int64(i),
			}, Title: row.Title, Archived: &row.Archived, Tags: row.Tags, TagEmojis: emojis}
			if err := tx.Put("thread:"+row.ID, record); err != nil {
				return err
			}
			ids = append(ids, row.ID)
		}
		return tx.SetOrder("threads", ids)
	})
	return errors.Join(err, db.Close())
}
