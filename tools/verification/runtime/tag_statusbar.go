package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/tag"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

func readTagStatus(ctx context.Context, h *handle) plugin.TagStatusbar {
	value, err := reportTool(ctx, h, "read_statusbar", "status", model.Object{})
	must(err)
	var status plugin.TagStatusbar
	must(json.Unmarshal(value, &status))
	return status
}
func mutateTagTool(ctx context.Context, h *handle, tool, callID string, args model.Object) plugin.TagStatusbar {
	value, err := reportTool(ctx, h, tool, callID, args)
	must(err)
	var result plugin.TagMutationResult
	must(json.Unmarshal(value, &result))
	if result.Status != "applied" {
		panic("tag mutation did not apply: " + string(value))
	}
	return result.Statusbar
}
func tagStatusID(status plugin.TagStatusbar, name string) string {
	for _, tag := range status.Tags {
		if tag.Name == name {
			return tag.ID
		}
	}
	panic("missing tag " + name)
}
func injectedTagStatus(sent backgroundSettingsSend) plugin.TagStatusbar {
	text := sent.input.Parts[0].Text
	_, data, found := strings.Cut(text, "\nStatusbar: ")
	if !found {
		panic("missing injected statusbar: " + text)
	}
	var status plugin.TagStatusbar
	must(json.Unmarshal([]byte(data), &status))
	if strings.Contains(text, "PRIVATE_") {
		panic("Tag received private task evidence")
	}
	var object map[string]json.RawMessage
	must(json.Unmarshal([]byte(data), &object))
	var threads []map[string]json.RawMessage
	must(json.Unmarshal(object["threads"], &threads))
	for _, thread := range threads {
		if len(thread) != 2 || thread["id"] == nil || thread["title"] == nil {
			panic("Tag thread evidence is not ID/title only")
		}
	}
	return status
}

