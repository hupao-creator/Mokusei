package main

import (
	"context"
	"errors"
	"fmt"
	"reflect"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
)

func (h *harness) verifyDirectoryTags(ctx context.Context, reportID string) error {
	ref := model.ThreadRef{ThreadID: "verification-directory-source", TypeID: "agent"}
	key := "application:" + report.CollectionID + ":" + reportID
	for _, scenario := range []struct {
		cwd       string
		directory []string
	}{
		{"/Users/fixture/.Mokusei/profiles/example/runtime-workspace/tmp-workspaces/thread-345832012", []string{}},
		{"/Users/fixture/.Mokusei/profiles/example/runtime-workspace/tmp-workspaces/thread-2061260304", []string{}},
		{"/Users/fixture/.Mokusei-headless/tmp-workspaces/thread-example/project", []string{}},
		{`C:\Users\fixture\AppData\Local\Temp\mokusei-example\project`, []string{}},
		{"/Users/fixture/Projects/thread-345832012", []string{"thread-345832012"}},
	} {
		var original model.VersionedRecord
		if _, err := h.store.Snapshot().Get(key, &original); err != nil {
			return err
		}
		value, err := report.ParseData(original.Value)
		if err != nil {
			return err
		}
		value.RelatedExecutions = []model.ExecutionRef{{Thread: ref, ExecutionID: "verification-completed"}}
		value.TagSources = map[string]report.TagSource{ref.ThreadID: {TagEmojis: map[string]string{"Keep": "👩🏽‍💻"}, SemanticTags: []string{"Keep"}, DirectoryTags: []string{"stale-directory-tag"}}}
		original.Value = encode(value)
		original.Revision++
		_, err = h.store.Update(ctx, func(tx *store.Tx) error {
			source := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: ref.ThreadID, Cwd: scenario.cwd, SessionState: encode(nil), Settings: encode(map[string]any{})}, Tags: []string{"Keep"}, TagEmojis: map[string]string{"Keep": "👩🏽‍💻"}}
			if err := tx.Put("thread:"+ref.ThreadID, source); err != nil {
				return err
			}
			return tx.Put(key, original)
		})
		if err != nil {
			return err
		}
		expected := model.TagProjection{Tags: append([]string{"Keep"}, scenario.directory...), TagEmojis: map[string]string{"Keep": "👩🏽‍💻"}, SemanticTags: []string{"Keep"}, DirectoryTags: scenario.directory}
		access := h.runtime.SnapshotCapabilities(h.store.Snapshot(), nil)
		tags, err := plugin.Require[plugin.SemanticTagsSnapshotCapability](access, plugin.SemanticTagsSnapshotCapabilityKey)
		if err != nil {
			return err
		}
		projected, err := tags.ReadThreadTags(ref)
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(projected, expected) {
			return fmt.Errorf("ordinary task tags for %q: got %+v, expected %+v", scenario.cwd, projected, expected)
		}
		if err = h.runtime.RefreshApplicationDirectoryTags(ctx); err != nil {
			return err
		}
		catalog, err := h.host.Catalog(ctx)
		if err != nil {
			return err
		}
		found := false
		for _, entry := range catalog {
			if entry.ID == reportID {
				found = true
				// This Inbox report keeps its own scope even if source metadata changes.
				expected.Tags = []string{"Keep"}
				expected.DirectoryTags = []string{}
				if !reflect.DeepEqual(entry.Tags, expected) {
					return fmt.Errorf("Report inherited incorrect directory tags for %q: %+v", scenario.cwd, entry.Tags)
				}
			}
		}
		if !found {
			return errors.New("directory refresh lost the Report")
		}
		var refreshed model.VersionedRecord
		if _, err = h.store.Snapshot().Get(key, &refreshed); err != nil {
			return err
		}
		updated, err := report.ParseData(refreshed.Value)
		if err != nil {
			return err
		}
		if updated.Title != value.Title || updated.HTML != value.HTML || updated.ContentRevision != value.ContentRevision || updated.Archived != value.Archived || refreshed.UpdatedAt != original.UpdatedAt {
			return errors.New("directory refresh changed Report content, archive state or visible timestamp")
		}
		if err = h.runtime.RefreshApplicationDirectoryTags(ctx); err != nil {
			return err
		}
		var repeated model.VersionedRecord
		if _, err = h.store.Snapshot().Get(key, &repeated); err != nil {
			return err
		}
		if !reflect.DeepEqual(repeated, refreshed) {
			return errors.New("repeated directory refresh rewrote an unchanged Report")
		}
	}
	// Persist one stale label again so the ordinary close/reopen replay must
	// repair it through startup, with the Tag application still disabled.
	_, err := h.store.Update(ctx, func(tx *store.Tx) error {
		var source model.ThreadRecord
		if _, err := tx.Get("thread:"+ref.ThreadID, &source); err != nil {
			return err
		}
		source.Cwd = "/Users/fixture/.Mokusei/profiles/example/runtime-workspace/tmp-workspaces/thread-345832012"
		return tx.Put("thread:"+ref.ThreadID, source)
	})
	if err != nil {
		return err
	}
	h.checks = append(h.checks, "temporary source paths hidden from task and Report tags; same-named ordinary project retained", "existing Report directory tags refreshed with Tag disabled; semantic names, content, archive and timestamps preserved", "repeated directory refresh leaves record revisions unchanged")
	return nil
}
