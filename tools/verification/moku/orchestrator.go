package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

type orchestratorHarness struct {
	plugin.Harness
	w *orchestratorWorld
}

func (h orchestratorHarness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "mock", DisplayName: "Mock", ThreadCapabilities: plugin.ThreadCapabilities{Instructions: true, ThreadContext: true, SendContext: true, ToolModes: []string{"exclusive"}}}
}
func (h orchestratorHarness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "available"}, nil
}
func (h orchestratorHarness) Settings() plugin.HarnessSettings { return orchestratorSettings{w: h.w} }
func (h orchestratorHarness) MokuContext(ctx context.Context, id string, req plugin.SettingsRequest, _ plugin.TelemetryLedger) (string, error) {
	h.w.mu.Lock()
	h.w.contextCalls[id]++
	collect := h.w.contextFn
	h.w.mu.Unlock()
	if collect != nil {
		return collect(ctx, id, req)
	}
	return id + " context", nil
}

type orchestratorSettings struct {
	plugin.HarnessSettings
	w *orchestratorWorld
}

func (f orchestratorSettings) DefaultThread(raw json.RawMessage) (json.RawMessage, error) {
	return model.CloneRaw(raw), nil
}

func (f orchestratorSettings) Describe(context.Context, plugin.SettingsRequest) (json.RawMessage, error) {
	f.w.mu.Lock()
	modelID := f.w.schemaModel
	f.w.mu.Unlock()
	if modelID == "" {
		modelID = "mock-model"
	}
	return mokuReplayRaw(map[string]any{"type": "object", "properties": map[string]any{"model": map[string]any{"type": "string", "enum": []string{modelID}}}, "required": []string{"model"}, "additionalProperties": false}), nil
}
func (f orchestratorSettings) ResolveThread(_ context.Context, r plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	if len(r.Requested) > 0 {
		f.w.mu.Lock()
		f.w.resolvedCwds = append(f.w.resolvedCwds, r.Cwd)
		f.w.mu.Unlock()
		return model.CloneRaw(r.Requested), nil
	}
	if len(r.Merged) > 0 {
		return model.CloneRaw(r.Merged), nil
	}
	return json.RawMessage(`{"model":"mock-model"}`), nil
}

type orchestratorSent struct {
	owner             string
	orchestratorInput model.AgentInput
	context           []plugin.ContextEntry
	execution         string
}
type orchestratorWorld struct {
	mu                   sync.Mutex
	records              map[string]model.ThreadRecord
	settings             model.Settings
	revision             int64
	sessionConfiguration moku.SessionConfiguration
	injections           map[string]*plugin.Injection
	listeners            map[int]func(model.ThreadRecord)
	next                 int
	sends                []orchestratorSent
	failures             []string
	closes               int
	creates              int
	resolvedCwds         []string
	reads                int
	configureConflicts   int
	schemaModel          string
	contextCalls         map[string]int
	contextFn            func(context.Context, string, plugin.SettingsRequest) (string, error)
	canonicalizeFn       func(context.Context, model.AgentInput) (model.AgentInput, error)
	beforeSend           func(context.Context) error
	afterAdmitted        func(context.Context, string, *plugin.Injection) error
	threadRead           func(context.Context, string, string) (string, error)
	wake                 chan struct{}
}