// Exercise the production participant and its actual injected callbacks against
// SQLite. Fixtures author task state; classification and all mutation/CAS logic
// run in the shipped Runtime and plugin.
func verifyTagStatusbar(ctx context.Context) {
	root, err := os.MkdirTemp("", "mokusei-tag-statusbar-")
	must(err)
	defer os.RemoveAll(root)
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	must(err)
	h := &backgroundSettingsHarness{sends: make(chan backgroundSettingsSend, 32)}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": h}, DataDir: root, DefaultCwd: root})
	must(err)
	defer func() { must(r.Close(ctx)); must(db.Close()) }()
	app, err := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{tag.New()}, RuntimeCapabilities: r.RuntimeCapabilities, BackgroundCapabilities: r.BackgroundCapabilities, SnapshotCapabilities: r.SnapshotCapabilities, DirectoryScopes: r.DirectoryScopes})
	must(err)
	r.SetApplications(app)
	_, err = r.EnsureExecutionSettings(ctx, "fixture", "")
	must(err)
	create := func(title string) string {
		created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: root, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "PRIVATE_REQUEST_" + title}}}})
		must(err)
		must(r.UpdateThread(ctx, created.Record.ID, func(t *model.ThreadRecord) error { t.Title = title; return nil }))
		return created.Record.ID
	}
	a, b, arch := create("Build frontend"), create("Repair runtime"), create("Archived task title")
	scope := directorytag.Scope(root)
	_, writes := scopedTagCapabilities(r, scope, "tag.fixture-setup")
	_, err = writes.Execute(ctx, plugin.SemanticTagOperation{Kind: "create", Name: "History", Emoji: stringPointer("📚")}, plugin.BackgroundWriteOptions{RequestID: "history"})
	must(err)
	_, err = writes.Execute(ctx, plugin.SemanticTagOperation{Kind: "assign", Thread: &model.ThreadRef{ThreadID: arch, TypeID: "agent"}, Tags: []string{"History"}}, plugin.BackgroundWriteOptions{RequestID: "historical-assignment"})
	must(err)
	must(r.SetArchived(ctx, arch, true))
	// A foreign record is present in authoritative storage, without opening a
	// foreign participant that would add independent fixture sends.
	foreign, err := r.Thread(a)
	must(err)
	foreign.ID = "foreign-thread"
	foreign.Cwd = "/foreign-tag-status-scope"
	foreign.Title = "PRIVATE_FOREIGN_TITLE"
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("thread:"+foreign.ID, foreign) })
	must(err)
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	await := func() backgroundSettingsSend {
		select {
		case sent := <-h.sends:
			return sent
		case <-time.After(4 * time.Second):
			panic("Tag did not wake")
		}
	}
	first := await()
	status := injectedTagStatus(first)
	if len(status.Threads) != 2 || len(status.UnassignedThreadIDs) != 2 || status.Capacity != 5 || status.Pool != scope {
		panic("incomplete or unscoped statusbar")
	}
	if !reflect.DeepEqual(status, readTagStatus(ctx, first.handle)) {
		panic("injection and read disagree without a classification change")
	}
	names := []string{}
	for _, tool := range first.handle.open.Injection.Tools.Bindings {
		names = append(names, tool.Name)
	}
	sort.Strings(names)
	if !reflect.DeepEqual(names, []string{"assign_threads", "create_tag", "delete_tag", "read_statusbar", "update_tag"}) {
		panic(fmt.Sprint("unexpected Tag authority: ", names))
	}
	mutate := func(tool, id string, args model.Object) {
		args["expectedRevision"] = status.Revision
		status = mutateTagTool(ctx, first.handle, tool, id, args)
	}
	mutate("create_tag", "build", model.Object{"name": "Build", "emoji": "🔧"})
	build := tagStatusID(status, "Build")
	mutate("create_tag", "runtime", model.Object{"name": "Runtime", "emoji": "⚙️"})
	runtimeTag := tagStatusID(status, "Runtime")
	before := status
	_, err = reportTool(ctx, first.handle, "assign_threads", "cross-scope", model.Object{"expectedRevision": status.Revision, "assignments": []plugin.TagStatusAssignment{{ThreadID: a, TagID: build}, {ThreadID: foreign.ID, TagID: runtimeTag}}})
	if err == nil {
		panic("cross-scope assignment accepted")
	}
	if !reflect.DeepEqual(before, readTagStatus(ctx, first.handle)) {
		panic("invalid batch partially applied")
	}
	mutate("assign_threads", "assign", model.Object{"assignments": []plugin.TagStatusAssignment{{ThreadID: a, TagID: build}, {ThreadID: b, TagID: runtimeTag}}})
	if len(status.UnassignedThreadIDs) != 0 || len(status.Assignments) != 2 {
		panic("batch did not cover active pool")
	}
	mutate("update_tag", "rename", model.Object{"tagId": build, "name": "Frontend"})
	if tagStatusID(status, "Frontend") != build {
		panic("rename changed stable identity")
	}
	assertThreadTags(r, a, "Frontend")
	_, err = reportTool(ctx, first.handle, "delete_tag", "delete-used", model.Object{"expectedRevision": status.Revision, "tagId": build})
	if err == nil {
		panic("deleted nonempty tag")
	}
	history := tagStatusID(status, "History")
	mutate("update_tag", "rename-history", model.Object{"tagId": history, "name": "Vacant", "emoji": "🧭"})
	assertThreadTags(r, arch, "History")
	assertTagEmoji(r, arch, "History", "📚")
	mutate("delete_tag", "delete-history", model.Object{"tagId": history})
	assertThreadTags(r, arch, "History")
	_, err = reportTool(ctx, first.handle, "assign_threads", "archived-assignment", model.Object{"expectedRevision": status.Revision, "assignments": []plugin.TagStatusAssignment{{ThreadID: arch, TagID: build}}})
	if err == nil {
		panic("archived assignment accepted")
	}
	for _, name := range []string{"Three", "Four", "Five"} {
		mutate("create_tag", name, model.Object{"name": name, "emoji": "🏷️"})
	}
	_, err = reportTool(ctx, first.handle, "create_tag", "overflow", model.Object{"expectedRevision": status.Revision, "name": "Six", "emoji": "🏷️"})
	if err == nil {
		panic("sixth tag accepted")
	}
	// Reorganize a full pool using only primitive production tools.
	mutate("assign_threads", "combine", model.Object{"assignments": []plugin.TagStatusAssignment{{ThreadID: b, TagID: build}}})
	mutate("delete_tag", "free-slot", model.Object{"tagId": runtimeTag})
	mutate("create_tag", "replacement", model.Object{"name": "Services", "emoji": "🛠️"})
	mutate("assign_threads", "redistribute", model.Object{"assignments": []plugin.TagStatusAssignment{{ThreadID: b, TagID: tagStatusID(status, "Services")}}})
	if len(status.Tags) != 5 || len(status.UnassignedThreadIDs) != 0 {
		panic("full pool reorganization lost coverage")
	}
	// An execution-only commit must not stale a title-based classification.
	finishReportFixture(ctx, h.latest(a), "completed")
	if readTagStatus(ctx, first.handle).Revision != status.Revision {
		panic("terminal execution invalidated classification revision")
	}
	stale := status.Revision
	must(r.UpdateThread(ctx, b, func(t *model.ThreadRecord) error { t.Title = "Repair service authentication"; return nil }))
	steered := await()
	newStatus := injectedTagStatus(steered)
	if steered.execution != first.execution || newStatus.Revision == stale {
		panic("title change did not steer with fresh status")
	}
	value, err := reportTool(ctx, first.handle, "update_tag", "stale-write", model.Object{"expectedRevision": stale, "tagId": build, "name": "Incorrect"})
	must(err)
	var conflict plugin.TagMutationResult
	must(json.Unmarshal(value, &conflict))
	if conflict.Status != "conflict" || conflict.Statusbar.Revision != newStatus.Revision || tagStatusID(conflict.Statusbar, "Frontend") != build {
		panic("stale write changed state or omitted fresh snapshot")
	}
	status = conflict.Statusbar
	// Restoring drops frozen decoration and wakes the current pool for review.
	must(r.SetArchived(ctx, arch, false))
	restored := await()
	status = injectedTagStatus(restored)
	if len(status.Threads) != 3 || len(status.UnassignedThreadIDs) != 1 || status.UnassignedThreadIDs[0] != arch {
		panic("restored Thread did not return unassigned")
	}
	// The formerly archived title is now allowed evidence.
	mutate("assign_threads", "restore-assignment", model.Object{"assignments": []plugin.TagStatusAssignment{{ThreadID: arch, TagID: build}}})
	finishReportFixture(ctx, first.handle, "completed")
	waitFor(func() bool { first.handle.mu.Lock(); defer first.handle.mu.Unlock(); return first.handle.closed })
	// At idle, terminal execution facts remain non-waking.
	finishReportFixture(ctx, h.latest(b), "failed")
	finishReportFixture(ctx, h.latest(arch), "interrupted")
	select {
	case <-h.sends:
		panic("terminal execution woke Tag")
	case <-time.After(150 * time.Millisecond):
	}
	must(r.UpdateThread(ctx, a, func(t *model.ThreadRecord) error { t.Title = "Frontend accessibility"; return nil }))
	next := await()
	fresh := injectedTagStatus(next)
	if next.execution == first.execution || fresh.Revision == status.Revision {
		panic("idle title update did not open a fresh batch")
	}
	finishReportFixture(ctx, next.handle, "completed")
	fmt.Println("PASS Tag statusbar: title-only full pool, primitive tools, stable IDs, atomic scope validation, revision CAS, five-slot reorganization, archive freeze/restore and title-only steering/idle wake")
}
