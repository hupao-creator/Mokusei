package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

func TestTagEmojiWriteContractAndAtomicFailure(t *testing.T) {
	root := t.TempDir()
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r, err := New(t.Context(), Config{Store: db, DataDir: root, DefaultCwd: root})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	_, err = db.Update(t.Context(), func(tx *store.Tx) error {
		return tx.Put("thread:current", model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "current", CreatedAt: 1, UpdatedAt: 1}, Title: "Thread title 🔥", Tags: []string{}, TagEmojis: map[string]string{}})
	})
	if err != nil {
		t.Fatal(err)
	}
	writes := tagsWriteCapability{runtime: r, source: "tag.agent.test", scope: directorytag.InboxScope}
	icon := "👩🏽‍💻"
	ref := model.ThreadRef{ThreadID: "current", TypeID: "agent"}
	run := func(op plugin.SemanticTagOperation, id string) {
		t.Helper()
		if _, err := writes.Execute(t.Context(), op, plugin.BackgroundWriteOptions{RequestID: id}); err != nil {
			t.Fatal(err)
		}
	}
	run(plugin.SemanticTagOperation{Kind: "create-many", Definitions: []plugin.SemanticTagInput{{Name: "Backend", Emoji: icon}, {Name: "Other", Emoji: "🧭"}}}, "create")
	run(plugin.SemanticTagOperation{Kind: "assign", Thread: &ref, Tags: []string{"Backend"}}, "assign")
	invalid := []plugin.SemanticTagOperation{
		{Kind: "create-many", Names: []string{"Old protocol"}},
		{Kind: "create", Name: "Missing"},
		{Kind: "create-many", Definitions: []plugin.SemanticTagInput{{Name: "Valid", Emoji: icon}, {Name: "Missing"}}},
		{Kind: "create", Name: "🔥 Backend", Emoji: &icon},
		{Kind: "update", Name: "Backend", NewName: "🔥 Backend"},
		{Kind: "update", Name: "Backend", Emoji: new(string)},
		{Kind: "merge", Names: []string{"Other"}, Target: "Backend"},
		{Kind: "merge", Names: []string{"Other"}, Target: "🔥 Backend", Emoji: &icon},
		{Kind: "assign", Thread: &ref, Tags: []string{"🔥 Backend"}},
	}
	for i, op := range invalid {
		before := db.Snapshot().Revision()
		if _, err := writes.Execute(t.Context(), op, plugin.BackgroundWriteOptions{RequestID: fmt.Sprintf("invalid-%d", i)}); err == nil {
			t.Fatalf("accepted invalid operation: %+v", op)
		}
		if db.Snapshot().Revision() != before {
			t.Fatalf("failed operation committed: %+v", op)
		}
	}
	// Duplicate create and ordinary rename preserve an existing icon under the
	// current text-only identity contract; icon-only updates publish a revision.
	run(plugin.SemanticTagOperation{Kind: "create-many", Definitions: []plugin.SemanticTagInput{{Name: " ＢＡＣＫＥＮＤ ", Emoji: "🔧"}}}, "duplicate")
	run(plugin.SemanticTagOperation{Kind: "update", Name: "Backend", NewName: "Services"}, "rename")
	thread, err := r.Thread("current")
	if err != nil {
		t.Fatal(err)
	}
	if thread.Title != "Thread title 🔥" || thread.Tags[0] != "Services" || thread.TagEmojis["Services"] != icon {
		t.Fatalf("text identity or decoration changed: %+v", thread)
	}
	bad := "👩‍"
	run(plugin.SemanticTagOperation{Kind: "update", Name: "Services", Emoji: &bad}, "invalid-generated-emoji")
	next, err := r.Thread("current")
	if err != nil {
		t.Fatal(err)
	}
	if next.TagEmojis["Services"] != "🏷️" || next.Revision <= thread.Revision {
		t.Fatalf("generated invalid emoji not normalized and published: %+v", next)
	}
	if err := writes.EnsureInventory(t.Context()); err != nil {
		t.Fatal(err)
	}
	before := db.Snapshot().Revision()
	if err := writes.EnsureInventory(t.Context()); err != nil {
		t.Fatal(err)
	}
	if db.Snapshot().Revision() != before {
		t.Fatal("inventory initialization rewrote persisted data")
	}
}

func TestStoredTagsAreRejectedWithoutRepair(t *testing.T) {
	for _, tag := range []tagDefinition{
		{Name: "Backend", Description: "Backend"},
		{Name: "🔥 Backend", Description: "Backend", Emoji: "🔥"},
		{Name: "Backend", Description: "Backend", Emoji: "👩‍"},
	} {
		db, err := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		_, err = db.Update(t.Context(), func(tx *store.Tx) error {
			if err := tx.Put(tagInventoryKey(directorytag.InboxScope), true); err != nil {
				return err
			}
			return tx.Put(tagPoolKey(directorytag.InboxScope), []tagDefinition{tag})
		})
		if err != nil {
			t.Fatal(err)
		}
		r, err := New(t.Context(), Config{Store: db, DataDir: t.TempDir()})
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close(context.Background())
		before := db.Snapshot().Revision()
		writes := tagsWriteCapability{runtime: r, scope: directorytag.InboxScope}
		if err := writes.EnsureInventory(t.Context()); err != nil {
			t.Fatal(err)
		}
		if _, _, err := readTags(db.Snapshot(), directorytag.InboxScope); err == nil {
			t.Fatalf("accepted invalid stored definition: %+v", tag)
		}
		var actual []tagDefinition
		if _, err := db.Snapshot().Get(tagPoolKey(directorytag.InboxScope), &actual); err != nil {
			t.Fatal(err)
		}
		want, _ := json.Marshal([]tagDefinition{tag})
		got, _ := json.Marshal(actual)
		if string(got) != string(want) || db.Snapshot().Revision() != before {
			t.Fatal("read repaired stored definitions")
		}
	}
}