func orchestratorCopyJSON[T any](v T) T {
	b, e := json.Marshal(v)
	mokuReplayMust(e)
	var out T
	mokuReplayMust(json.Unmarshal(b, &out))
	return out
}
func newOrchestratorWorld() *orchestratorWorld {
	return &orchestratorWorld{records: map[string]model.ThreadRecord{}, settings: model.DefaultSettings([]string{"mock"}), revision: 1, injections: map[string]*plugin.Injection{}, listeners: map[int]func(model.ThreadRecord){}, contextCalls: map[string]int{}, wake: make(chan struct{}, 256)}
}
func (w *orchestratorWorld) pulse() {
	select {
	case w.wake <- struct{}{}:
	default:
	}
}
func (w *orchestratorWorld) id(prefix string) string {
	w.next++
	return fmt.Sprintf("%s-%d", prefix, w.next)
}
func (w *orchestratorWorld) thread(id string) (model.ThreadRecord, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	r, ok := w.records[id]
	if !ok {
		return r, errors.New("thread absent")
	}
	return orchestratorCopyJSON(r), nil
}
func (w *orchestratorWorld) threads() ([]model.ThreadRecord, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := []model.ThreadRecord{}
	for _, r := range w.records {
		out = append(out, orchestratorCopyJSON(r))
	}
	return out, nil
}
func (w *orchestratorWorld) update(ctx context.Context, id string, change func(*model.ThreadRecord) error) error {
	if e := ctx.Err(); e != nil {
		return e
	}
	w.mu.Lock()
	r, ok := w.records[id]
	if !ok {
		w.mu.Unlock()
		return errors.New("thread absent")
	}
	r = orchestratorCopyJSON(r)
	if e := change(&r); e != nil {
		w.mu.Unlock()
		return e
	}
	r.Revision++
	r.UpdatedAt = time.Now().UnixMilli()
	w.records[id] = orchestratorCopyJSON(r)
	ls := []func(model.ThreadRecord){}
	for _, f := range w.listeners {
		ls = append(ls, f)
	}
	w.mu.Unlock()
	for _, f := range ls {
		f(orchestratorCopyJSON(r))
	}
	w.pulse()
	return nil
}
func (w *orchestratorWorld) updateNote(ctx context.Context, owner, text string, expected *model.NoteBasis) (model.NoteUpdateResult, error) {
	var result model.NoteUpdateResult
	if err := ctx.Err(); err != nil {
		return result, err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	record, ok := w.records[owner]
	if !ok || !record.Moku {
		return result, errors.New("Moku note owner was replaced")
	}
	result.State = model.SnapshotNote(record.Note)
	if (expected == nil) != (result.State.Basis == nil) || expected != nil && *expected != *result.State.Basis {
		result.Code = "note_state_changed"
		return result, nil
	}
	if record.Note == nil {
		record.Note = &model.ThreadNote{ID: "00000000-0000-4000-8000-000000000001", Revision: 1, Text: text, UpdatedAt: time.Now().UnixMilli()}
	} else {
		note := *record.Note
		note.Revision++
		note.Text = text
		note.UpdatedAt = time.Now().UnixMilli()
		if text == "" && note.LastExposure != nil {
			note.LastExposure = nil
			note.ReadingRevision++
		}
		record.Note = &note
	}
	record.Revision++
	w.records[owner] = orchestratorCopyJSON(record)
	result.OK = true
	result.State = model.SnapshotNote(record.Note)
	return result, nil
}
func (w *orchestratorWorld) makeMoku(_ context.Context, old string, c moku.SessionConfiguration) (model.ThreadRecord, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	var previous model.ThreadRecord
	if old != "" {
		previous = w.records[old]
		delete(w.records, old)
		delete(w.injections, old)
	}
	id := w.id("moku")
	now := time.Now().UnixMilli()
	r := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: c.HarnessID, Revision: 1, Cwd: c.Cwd, Settings: model.CloneRaw(c.Settings), CreatedAt: now, UpdatedAt: now}, Moku: true, Title: "Moku", Tags: []string{}, TagEmojis: map[string]string{}, Transcript: []json.RawMessage{}}
	if c.PreserveNote {
		r.Note = previous.Note
	}
	w.records[id] = orchestratorCopyJSON(r)
	w.sessionConfiguration = orchestratorCopyJSON(c)
	return orchestratorCopyJSON(r), nil
}
func (w *orchestratorWorld) config() moku.Configuration {
	return moku.Configuration{Workspace: "/isolated/moku", DataDir: "/tmp/moku-smoke", Harnesses: map[string]plugin.Harness{"mock": orchestratorHarness{w: w}},
		Settings: func() (model.Settings, int64, error) {
			w.mu.Lock()
			defer w.mu.Unlock()
			return orchestratorCopyJSON(w.settings), w.revision, nil
		},
		ReadSessionConfiguration: func() (moku.SessionConfiguration, error) {
			w.mu.Lock()
			defer w.mu.Unlock()
			return orchestratorCopyJSON(w.sessionConfiguration), nil
		},
		Threads: w.threads, Thread: w.thread, UpdateThread: w.update, UpdateNote: w.updateNote,
		EnsureSession: func(ctx context.Context, c moku.SessionConfiguration) (model.ThreadRecord, error) {
			records, _ := w.threads()
			for _, r := range records {
				if r.Moku {
					return r, nil
				}
			}
			return w.makeMoku(ctx, "", c)
		},
		ReplaceSession: w.makeMoku,
		ConfigureSession: func(ctx context.Context, id string, revision int64, c moku.SessionConfiguration) error {
			w.mu.Lock()
			conflict := w.configureConflicts > 0
			if conflict {
				w.configureConflicts--
			}
			w.mu.Unlock()
			if conflict {
				if err := w.update(ctx, id, func(*model.ThreadRecord) error { return nil }); err != nil {
					return err
				}
				return model.NewError("REVISION_CONFLICT", "injected competing terminal settlement")
			}
			e := w.update(ctx, id, func(r *model.ThreadRecord) error {
				if r.Revision != revision {
					return model.NewError("REVISION_CONFLICT", "revision conflict")
				}
				r.Settings = model.CloneRaw(c.Settings)
				return nil
			})
			if e == nil {
				w.mu.Lock()
				w.sessionConfiguration = orchestratorCopyJSON(c)
				w.mu.Unlock()
			}
			return e
		},
		OpenSession: func(ctx context.Context, id string, injection *plugin.Injection) error {
			if e := ctx.Err(); e != nil {
				return e
			}
			w.mu.Lock()
			w.injections[id] = injection
			w.mu.Unlock()
			return nil
		},
		CloseSession: func(context.Context, string) error { w.mu.Lock(); w.closes++; w.mu.Unlock(); return nil },
		SubscribeCommitted: func(callback func(model.ThreadRecord)) func() {
			w.mu.Lock()
			w.next++
			id := w.next
			w.listeners[id] = callback
			w.mu.Unlock()
			return func() { w.mu.Lock(); delete(w.listeners, id); w.mu.Unlock() }
		},
		SendSession: w.sendSession,
		CreateThread: func(ctx context.Context, q moku.CreateThreadRequest) (moku.CreatedThread, error) {
			cwd := q.Cwd
			if cwd == "" {
				cwd = "/tmp/mokusei-child"
			}
			settings := q.Settings
			if q.ResolveSettings != nil {
				var e error
				settings, e = q.ResolveSettings(ctx, cwd)
				if e != nil {
					return moku.CreatedThread{}, e
				}
			}
			w.mu.Lock()
			w.creates++
			id := w.id("child")
			execution := w.id("child-execution")
			now := time.Now().UnixMilli()
			r := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: q.HarnessID, Cwd: cwd, Settings: settings, CreatedAt: now, UpdatedAt: now, Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: execution, Status: "running", StartedAt: now}}}, Title: q.Input.Parts[0].Text, Tags: []string{}}
			w.records[id] = orchestratorCopyJSON(r)
			w.mu.Unlock()
			return moku.CreatedThread{Record: r, Execution: plugin.SessionSendResult{ExecutionID: execution, StartedNewExecution: true}, Acknowledgement: json.RawMessage(`{"accepted":true}`)}, nil
		},
		SendThread: func(ctx context.Context, id string, orchestratorInput model.AgentInput) (plugin.SessionSendResult, error) {
			r, e := w.thread(id)
			if e != nil {
				return plugin.SessionSendResult{}, e
			}
			return plugin.SessionSendResult{ExecutionID: r.Observation.LatestExecution.ExecutionID}, nil
		},
		ReadThread: func(ctx context.Context, id, question string) (string, error) {
			w.mu.Lock()
			w.reads++
			read := w.threadRead
			w.mu.Unlock()
			if read != nil {
				return read(ctx, id, question)
			}
			return "inspected: " + question, nil
		},
		InterruptThread: func(ctx context.Context, id string) error { return w.terminal(ctx, id, "interrupted") },
		CanonicalizeInput: func(ctx context.Context, orchestratorInput model.AgentInput) (model.AgentInput, error) {
			w.mu.Lock()
			fn := w.canonicalizeFn
			w.mu.Unlock()
			if fn != nil {
				return fn(ctx, orchestratorInput)
			}
			return orchestratorInput, nil
		},
		ReportFailure: func(kind string, e error) {
			w.mu.Lock()
			w.failures = append(w.failures, kind+": "+e.Error())
			w.mu.Unlock()
			w.pulse()
		},
	}
}
func (w *orchestratorWorld) sendSession(ctx context.Context, id string, orchestratorInput model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry, onAdmitted func(plugin.SessionSendResult) error) (plugin.SessionSendResult, error) {
	w.mu.Lock()
	before, after := w.beforeSend, w.afterAdmitted
	w.mu.Unlock()
	if before != nil {
		if e := before(ctx); e != nil {
			return plugin.SessionSendResult{}, e
		}
	}
	var result plugin.SessionSendResult
	e := w.update(ctx, id, func(r *model.ThreadRecord) error {
		existing := r.Observation.LatestExecution
		if existing == nil || existing.Terminal() {
			r.Observation.LatestExecution = &model.PublicExecution{ExecutionID: w.id("execution"), Status: "running", StartedAt: time.Now().UnixMilli()}
			result.StartedNewExecution = true
		}
		result.ExecutionID = r.Observation.LatestExecution.ExecutionID
		return nil
	})
	if e != nil {
		return result, e
	}
	if onAdmitted != nil {
		if e = onAdmitted(result); e != nil {
			return result, e
		}
	}
	if after != nil && orchestratorInput.Presentation != "internal" {
		if e = after(ctx, id, injection); e != nil {
			return result, e
		}
	}
	w.mu.Lock()
	w.sends = append(w.sends, orchestratorSent{id, orchestratorCopyJSON(orchestratorInput), orchestratorCopyJSON(entries), result.ExecutionID})
	w.mu.Unlock()
	w.pulse()
	return result, nil
}
func (w *orchestratorWorld) terminal(ctx context.Context, id, status string) error {
	return w.update(ctx, id, func(r *model.ThreadRecord) error {
		if r.Observation.LatestExecution == nil {
			return errors.New("no execution")
		}
		now := time.Now().UnixMilli()
		r.Observation.LatestExecution.Status = status
		r.Observation.LatestExecution.FinishedAt = &now
		return nil
	})
}
func (w *orchestratorWorld) mokuRecord() model.ThreadRecord {
	rs, e := w.threads()
	mokuReplayMust(e)
	for _, r := range rs {
		if r.Moku {
			return r
		}
	}
	panic("no Moku")
}
func (w *orchestratorWorld) binding(name string) plugin.ToolBinding {
	r := w.mokuRecord()
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, b := range w.injections[r.ID].Tools.Bindings {
		if b.Name == name {
			return b
		}
	}
	panic("missing tool " + name)
}
func (w *orchestratorWorld) call(name, args string) (json.RawMessage, error) {
	return w.binding(name).Execute(mokuReplayContext(), plugin.ToolCall{CallID: "native-recycled-token", Arguments: json.RawMessage(args)})
}
func (w *orchestratorWorld) wait(label string, predicate func() bool) {
	timer := time.NewTimer(12 * time.Second)
	defer timer.Stop()
	for {
		if predicate() {
			return
		}
		select {
		case <-w.wake:
		case <-timer.C:
			panic("timeout: " + label)
		}
	}
}
func orchestratorInput(text string) moku.SubmitRequest {
	return moku.SubmitRequest{Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}}
}
func startOrchestrator(w *orchestratorWorld) *moku.Coordinator {
	c, e := moku.New(w.config())
	mokuReplayMust(e)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	return c
}
func stopOrchestrator(c *moku.Coordinator) {
	ctx, cancel := context.WithTimeout(mokuReplayContext(), 3*time.Second)
	defer cancel()
	mokuReplayMust(c.Stop(ctx))
}
func replayOrchestratorBasics() {
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	w.mu.Lock()
	w.afterAdmitted = func(ctx context.Context, id string, injection *plugin.Injection) error {
		r, e := w.thread(id)
		if e != nil {
			return e
		}
		mokuReplayCheck(len(r.Transcript) > 0 && strings.Contains(string(r.Transcript[len(r.Transcript)-1]), `"role":"user"`), "native dispatch before durable user transcript")
		for _, b := range injection.Tools.Bindings {
			if b.Name == "talk" {
				_, e = b.Execute(ctx, plugin.ToolCall{Arguments: json.RawMessage(`{"text":"Native execution is admitted."}`)})
				return e
			}
		}
		return errors.New("missing native tool injection")
	}
	w.mu.Unlock()
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("coordinate")))
	initialOwner := w.mokuRecord().ID
	w.mu.Lock()
	mokuReplayCheck(strings.Contains(strings.Join(w.injections[initialOwner].Instructions, "\n"), "After successfully creating or sending delegated work, use talk"), "default Moku prompt omitted Overview confirmation policy")
	w.mu.Unlock()
	mokuReplayCheck(c.Clear(mokuReplayContext()) != nil, "clear active session")
	w.mu.Lock()
	createsBefore := w.creates
	w.mu.Unlock()
	_, missingErr := w.call("create_thread", `{"prompt":"missing isolation choice","harnessId":"mock","options":{"model":"mock-model"}}`)
	mokuReplayCheck(missingErr != nil && strings.Contains(missingErr.Error(), "worktree"), "injected tool omitted missing-worktree error")
	w.mu.Lock()
	mokuReplayCheck(w.creates == createsBefore, "missing worktree reached runtime creation")
	w.mu.Unlock()
	raw, e := w.call("create_thread", `{"worktree":false,"prompt":"delegate","harnessId":"mock","options":{"model":"mock-model"}}`)
	mokuReplayMust(e)
	var created struct {
		ThreadID string `json:"threadId"`
	}
	mokuReplayMust(json.Unmarshal(raw, &created))
	mokuReplayCheck(created.ThreadID != "", "created thread")
	w.mu.Lock()
	mokuReplayCheck(len(w.resolvedCwds) > 0 && w.resolvedCwds[len(w.resolvedCwds)-1] == "/tmp/mokusei-child", "target settings resolved against Moku workspace")
	w.mu.Unlock()
	for _, item := range [][2]string{{"send_to_thread", fmt.Sprintf(`{"threadId":%q,"prompt":"continue"}`, created.ThreadID)}, {"get_thread_status", fmt.Sprintf(`{"threadId":%q}`, created.ThreadID)}, {"read_thread", fmt.Sprintf(`{"threadId":%q,"question":"what changed?"}`, created.ThreadID)}, {"talk", `{"text":"Delegated work."}`}, {"list_threads", `{"limit":1}`}} {
		result, callErr := w.call(item[0], item[1])
		mokuReplayMust(callErr)
		if item[0] == "send_to_thread" {
			var acknowledgement map[string]any
			mokuReplayMust(json.Unmarshal(result, &acknowledgement))
			executionID, validExecution := acknowledgement["executionId"].(string)
			mokuReplayCheck(acknowledgement["ok"] == true && acknowledgement["threadId"] == created.ThreadID &&
				acknowledgement["startedNewExecution"] == false && validExecution && executionID != "" &&
				acknowledgement["hint"] == moku.ThreadNotificationHint, "steering success lost its delivery acknowledgement")
			record := w.mokuRecord()
			var audit map[string]any
			mokuReplayMust(json.Unmarshal(record.Transcript[len(record.Transcript)-1], &audit))
			mokuReplayCheck(audit["name"] == "send_to_thread" && audit["completedAt"] != nil && audit["isError"] != true &&
				string(mokuReplayRaw(audit["result"])) == string(mokuReplayRaw(acknowledgement)), "successful send was audited as a failure")
		}
	}
	_, e = w.call("send_to_thread", fmt.Sprintf(`{"threadId":%q,"prompt":"must reject Moku target"}`, initialOwner))
	mokuReplayCheck(e != nil, "send to Moku target unexpectedly succeeded")
	rejectedRecord := w.mokuRecord()
	var rejectedSend map[string]any
	mokuReplayMust(json.Unmarshal(rejectedRecord.Transcript[len(rejectedRecord.Transcript)-1], &rejectedSend))
	var rejectedResult struct {
		Error string `json:"error"`
	}
	mokuReplayMust(json.Unmarshal(mokuReplayRaw(rejectedSend["result"]), &rejectedResult))
	mokuReplayCheck(rejectedSend["name"] == "send_to_thread" && rejectedSend["completedAt"] != nil &&
		rejectedSend["isError"] == true && strings.Contains(rejectedResult.Error, "ordinary Agent Threads"), "rejected send lost its failure audit")
	var talkSchema struct {
		Properties map[string]struct {
			MaxLength   int    `json:"maxLength"`
			Description string `json:"description"`
		} `json:"properties"`
	}
	mokuReplayMust(json.Unmarshal(w.binding("talk").InputSchema, &talkSchema))
	mokuReplayCheck(talkSchema.Properties["text"].MaxLength == moku.TalkTextMaxCharacters &&
		talkSchema.Properties["text"].Description == moku.TalkTextPolicy &&
		strings.Contains(w.binding("talk").Description, moku.TalkTextPolicy) &&
		strings.Contains(moku.DefaultSystemPrompt(), moku.TalkTextPolicy) &&
		strings.Contains(moku.TalkTextPolicy, "Use emoji naturally when they add expression and suit the context."), "talk schema and prompt policy drifted")
	var noteSchema struct {
		Properties map[string]struct {
			Description string `json:"description"`
		} `json:"properties"`
	}
	mokuReplayMust(json.Unmarshal(w.binding("update_note").InputSchema, &noteSchema))
	mokuReplayCheck(noteSchema.Properties["text"].Description == moku.NoteTextPolicy &&
		strings.Contains(w.binding("update_note").Description, moku.NoteTextPolicy) &&
		strings.Contains(moku.DefaultSystemPrompt(), moku.NoteTextPolicy) &&
		strings.Contains(moku.NoteTextPolicy, "Use emoji naturally when they add expression and suit the context."), "note schema and prompt policy drifted")
	// A bubble is projected from successful, completed audit entries. Preserve
	// the exact text and leave the execution running; invalid calls cannot
	// replace the latest successful bubble.
	for _, text := range []string{strings.Repeat("界", moku.TalkTextMaxCharacters), strings.Repeat("😀", moku.TalkTextMaxCharacters), strings.Repeat("e\u0301", moku.TalkTextMaxCharacters/2), strings.Repeat("W", moku.TalkTextMaxCharacters), strings.Repeat("x", moku.TalkTextMaxCharacters-1) + " ", "  Exact\r\ntext\t ", "\u0085Visible\u0085", "Latest confirmation."} {
		_, e = w.call("talk", string(mokuReplayRaw(map[string]string{"text": text})))
		mokuReplayMust(e)
		var audit struct {
			Arguments struct {
				Text string `json:"text"`
			} `json:"arguments"`
		}
		record := w.mokuRecord()
		mokuReplayMust(json.Unmarshal(record.Transcript[len(record.Transcript)-1], &audit))
		mokuReplayCheck(audit.Arguments.Text == text, "talk changed accepted text in durable audit")
	}
	for _, args := range []string{`{"text":"   "}`, `{"text":"\u0085"}`, `{"text":"\u0085 \r\n\uFEFF"}`, `{"text":"\uFEFF\u3000\n"}`, `{"text":"a\u0000b"}`, string(mokuReplayRaw(map[string]string{"text": strings.Repeat("界", moku.TalkTextMaxCharacters+1)})), string(mokuReplayRaw(map[string]string{"text": strings.Repeat("😀", moku.TalkTextMaxCharacters+1)})), string(mokuReplayRaw(map[string]string{"text": strings.Repeat("x", moku.TalkTextMaxCharacters) + " "})), string(mokuReplayRaw(map[string]string{"text": strings.Repeat("e\u0301", moku.TalkTextMaxCharacters/2) + "x"})), `{"text":"valid","extra":true}`} {
		_, e = w.call("talk", args)
		mokuReplayCheck(e != nil && e.Error() != "", "invalid talk accepted without explanatory error")
	}
	latestTalk := ""
	for _, raw := range w.mokuRecord().Transcript {
		var item struct {
			Name        string `json:"name"`
			CompletedAt *int64 `json:"completedAt"`
			IsError     bool   `json:"isError"`
			Arguments   struct {
				Text string `json:"text"`
			} `json:"arguments"`
		}
		mokuReplayMust(json.Unmarshal(raw, &item))
		if item.Name == "talk" && item.CompletedAt != nil && !item.IsError {
			latestTalk = item.Arguments.Text
		}
	}
	mokuReplayCheck(latestTalk == "Latest confirmation.", "talk audit lost latest successful bubble text")
	mokuReplayCheck(!w.mokuRecord().Observation.LatestExecution.Terminal(), "talk ended the execution")
	fmt.Println("PASS Moku Overview talk policy, exact bubble text, replacement, Unicode code point bounds and active execution")
	_, e = w.call("create_thread", `{"worktree":false,"prompt":"bad missing model","harnessId":"mock","options":{}}`)
	mokuReplayCheck(e != nil, "missing required native option admitted")
	r := w.mokuRecord()
	toolCount := 0
	for _, raw := range r.Transcript {
		var item map[string]any
		mokuReplayMust(json.Unmarshal(raw, &item))
		if item["type"] == "tool-operation" {
			toolCount++
			mokuReplayCheck(item["completedAt"] != nil, "unsettled successful/failed tool")
			mokuReplayCheck(item["callId"] != "native-recycled-token", "native correlation leaked into durable ID")
		}
	}
	mokuReplayCheck(toolCount >= 7, "tool transcript coverage")
	_, e = w.call("interrupt_thread", fmt.Sprintf(`{"threadIds":[%q]}`, created.ThreadID))
	mokuReplayMust(e)
	w.wait("terminal auto resume", func() bool {
		w.mu.Lock()
		defer w.mu.Unlock()
		for _, s := range w.sends {
			if s.orchestratorInput.Presentation == "internal" && strings.Contains(s.orchestratorInput.Parts[0].Text, "terminal event") {
				return true
			}
		}
		return false
	})
	old := w.binding("talk")
	mokuReplayMust(c.Cancel(mokuReplayContext()))
	mokuReplayMust(c.Clear(mokuReplayContext()))
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("new session")))
	_, e = old.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: json.RawMessage(`{"text":"stale"}`)})
	mokuReplayCheck(e != nil, "cleared session tool survived")
	sameID := w.mokuRecord().ID
	old = w.binding("talk")
	mokuReplayMust(c.Cancel(mokuReplayContext()))
	w.mu.Lock()
	prompt := "changed routing policy"
	w.settings.Moku.RoutingGuidance = &prompt
	w.configureConflicts = 1
	w.revision++
	w.mu.Unlock()
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("new generation")))
	mokuReplayCheck(w.mokuRecord().ID == sameID, "same harness unnecessarily changed thread")
	_, e = old.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: json.RawMessage(`{"text":"stale generation"}`)})
	mokuReplayCheck(e != nil, "recycled generation tool survived")
	w.mu.Lock()
	mokuReplayCheck(w.configureConflicts == 0, "CAS conflict replay did not run")
	w.mu.Unlock()
	old = w.binding("talk")
	mokuReplayMust(c.Cancel(mokuReplayContext()))
	w.mu.Lock()
	w.schemaModel = "next-model"
	w.mu.Unlock()
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("fresh target catalog")))
	_, e = old.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: json.RawMessage(`{"text":"retired target generation"}`)})
	mokuReplayCheck(e != nil, "retired target catalog binding survived")
	_, e = w.call("create_thread", `{"worktree":false,"prompt":"new target catalog","harnessId":"mock","options":{"model":"next-model"}}`)
	mokuReplayMust(e)
	stopOrchestrator(c)
	mokuReplayCheck(c.Submit(mokuReplayContext(), orchestratorInput("after stop")) != nil, "submission after stop")
	fmt.Println("PASS durable admission, all core tools, strict native options, audit records, auto-resume, clear, generation, shutdown")
}
func replayOrchestratorPendingCancel() {
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("init")))
	mokuReplayMust(c.Cancel(mokuReplayContext()))
	entered := make(chan struct{})
	w.mu.Lock()
	w.canonicalizeFn = func(ctx context.Context, in model.AgentInput) (model.AgentInput, error) {
		close(entered)
		<-ctx.Done()
		return in, ctx.Err()
	}
	w.mu.Unlock()
	done := make(chan error, 1)
	go func() { done <- c.Submit(mokuReplayContext(), orchestratorInput("pending")) }()
	mokuReplayAwait("entered", entered)
	mokuReplayCheck(c.Clear(mokuReplayContext()) != nil, "clear discarded queued input")
	mokuReplayMust(c.Cancel(mokuReplayContext()))
	select {
	case e := <-done:
		mokuReplayCheck(e != nil, "cancelled admission succeeded")
	case <-time.After(time.Second):
		panic("queued cancellation stalled")
	}
	w.mu.Lock()
	w.canonicalizeFn = nil
	w.mu.Unlock()
	entered = make(chan struct{})
	w.mu.Lock()
	w.beforeSend = func(ctx context.Context) error { close(entered); <-ctx.Done(); return ctx.Err() }
	w.mu.Unlock()
	go func() { done <- c.Submit(mokuReplayContext(), orchestratorInput("native pending")) }()
	mokuReplayAwait("entered", entered)
	mokuReplayMust(c.Cancel(mokuReplayContext()))
	select {
	case e := <-done:
		mokuReplayCheck(e != nil, "native pending admission succeeded")
	case <-time.After(time.Second):
		panic("pre-admission native cancellation stalled")
	}
	w.mu.Lock()
	w.beforeSend = nil
	w.mu.Unlock()
	stopOrchestrator(c)
	fmt.Println("PASS queued/entered admission cancellation and clear guard")
}
func replayOrchestratorContextLifetime() {
	w := newOrchestratorWorld()
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	w.contextFn = func(ctx context.Context, id string, req plugin.SettingsRequest) (string, error) {
		if id == "workspace" {
			once.Do(func() { close(entered) })
			<-release
			return "late workspace", nil
		}
		return "telemetry", nil
	}
	c := startOrchestrator(w)
	started := time.Now()
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("bounded context")))
	mokuReplayCheck(time.Since(started) >= 1900*time.Millisecond && time.Since(started) < 4*time.Second, "workspace context timeout unbounded")
	mokuReplayAwait("entered", entered)
	w.mu.Lock()
	first := w.contextCalls["telemetry"]
	w.mu.Unlock()
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("cached context")))
	w.mu.Lock()
	second := w.contextCalls["telemetry"]
	w.mu.Unlock()
	mokuReplayCheck(first == second, "telemetry not cached")
	ctx, cancel := context.WithTimeout(mokuReplayContext(), 50*time.Millisecond)
	e := c.Stop(ctx)
	cancel()
	mokuReplayCheck(e != nil, "shutdown abandoned uncooperative contributor")
	close(release)
	stopOrchestrator(c)
	fmt.Println("PASS bounded context timeout, cached telemetry, tracked contributor shutdown")
}
func replayOrchestratorContextGeneration() {
	w := newOrchestratorWorld()
	oldStarted, oldRelease := make(chan struct{}), make(chan struct{})
	newStarted, newRelease := make(chan struct{}), make(chan struct{})
	var oldOnce, newOnce sync.Once
	w.contextFn = func(ctx context.Context, id string, req plugin.SettingsRequest) (string, error) {
		if id != "telemetry" {
			return "workspace", nil
		}
		if strings.Contains(string(req.Settings), "new") {
			newOnce.Do(func() { close(newStarted) })
			<-newRelease
			return "new generation", nil
		}
		oldOnce.Do(func() { close(oldStarted) })
		<-oldRelease
		return "old generation", nil
	}
	c := startOrchestrator(w)
	lastContext := func() string {
		w.mu.Lock()
		defer w.mu.Unlock()
		encoded, _ := json.Marshal(w.sends[len(w.sends)-1].context)
		return string(encoded)
	}
	submit := func(text string) {
		ctx, cancel := context.WithTimeout(mokuReplayContext(), time.Second)
		defer cancel()
		mokuReplayMust(c.Submit(ctx, orchestratorInput(text)))
	}
	submit("send while account telemetry is blocked")
	mokuReplayAwait("old telemetry started", oldStarted)
	first := lastContext()
	mokuReplayCheck(strings.Contains(first, "unknown") && strings.Contains(first, "Do not assume unlimited") && !strings.Contains(first, "old generation"), "missing telemetry must be explicitly unknown without delaying submission")
	mokuReplayMust(w.terminal(mokuReplayContext(), w.mokuRecord().ID, "completed"))
	w.mu.Lock()
	w.settings.Harnesses["mock"] = json.RawMessage(`{"label":"new"}`)
	w.revision++
	w.mu.Unlock()
	submit("send new configuration while old refresh is blocked")
	mokuReplayCheck(strings.Contains(lastContext(), "unknown") && !strings.Contains(lastContext(), "old generation"), "replacement generation inherited stale account context")
	close(oldRelease)
	mokuReplayAwait("new telemetry started", newStarted)
	submit("old refresh completed but new refresh is still blocked")
	mokuReplayCheck(strings.Contains(lastContext(), "unknown") && !strings.Contains(lastContext(), "old generation"), "completed stale refresh published into replacement")
	close(newRelease)
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		submit("observe background refresh")
		latest := lastContext()
		mokuReplayCheck(!strings.Contains(latest, "old generation"), "old generation leaked after refresh")
		if strings.Contains(latest, "new generation") {
			break
		}
		select {
		case <-tick.C:
		case <-deadline.C:
			panic("refreshed current generation was not adopted")
		}
	}
	stopOrchestrator(c)
	fmt.Println("PASS blocked telemetry admits unknown context, rejects stale generations and adopts background refresh")
}
func replayOrchestratorToolCancellation() {
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("tool cancellation")))
	raw, e := w.call("create_thread", `{"worktree":false,"prompt":"delegate","harnessId":"mock","options":{"model":"mock-model"}}`)
	mokuReplayMust(e)
	var created struct {
		ThreadID string `json:"threadId"`
	}
	mokuReplayMust(json.Unmarshal(raw, &created))
	entered := make(chan struct{})
	w.mu.Lock()
	w.threadRead = func(ctx context.Context, _, _ string) (string, error) {
		close(entered)
		<-ctx.Done()
		return "", ctx.Err()
	}
	w.mu.Unlock()
	done := make(chan error, 1)
	go func() {
		_, e := w.call("read_thread", fmt.Sprintf(`{"threadId":%q,"question":"blocked"}`, created.ThreadID))
		done <- e
	}()
	mokuReplayAwait("entered", entered)
	mokuReplayMust(c.Cancel(mokuReplayContext()))
	select {
	case e := <-done:
		mokuReplayCheck(e != nil, "tool ignored terminal cancellation")
	case <-time.After(time.Second):
		panic("tool scope did not cancel")
	}
	stopOrchestrator(c)
	fmt.Println("PASS terminal observation cancels in-flight tool scope")
}
func replayOrchestratorStartRollback() {
	w := newOrchestratorWorld()
	cfg := w.config()
	first := true
	cfg.Threads = func() ([]model.ThreadRecord, error) {
		if first {
			first = false
			return nil, errors.New("storage unavailable")
		}
		return w.threads()
	}
	c, e := moku.New(cfg)
	mokuReplayMust(e)
	mokuReplayCheck(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}) != nil, "startup storage failure ignored")
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("retry startup")))
	stopOrchestrator(c)
	fmt.Println("PASS startup failure rolls back lifecycle for retry")
}

