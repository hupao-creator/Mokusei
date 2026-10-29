package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

// The production Report participant drives real private sessions and tools.
// Only the native model is controlled: sends stay running until this replay
// commits a terminal observation through the Harness's actual SessionStore.
type reportScopeHarness struct {
	harness
	mu      sync.Mutex
	handles []*handle
}

func (f *reportScopeHarness) Open(_ context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	h := &handle{open: open}
	f.mu.Lock()
	f.handles = append(f.handles, h)
	f.mu.Unlock()
	return h, nil
}
func (f *reportScopeHarness) latest(key string) *handle {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.handles) - 1; i >= 0; i-- {
		h := f.handles[i]
		if h.open.ThreadID == key || filepath.Base(h.open.ReadThread().Cwd) == key {
			return h
		}
	}
	return nil
}
func (f *reportScopeHarness) reportCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	count := 0
	for _, h := range f.handles {
		if strings.Contains(h.open.ReadThread().Cwd, "/plugins/report/") {
			count++
		}
	}
	return count
}
func finishReportFixture(ctx context.Context, h *handle, status string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	var s state
	must(json.Unmarshal(h.open.SessionState.Read(), &s))
	s.Observation.LatestExecution.Status = status
	finished := max(time.Now().UnixMilli(), s.Observation.LatestExecution.StartedAt)
	s.Observation.LatestExecution.FinishedAt = &finished
	must(h.open.SessionState.Commit(ctx, raw(s)))
}
func reportTool(ctx context.Context, h *handle, name, callID string, args model.Object) (json.RawMessage, error) {
	for _, tool := range h.open.Injection.Tools.Bindings {
		if tool.Name == name {
			return tool.Execute(ctx, plugin.ToolCall{CallID: callID, Arguments: raw(args)})
		}
	}
	panic("missing Report tool: " + name)
}
func reportPage(ctx context.Context, h *handle, name string, args model.Object) string {
	value, err := reportTool(ctx, h, name, "read", args)
	must(err)
	var page struct {
		Text string `json:"text"`
	}
	must(json.Unmarshal(value, &page))
	if page.Text == "" {
		panic("missing evidence page: " + string(value))
	}
	return page.Text
}
func expectReportDenied(err error, label string) {
	if err == nil {
		panic("Report accepted " + label)
	}
}

func verifyReportGuidance(h *handle) {
	// Hash the actual injected entry, including front matter and trailing newline,
	// against the pinned upstream bytes rather than duplicating the skill here.
	found := false
	guidance := strings.Join(h.open.Injection.Instructions, "\n")
	for _, instruction := range h.open.Injection.Instructions {
		if fmt.Sprintf("%x", sha256.Sum256([]byte(instruction))) == "3bb95cd13852051c5a1862e8b94da1de7cfba7415d418ab0ca4d762527d1b9a5" {
			found = true
		}
	}
	if !found {
		panic("Report session lacks the verbatim upstream ELI5 skill")
	}
	for _, tool := range h.open.Injection.Tools.Bindings {
		guidance += "\n" + tool.Description + "\n" + string(tool.InputSchema)
	}
	var s state
	must(json.Unmarshal(h.open.SessionState.Read(), &s))
	guidance += "\n" + strings.Join(s.Messages, "\n")
	for _, removed := range []string{"ASD-STE100", "3Blue1Brown", "current application output language", "Current application output language", "Do not assume every reader is a beginner"} {
		if strings.Contains(guidance, removed) {
			panic("Report retained removed writing guidance: " + removed)
		}
	}
}