func replayOrchestratorStaleScope() {
	w := newOrchestratorWorld()
	cfg := w.config()
	var gate sync.Mutex
	armed := false
	entered, release := make(chan struct{}), make(chan struct{})
	cfg.Thread = func(id string) (model.ThreadRecord, error) {
		r, e := w.thread(id)
		gate.Lock()
		wait := armed
		armed = false
		gate.Unlock()
		if wait {
			close(entered)
			<-release
		}
		return r, e
	}
	c, e := moku.New(cfg)
	mokuReplayMust(e)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("scope race")))
	owner := w.mokuRecord().ID
	raw, e := w.call("create_thread", `{"worktree":false,"prompt":"delegate","harnessId":"mock","options":{"model":"mock-model"}}`)
	mokuReplayMust(e)
	var created struct {
		ThreadID string `json:"threadId"`
	}
	mokuReplayMust(json.Unmarshal(raw, &created))
	gate.Lock()
	armed = true
	gate.Unlock()
	done := make(chan error, 1)
	go func() {
		_, e := w.call("read_thread", fmt.Sprintf(`{"threadId":%q,"question":"must not execute after terminal"}`, created.ThreadID))
		done <- e
	}()
	mokuReplayAwait("entered", entered)
	mokuReplayMust(w.terminal(mokuReplayContext(), owner, "completed"))
	close(release)
	select {
	case e := <-done:
		w.mu.Lock()
		reads := w.reads
		w.mu.Unlock()
		mokuReplayCheck(reads == 0, "stale execution scope performed model read after terminal callback")
		mokuReplayCheck(e != nil, "stale execution scope resurrected after terminal callback")
	case <-time.After(time.Second):
		panic("stale tool hung")
	}
	stopOrchestrator(c)
	fmt.Println("PASS terminal callback cannot resurrect a stale tool execution scope")
}