func verifyReportScopes(ctx context.Context) {
	data, err := os.MkdirTemp("", "mokusei-report-replay-")
	must(err)
	defer os.RemoveAll(data)
	projects, err := os.MkdirTemp("/tmp", "scoped-reports-")
	must(err)
	defer os.RemoveAll(projects)
	aDir, bDir := filepath.Join(projects, "one", "Project"), filepath.Join(projects, "two", "Project")
	must(os.MkdirAll(aDir, 0o700))
	must(os.MkdirAll(bDir, 0o700))
	aScope, bScope := directorytag.Scope(aDir), directorytag.Scope(bDir)
	db, err := store.Open(filepath.Join(data, "state.sqlite"))
	must(err)
	f := &reportScopeHarness{}
	var r *core.Runtime
	var app *applicationhost.Host
	open := func() {
		manager := workspaces.New(workspaces.Paths{DefaultCwd: data, TemporaryRoot: filepath.Join(data, "tmp-workspaces"), RegistryPath: filepath.Join(data, "worktrees.json")})
		r, err = core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": f}, DataDir: data, DefaultCwd: data, Workspaces: manager, Log: func(kind string, err error) { fmt.Println("report replay", kind, err) }})
		must(err)
		app, err = applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{report.New()}, RuntimeCapabilities: r.RuntimeCapabilities, BackgroundCapabilities: r.BackgroundCapabilities, SnapshotCapabilities: r.SnapshotCapabilities, ArchiveExecutions: r.ArchiveExecutions, DirectoryScopes: r.DirectoryScopes})
		must(err)
		r.SetApplications(app)
	}
	open()
	defer func() { must(r.Close(ctx)); must(db.Close()) }()
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	createTask := func(cwd string) model.ThreadRecord {
		created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: cwd, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "scope evidence"}}}})
		must(err)
		return created.Record
	}
	a, b := createTask(aDir), createTask(bDir)
	inbox := createTask("")
	finishReportFixture(ctx, f.latest(inbox.ID), "failed")
	// None of accepted input, running or failure may acquire a Report model.
	time.Sleep(150 * time.Millisecond)
	if f.reportCount() != 0 {
		panic("idle/excluded events opened a Report session")
	}
	owners := map[string]plugin.BackgroundAgentRef{}
	for _, owner := range app.BackgroundInstances() {
		owners[owner.Binding.Scope] = owner
	}
	if len(owners) != 3 || owners[aScope].AgentID == owners[bScope].AgentID {
		panic("scope discovery conflated same-named directories")
	}
	// The declared scope wrapper must retain host drain visibility. Pending
	// completions remain unadmitted, then resume promptly without retry backoff.
	must(r.SetServiceDraining(true))
	finishReportFixture(ctx, f.latest(a.ID), "completed")
	finishReportFixture(ctx, f.latest(b.ID), "completed")
	time.Sleep(200 * time.Millisecond)
	if f.reportCount() != 0 {
		panic("draining host started a scoped Report execution")
	}
	for _, scope := range []string{aScope, bScope} {
		_, exists, err := db.Snapshot().Work(owners[scope].AgentID + ".events")
		must(err)
		if exists {
			panic("draining host admitted a scoped Report batch")
		}
	}
	must(r.SetServiceDraining(false))
	active := func(scope string, count int) store.Work {
		var work store.Work
		waitFor(func() bool {
			var exists bool
			work, exists, err = db.Snapshot().Work(owners[scope].AgentID + ".events")
			must(err)
			h := f.latest(owners[scope].AgentID)
			if !exists || work.ExecutionID == "" || len(work.EventIDs) != count || h == nil {
				return false
			}
			h.mu.Lock()
			closed := h.closed
			h.mu.Unlock()
			observation := h.open.ReadThread().Observation
			return !closed && observation.LatestExecution != nil && observation.LatestExecution.ExecutionID == work.ExecutionID && observation.LatestExecution.Status == "running"
		})
		return work
	}
	aWork, bWork := active(aScope, 1), active(bScope, 1)
	aHandle, bHandle := f.latest(owners[aScope].AgentID), f.latest(owners[bScope].AgentID)
	verifyReportGuidance(aHandle)
	verifyReportGuidance(bHandle)
	if aHandle.open.ThreadID == bHandle.open.ThreadID || aWork.ID == bWork.ID {
		panic("Report scopes share session or batch identity")
	}
	a2 := createTask(aDir)
	finishReportFixture(ctx, f.latest(a2.ID), "completed")
	steered := active(aScope, 2)
	waitFor(func() bool {
		var s state
		must(json.Unmarshal(aHandle.open.SessionState.Read(), &s))
		return strings.Contains(strings.Join(s.Messages, "\n"), a2.ID)
	})
	verifyReportGuidance(aHandle)
	if steered.ID != aWork.ID || steered.ExecutionID != aWork.ExecutionID {
		panic("same-scope event did not steer the active Report execution")
	}
	if current, _, err := db.Snapshot().Work(owners[bScope].AgentID + ".events"); err != nil || len(current.EventIDs) != 1 {
		panic("Report steering crossed scopes")
	}
	for _, entry := range []struct {
		scope string
		h     *handle
		own   model.ThreadRecord
		other model.ThreadRecord
	}{{aScope, aHandle, a, b}, {bScope, bHandle, b, a}} {
		list := reportPage(ctx, entry.h, "list_threads", model.Object{})
		if !strings.Contains(list, entry.own.ID) || strings.Contains(list, entry.other.ID) || strings.Contains(list, inbox.ID) {
			panic("Report list_threads leaked another scope")
		}
		for _, tool := range []string{"get_thread_status", "read_thread"} {
			args := model.Object{"threadId": entry.other.ID}
			if tool == "read_thread" {
				args["question"] = "evidence"
			}
			_, err := reportTool(ctx, entry.h, tool, "foreign-task", args)
			expectReportDenied(err, "foreign "+tool)
		}
		caps := r.BackgroundCapabilities(owners[entry.scope], report.SettingsID)
		tasks, err := plugin.Require[plugin.OrdinaryTaskReadCapability](caps, plugin.OrdinaryTaskReadCapabilityKey)
		must(err)
		ref := model.ThreadRef{ThreadID: entry.other.ID, TypeID: "agent"}
		_, err = tasks.CaptureHistory(ctx, ref)
		expectReportDenied(err, "foreign history")
		execution, err := tasks.ResolveExecution(ctx, model.ExecutionRef{Thread: ref, ExecutionID: entry.other.Observation.LatestExecution.ExecutionID})
		must(err)
		if execution != nil {
			panic("Report resolved foreign execution")
		}
	}
	// Explicit journal IDs must obey the same filter as delivery.
	journal := reportPage(ctx, aHandle, "read_lifecycle_events", model.Object{"eventIds": append(append([]string{}, steered.EventIDs...), bWork.EventIDs...)})
	if !strings.Contains(journal, a.ID) || strings.Contains(journal, b.ID) || strings.Contains(journal, inbox.ID) {
		panic("Report journal escaped successful-event scope")
	}
	create := model.Object{"title": "Scoped report", "html": "<html><body>Evidence</body></html>"}
	aRaw, err := reportTool(ctx, aHandle, "create_report", "create", create)
	must(err)
	var aReport report.Summary
	must(json.Unmarshal(aRaw, &aReport))
	repeat, err := reportTool(ctx, aHandle, "create_report", "create", create)
	must(err)
	if !bytes.Equal(aRaw, repeat) {
		panic("Report batch receipt did not replay")
	}
	bRaw, err := reportTool(ctx, bHandle, "create_report", "create", create)
	must(err)
	var bReport report.Summary
	must(json.Unmarshal(bRaw, &bReport))
	if aReport.ID == bReport.ID {
		panic("scoped report write identities collided")
	}
	if list := reportPage(ctx, aHandle, "list_reports", model.Object{}); !strings.Contains(list, aReport.ID) || strings.Contains(list, bReport.ID) {
		panic("Report list leaked another scope")
	}
	if read := reportPage(ctx, aHandle, "read_report", model.Object{"reportId": bReport.ID}); read != "null" {
		panic("Report read leaked a known foreign ID")
	}
	_, err = reportTool(ctx, aHandle, "update_report", "foreign-update", model.Object{"reportId": bReport.ID, "title": "Wrong scope"})
	expectReportDenied(err, "foreign report update")
	_, err = reportTool(ctx, aHandle, "create_report", "spoof-scope", model.Object{"title": "Spoof", "html": "<p>x</p>", "scope": bScope})
	expectReportDenied(err, "model-supplied scope")
	refs := []model.Object{{"threadId": a.ID, "executionId": a.Observation.LatestExecution.ExecutionID}, {"threadId": b.ID, "executionId": b.Observation.LatestExecution.ExecutionID}}
	_, err = reportTool(ctx, aHandle, "update_report", "mixed-update", model.Object{"reportId": aReport.ID, "title": "Must roll back", "relatedExecutions": refs})
	expectReportDenied(err, "mixed-scope related executions")
	_, err = reportTool(ctx, aHandle, "create_report", "mixed-create", model.Object{"title": "Must roll back", "html": "<p>x</p>", "relatedExecutions": refs})
	expectReportDenied(err, "cross-scope creation")
	assertCatalog := func() {
		catalog, err := app.Catalog(ctx)
		must(err)
		if len(catalog) != 2 {
			panic("rejected Report write left a partial record")
		}
		for _, entry := range catalog {
			expected := aScope
			if entry.ID == bReport.ID {
				expected = bScope
			}
			if entry.Scope != expected || len(entry.Tags.DirectoryTags) != 1 || entry.Tags.DirectoryTags[0] != "Project" || entry.Title != "Scoped report" {
				panic("source-free Report lost stable scope or atomicity")
			}
			_, err := app.Query(ctx, plugin.OperationRequest{PluginID: "report", OperationID: "report.html", Input: raw(report.IdentityInput{ReportID: entry.ID})})
			must(err)
		}
	}
	assertCatalog()
	// Attach a permitted historical execution, then retain document ownership
	// after deleting the source. The report title-only update needs no source.
	_, err = reportTool(ctx, aHandle, "update_report", "same-scope", model.Object{"reportId": aReport.ID, "relatedExecutions": refs[:1]})
	must(err)
	must(r.SetArchived(ctx, a.ID, true))
	_, err = reportTool(ctx, aHandle, "read_thread", "archived", model.Object{"threadId": a.ID, "question": "evidence"})
	must(err)
	must(r.DeleteThread(ctx, a.ID))
	must(r.DeleteThread(ctx, a2.ID))
	_, err = reportTool(ctx, aHandle, "update_report", "after-source-delete", model.Object{"reportId": aReport.ID, "title": "Scoped report"})
	must(err)
	assertCatalog()
	finishReportFixture(ctx, aHandle, "completed")
	finishReportFixture(ctx, bHandle, "completed")
	for _, h := range []*handle{aHandle, bHandle} {
		waitFor(func() bool { h.mu.Lock(); defer h.mu.Unlock(); return h.closed })
		_, err = reportTool(ctx, h, "create_report", "retired", create)
		expectReportDenied(err, "retired scope tools")
	}
	before := f.reportCount()
	time.Sleep(150 * time.Millisecond)
	if f.reportCount() != before {
		panic("Report completion or writes woke reporting")
	}
	must(r.Close(ctx))
	must(db.Close())

	// Save a successful completion while the host is offline, then delete its
	// only source thread. A fresh runtime must still discover and process it.
	db, err = store.Open(filepath.Join(data, "state.sqlite"))
	must(err)
	open()
	pendingTask := createTask(aDir)
	finishReportFixture(ctx, f.latest(pendingTask.ID), "completed")
	must(r.DeleteThread(ctx, pendingTask.ID))
	must(r.Close(ctx))
	must(db.Close())
	db, err = store.Open(filepath.Join(data, "state.sqlite"))
	must(err)
	open()
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	recoveredWork := active(aScope, 1)
	recovered := f.latest(owners[aScope].AgentID)
	verifyReportGuidance(recovered)
	if recovered == aHandle || recovered.open.ThreadID != aHandle.open.ThreadID {
		panic("Report lost durable private session identity")
	}
	if f.reportCount() != before+1 {
		panic("recovery replayed settled scopes")
	}
	// Recovery preserves the admitted batch and its receipts. A still-running
	// saved execution reconnects without redelivery; a saved interruption
	// starts one counted retry in the same private session.
	update := model.Object{"reportId": aReport.ID, "title": "Scoped report"}
	priorWrite, err := reportTool(ctx, recovered, "update_report", "recovery-write", update)
	must(err)
	must(app.Stop(ctx))
	must(r.Close(ctx))
	var savedSession plugin.PrivateSessionSnapshot
	found, err := db.Snapshot().Get("private-session:"+owners[aScope].AgentID+":primary", &savedSession)
	must(err)
	if !found {
		panic("shutdown lost scoped private session")
	}
	savedExecution := savedSession.Record.Observation.LatestExecution
	if savedExecution == nil || (savedExecution.Status != "running" && savedExecution.Status != "interrupted") {
		panic("unexpected saved Report execution")
	}
	must(db.Close())
	db, err = store.Open(filepath.Join(data, "state.sqlite"))
	must(err)
	open()
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	resumedWork := active(aScope, 1)
	resumed := f.latest(owners[aScope].AgentID)
	if resumedWork.ID != recoveredWork.ID || resumed.open.ThreadID != recovered.open.ThreadID {
		panic("Report recovery lost its batch or session identity")
	}
	if savedExecution.Status == "running" {
		if resumedWork.ExecutionID != recoveredWork.ExecutionID || resumedWork.Attempts != recoveredWork.Attempts || !bytes.Equal(savedSession.Record.SessionState, resumed.open.SessionState.Read()) {
			panic("Report reconnect duplicated admission or spent an attempt")
		}
	} else if resumedWork.ExecutionID == recoveredWork.ExecutionID || resumedWork.Attempts != recoveredWork.Attempts+1 {
		panic("interrupted Report recovery did not count exactly one retry")
	}
	replayedWrite, err := reportTool(ctx, resumed, "update_report", "recovery-write", update)
	must(err)
	if !bytes.Equal(priorWrite, replayedWrite) {
		panic("Report recovery lost its write receipt")
	}
	recovered = resumed
	assertCatalog()
	must(app.Archive(ctx, model.ThreadRef{ThreadID: bReport.ID, TypeID: report.ThreadTypeID}, true))
	finishReportFixture(ctx, recovered, "completed")
	waitFor(func() bool { recovered.mu.Lock(); defer recovered.mu.Unlock(); return recovered.closed })
	fmt.Println("PASS production Report scopes: independent sessions/batches, successful-event routing, steering, evidence and domain isolation, atomic references/receipts, source-free ownership, deleted-source recovery, global user reads/archive and idle resource release")
}