func replayOrchestratorBatchInterrupt() {
	w := newOrchestratorWorld()
	config := w.config()
	var interrupted []string
	config.InterruptThread = func(ctx context.Context, id string) error {
		interrupted = append(interrupted, id)
		if id == "backend-failure" {
			return errors.New("native interruption failed")
		}
		return w.terminal(ctx, id, "interrupted")
	}
	c, err := moku.New(config)
	mokuReplayMust(err)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("interrupt several threads")))
	for _, id := range []string{"first", "second", "backend-failure", "last"} {
		w.mu.Lock()
		w.records[id] = model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "mock", Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: id + "-execution", Status: "running"}}}}
		w.mu.Unlock()
	}
	for _, args := range []string{
		`{}`, `{"threadId":"first"}`, `{"threadIds":[]}`, `{"threadIds":"first"}`,
		`{"threadIds":["first",null]}`, `{"threadIds":["first",42]}`,
		`{"threadIds":["first",""]}`, `{"threadIds":["first","bad id"]}`,
		`{"threadIds":["first","bad\u0000id"]}`,
		fmt.Sprintf(`{"threadIds":["first",%q]}`, strings.Repeat("x", 129)),
		`{"threadIds":["first"],"threadId":"first"}`,
	} {
		_, err = w.call("interrupt_thread", args)
		mokuReplayCheck(err != nil, "invalid interruption batch admitted: "+args)
		mokuReplayCheck(len(interrupted) == 0, "invalid batch interrupted a thread")
	}
	check := func(args string, ids []string, success []bool) {
		raw, err := w.call("interrupt_thread", args)
		mokuReplayMust(err)
		var response struct {
			OK      bool `json:"ok"`
			Results []struct {
				ThreadID string `json:"threadId"`
				OK       bool   `json:"ok"`
				Error    string `json:"error"`
			} `json:"results"`
		}
		mokuReplayMust(json.Unmarshal(raw, &response))
		mokuReplayCheck(len(response.Results) == len(ids), "missing batch interruption results")
		allOK := true
		for i, result := range response.Results {
			mokuReplayCheck(result.ThreadID == ids[i] && result.OK == success[i], "incorrect batch result: "+string(raw))
			mokuReplayCheck((result.Error == "") == result.OK, "missing failure reason or unexpected success error")
			allOK = allOK && result.OK
		}
		mokuReplayCheck(response.OK == allOK, "incorrect overall interruption outcome")
	}
	check(`{"threadIds":["first","second"]}`, []string{"first", "second"}, []bool{true, true})
	mokuID := w.mokuRecord().ID
	args := fmt.Sprintf(`{"threadIds":["missing",%q,"backend-failure","last"]}`, mokuID)
	check(args, []string{"missing", mokuID, "backend-failure", "last"}, []bool{false, false, false, true})
	mokuReplayCheck(strings.Join(interrupted, ",") == "first,second,backend-failure,last", "batch stopped after failure or interrupted Moku")
	for _, id := range []string{"first", "second", "last"} {
		record, err := w.thread(id)
		mokuReplayMust(err)
		mokuReplayCheck(record.Observation.LatestExecution.Status == "interrupted", "successful target still running")
	}
	check(`{"threadIds":["last","last"]}`, []string{"last", "last"}, []bool{true, true})
	mokuReplayCheck(strings.Join(interrupted, ",") == "first,second,backend-failure,last,last,last", "repeated IDs lost ordered results")
	check(`{"threadIds":["missing"]}`, []string{"missing"}, []bool{false})
	fmt.Println("PASS batch interruption: strict input, ordered per-thread outcomes, failure continuation and Moku isolation")
}

func runOrchestratorReplay() error {
	for _, fixture := range []struct {
		name string
		run  func()
	}{
		{"tools, configuration CAS and target generation", replayOrchestratorBasics},
		{"batch interruption and per-thread failures", replayOrchestratorBatchInterrupt},
		{"deferred native target admission", replayOrchestratorDeferredTarget},
		{"parallel Target discovery ownership", replayOrchestratorParallelTargets},
		{"workspace avoids native account discovery", replayWorkspaceWithoutAccounts},
		{"queued admission cancellation", replayOrchestratorPendingCancel},
		{"context lifetime and cache", replayOrchestratorContextLifetime},
		{"context generation ownership", replayOrchestratorContextGeneration},
		{"tool terminal cancellation", replayOrchestratorToolCancellation},
		{"startup rollback", replayOrchestratorStartRollback},
		{"stale terminal execution scope", replayOrchestratorStaleScope},
	} {
		if err := runMokuReplaySection(fixture.name, func() error { fixture.run(); return nil }); err != nil {
			return err
		}
	}
	return nil
}

// A target whose native probe/catalog cannot complete until explicitly released.
// Moku must still admit its host's first input and advertise on-demand discovery.
type deferredNativeHarness struct {
	orchestratorHarness
	ready   <-chan struct{}
	entered chan<- struct{}
}

func (h deferredNativeHarness) Descriptor() plugin.HarnessDescriptor {
	d := h.orchestratorHarness.Descriptor()
	d.ID = "opencode"
	d.DisplayName = "Deferred OpenCode"
	return d
}
func (h deferredNativeHarness) DiscoverMokuTarget(context.Context, plugin.SettingsRequest) (json.RawMessage, plugin.Availability, error) {
	return nil, plugin.Availability{Available: true}, nil
}
func (h deferredNativeHarness) Probe(ctx context.Context, _ plugin.SettingsRequest, _ string) (plugin.Availability, error) {
	select {
	case h.entered <- struct{}{}:
	default:
	}
	select {
	case <-h.ready:
		return plugin.Availability{Available: true}, nil
	case <-ctx.Done():
		return plugin.Availability{}, ctx.Err()
	}
}
func (h deferredNativeHarness) Settings() plugin.HarnessSettings {
	return deferredNativeSettings{orchestratorSettings: orchestratorSettings{w: h.w}, ready: h.ready}
}

type deferredNativeSettings struct {
	orchestratorSettings
	ready <-chan struct{}
}

func (s deferredNativeSettings) Describe(ctx context.Context, r plugin.SettingsRequest) (json.RawMessage, error) {
	select {
	case <-s.ready:
		return s.orchestratorSettings.Describe(ctx, r)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func replayOrchestratorDeferredTarget() {
	w := newOrchestratorWorld()
	w.settings.Moku.TargetHarnessIDs = []string{"mock", "opencode"}
	w.settings.Moku.HostHarnessPreference = "mock"
	w.settings.Harnesses["opencode"] = json.RawMessage(`{}`)
	ready := make(chan struct{})
	entered := make(chan struct{}, 1)
	cfg := w.config()
	cfg.Harnesses["opencode"] = deferredNativeHarness{orchestratorHarness: orchestratorHarness{w: w}, ready: ready, entered: entered}
	c, err := moku.New(cfg)
	mokuReplayMust(err)
	defer stopOrchestrator(c)
	ctx, cancel := context.WithTimeout(mokuReplayContext(), 2*time.Second)
	defer cancel()
	mokuReplayMust(c.Start(ctx, plugin.RuntimeStartContext{Reason: "manual"}))
	mokuReplayMust(c.Submit(ctx, orchestratorInput("first message while native catalog blocked")))
	select {
	case <-entered:
		panic("deferred target probe blocked first admission")
	default:
	}
	schema := w.binding("create_thread").InputSchema
	mokuReplayCheck(strings.Contains(string(schema), "opencode") && strings.Contains(string(schema), "describe_native_harness"), "deferred native target not advertised")
	_, err = w.call("create_thread", `{"worktree":false,"prompt":"invalid defaults","harnessId":"opencode","options":{}}`)
	mokuReplayCheck(err != nil, "deferred native target accepted empty options")
	completed := make(chan error, 1)
	go func() { _, err := w.call("describe_native_harness", `{"harnessId":"opencode"}`); completed <- err }()
	mokuReplayAwait("on-demand native probe", entered)
	select {
	case <-completed:
		panic("on-demand description skipped native probe")
	default:
	}
	close(ready)
	mokuReplayMust(<-completed)
	_, err = w.call("create_thread", `{"worktree":false,"prompt":"reject invalid model","harnessId":"opencode","options":{"model":"unadvertised"}}`)
	mokuReplayCheck(err != nil, "deferred target bypassed native schema")
	_, err = w.call("create_thread", `{"worktree":false,"prompt":"native task","harnessId":"opencode","options":{"model":"mock-model"}}`)
	mokuReplayMust(err)
	fmt.Println("PASS deferred native target: first Moku admission before blocked catalog; on-demand exact schema; empty and invalid options rejected")
}

// Every probe and description has an independent gate. A sequential coordinator
// cannot reach all entered signals; completion order must not affect tool JSON.
type targetDiscoveryGates struct {
	probe, describe                                    chan struct{}
	cleanup                                            chan struct{}
	probeEntered, describeEntered, cancelled, finished chan string
	fail                                               bool
}
type parallelTargetHarness struct {
	orchestratorHarness
	id    string
	gates *targetDiscoveryGates
}

func (h parallelTargetHarness) Descriptor() plugin.HarnessDescriptor {
	d := h.orchestratorHarness.Descriptor()
	d.ID = h.id
	d.DisplayName = h.id
	return d
}
func (h parallelTargetHarness) Probe(ctx context.Context, _ plugin.SettingsRequest, _ string) (plugin.Availability, error) {
	h.gates.probeEntered <- h.id
	select {
	case <-h.gates.probe:
		return plugin.Availability{Available: true}, nil
	case <-ctx.Done():
		h.gates.cancelled <- h.id
		<-h.gates.cleanup
		h.gates.finished <- h.id
		return plugin.Availability{}, ctx.Err()
	}
}
func (h parallelTargetHarness) Settings() plugin.HarnessSettings {
	return parallelTargetSettings{orchestratorSettings: orchestratorSettings{w: h.w}, id: h.id, gates: h.gates}
}

type parallelTargetSettings struct {
	orchestratorSettings
	id    string
	gates *targetDiscoveryGates
}

func (s parallelTargetSettings) Describe(ctx context.Context, r plugin.SettingsRequest) (json.RawMessage, error) {
	s.gates.describeEntered <- s.id
	select {
	case <-s.gates.describe:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { s.gates.finished <- s.id }()
	if s.gates.fail {
		return nil, errors.New("description failed: " + s.id)
	}
	return s.orchestratorSettings.Describe(ctx, r)
}
func replayOrchestratorParallelTargets() {
	ids := []string{"target-c", "target-a", "target-b"}
	build := func(fail bool) (*orchestratorWorld, *moku.Coordinator, []*targetDiscoveryGates) {
		w := newOrchestratorWorld()
		w.settings.Moku.HostHarnessPreference = "mock"
		w.settings.Moku.TargetHarnessIDs = ids
		cfg := w.config()
		gates := []*targetDiscoveryGates{}
		for _, id := range ids {
			gate := &targetDiscoveryGates{probe: make(chan struct{}), describe: make(chan struct{}), cleanup: make(chan struct{}), probeEntered: make(chan string, 1), describeEntered: make(chan string, 1), cancelled: make(chan string, 1), finished: make(chan string, 1), fail: fail}
			gates = append(gates, gate)
			cfg.Harnesses[id] = parallelTargetHarness{orchestratorHarness: orchestratorHarness{w: w}, id: id, gates: gate}
		}
		c, err := moku.New(cfg)
		mokuReplayMust(err)
		mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
		return w, c, gates
	}
	await := func(label string, channel <-chan string) string {
		select {
		case id := <-channel:
			return id
		case <-time.After(5 * time.Second):
			panic("timed out waiting for " + label)
		}
	}
	var previous string
	for _, order := range [][]int{{2, 1, 0}, {0, 1, 2}} {
		w, c, gates := build(false)
		done := make(chan error, 1)
		go func() { done <- c.Submit(mokuReplayContext(), orchestratorInput("parallel targets")) }()
		for i, gate := range gates {
			mokuReplayCheck(await("parallel probe", gate.probeEntered) == ids[i], "wrong target probe")
		}
		for _, gate := range gates {
			close(gate.probe)
		}
		for i, gate := range gates {
			mokuReplayCheck(await("parallel description", gate.describeEntered) == ids[i], "wrong target description")
		}
		for _, index := range order {
			close(gates[index].describe)
			await("ordered description completion", gates[index].finished)
		}
		mokuReplayMust(<-done)
		raw := w.binding("create_thread").InputSchema
		var schema map[string]any
		mokuReplayMust(json.Unmarshal(raw, &schema))
		options := schema["properties"].(map[string]any)["harnessId"].(map[string]any)["enum"].([]any)
		for i, id := range ids {
			mokuReplayCheck(options[i] == id, "target completion order changed configured order")
		}
		if previous != "" {
			mokuReplayCheck(string(raw) == previous, "completion order changed Moku tool schema")
		}
		previous = string(raw)
		stopOrchestrator(c)
	}
	// Complete later configured failures first; first configured error still wins.
	_, c, gates := build(true)
	done := make(chan error, 1)
	go func() { done <- c.Submit(mokuReplayContext(), orchestratorInput("parallel target errors")) }()
	for _, gate := range gates {
		await("error probe", gate.probeEntered)
		close(gate.probe)
	}
	for _, gate := range gates {
		await("error description", gate.describeEntered)
	}
	for _, i := range []int{2, 1, 0} {
		close(gates[i].describe)
		await("error completion", gates[i].finished)
	}
	err := <-done
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "description failed: target-c"), "discovery error followed completion order")
	stopOrchestrator(c)
	// Cancellation must join every native probe's cleanup before Submit or Stop.
	_, c, gates = build(false)
	ctx, cancel := context.WithCancel(mokuReplayContext())
	done = make(chan error, 1)
	go func() { done <- c.Submit(ctx, orchestratorInput("cancel all parallel probes")) }()
	for _, gate := range gates {
		await("cancellable probe", gate.probeEntered)
	}
	cancel()
	for _, gate := range gates {
		await("probe cancellation", gate.cancelled)
	}
	stopped := make(chan error, 1)
	go func() { stopped <- c.Stop(mokuReplayContext()) }()
	select {
	case <-done:
		panic("Submit detached target cleanup")
	case <-stopped:
		panic("Stop detached target cleanup")
	case <-time.After(30 * time.Millisecond):
	}
	for _, gate := range gates {
		close(gate.cleanup)
		await("probe cleanup", gate.finished)
	}
	mokuReplayCheck(errors.Is(<-done, context.Canceled), "parallel cancellation not returned")
	mokuReplayMust(<-stopped)
	fmt.Println("PASS parallel targets: simultaneous Probe/Describe, stable configured schema/error order, cancellation and Stop join native cleanup")
}
