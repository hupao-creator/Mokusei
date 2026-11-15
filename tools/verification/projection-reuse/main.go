// Command projection-reuse verifies that narrow reader scopes reuse one
// immutable Harness index across subscriptions and unrelated state changes.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

type productionHarness struct {
	plugin.Harness
	adapter plugin.SessionStateAdapter
}

func (h productionHarness) SessionState() plugin.SessionStateAdapter { return h.adapter }

type statsProvider interface {
	CacheStats() sessioncache.Stats
}

type fixture struct {
	name       string
	harnessID  string
	harness    plugin.Harness
	adapter    plugin.SessionStateAdapter
	stats      statsProvider
	newAdapter func() plugin.SessionStateAdapter
	target     string
	state      func(unrelated, body int, targetText string) json.RawMessage
}

func main() {
	unrelated := flag.Int("unrelated", 8, "number of unrelated executions")
	body := flag.Int("body", 256<<10, "total unrelated transcript bytes per state")
	largeEntry := flag.Bool("large-entry", false, "exercise a real reader entry larger than the old 64 MiB cap")
	flag.Parse()
	directory, err := os.MkdirTemp("", "mokusei-projection-reuse-")
	must(err)
	defer os.RemoveAll(directory)
	for _, f := range fixtures() {
		verifyFixture(directory, f, *unrelated, *body)
		measureReader(context.Background(), f, *unrelated, *body)
		if closer, ok := f.harness.(plugin.Closer); ok {
			must(closer.Close())
		}
	}
	if *largeEntry {
		verifyLargeEntry(context.Background(), piFixture())
	}
	verifyHistoryEquivalence(context.Background())
	fmt.Println("PASS cold index build, same-version reuse, metadata-only no-op, unrelated execution no-op, visible target update, concurrent scope isolation, cross-Thread isolation, cancellation and deletion eviction")
}

func claudeFixture() fixture {
	harness := claude.New(plugin.HostContext{})
	return fixture{
		name: "claude", harnessID: "claude", harness: harness, adapter: harness.SessionState(),
		stats: harness.SessionState().(statsProvider), newAdapter: func() plugin.SessionStateAdapter { return claude.NewStateAdapter() }, target: "target",
		state: func(unrelated, body int, targetText string) json.RawMessage {
			state := claude.NewState()
			add := func(id, text string, at int64) {
				turn := state.NewTurn(id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt " + id}}}, claude.Settings{})
				turn.Text = text
				turn.Status = "completed"
				turn.CreatedAt, turn.UpdatedAt = at, at
				finished := at + 2
				turn.FinishedAt = &finished
				turn.Timeline = []map[string]any{{"id": id + ":answer", "kind": "assistant", "content": text, "status": "complete", "createdAt": at}}
			}
			add("target", targetText, 1)
			for i := 0; i < unrelated; i++ {
				add(fmt.Sprintf("other-%d", i), unrelatedText(body, unrelated), int64(10+i*5))
			}
			raw, err := state.Encode()
			must(err)
			return raw
		},
	}
}

func codexFixture() fixture {
	harness := codex.New(plugin.HostContext{})
	return fixture{
		name: "codex", harnessID: "codex", harness: harness, adapter: harness.SessionState(),
		stats: harness.SessionState().(statsProvider), newAdapter: codex.NewSessionStateAdapter, target: "turn:target",
		state: func(unrelated, body int, targetText string) json.RawMessage {
			state := codex.EmptyState(1)
			add := func(id, text string, at int64) {
				state = codex.StageExecution(state, id, codex.Map{"parts": []any{codex.Map{"kind": "text", "text": "prompt " + id}}}, at, nil)
				state = codex.ReduceEvent(state, id, codex.Map{"type": "text-final", "itemId": id + "-answer", "text": text, "at": at + 1})
				state = codex.SettleExecution(state, id, "completed", at+2, "")
			}
			add("target", targetText, 2)
			for i := 0; i < unrelated; i++ {
				add(fmt.Sprintf("other-%d", i), unrelatedText(body, unrelated), int64(10+i*5))
			}
			// Real stEditTurn advances the Thread-level timestamp for any
			// execution event. The target turn stays at its own fixed time.
			state["updatedAt"] = int64(1000 + body)
			return encode(state)
		},
	}
}

func piFixture() fixture {
	harness := pi.New(plugin.HostContext{})
	return fixture{
		name: "pi", harnessID: "pi", harness: harness, adapter: harness.SessionState(),
		stats: harness.SessionState().(statsProvider), newAdapter: func() plugin.SessionStateAdapter { return pi.New(plugin.HostContext{}).SessionState() }, target: "target",
		state: func(unrelated, body int, targetText string) json.RawMessage {
			state := pi.State{Version: 1, Messages: []pi.MessageState{}, Executions: []model.PublicExecution{}, NativeSessionJSONL: strings.Repeat("n", body)}
			add := func(id, text string, at int64) {
				state.Messages = append(state.Messages,
					pi.MessageState{ID: id + "-user", ExecutionID: id, Role: "user", Text: "prompt " + id, CreatedAt: at},
					pi.MessageState{ID: id + "-assistant", ExecutionID: id, Role: "assistant", Text: text, Status: "complete"},
				)
				finished := at + 2
				state.Executions = append(state.Executions, model.PublicExecution{ExecutionID: id, Status: "completed", StartedAt: at, FinishedAt: &finished})
			}
			add("target", targetText, 1)
			for i := 0; i < unrelated; i++ {
				add(fmt.Sprintf("other-%d", i), unrelatedText(body, unrelated), int64(10+i*5))
			}
			latest := fmt.Sprintf("other-%d", max(0, unrelated-1))
			if unrelated == 0 {
				latest = "target"
			}
			state.LatestExecutionID = &latest
			state.ExecutionAuthors = map[string]json.RawMessage{"target": encode(map[string]string{"model": "target-model"})}
			for i := 0; i < unrelated; i++ {
				state.ExecutionAuthors[fmt.Sprintf("other-%d", i)] = encode(map[string]string{"model": "other-model"})
			}
			return encode(state)
		},
	}
}

func opencodeFixture() fixture {
	harness := opencode.New(plugin.HostContext{})
	return fixture{
		name: "opencode", harnessID: "opencode", harness: harness, adapter: harness.SessionState(),
		stats: harness.SessionState().(statsProvider), newAdapter: func() plugin.SessionStateAdapter { return opencode.NewStateAdapter() }, target: "target",
		state: func(unrelated, body int, targetText string) json.RawMessage {
			state := &opencode.State{Version: 1, Messages: []*opencode.Message{}, Executions: []*model.PublicExecution{}, Interactions: []*opencode.Interaction{}}
			add := func(id, text string, at int64) {
				state.Messages = append(state.Messages,
					&opencode.Message{ID: id + "-user", ExecutionID: id, Role: "user", Text: "prompt " + id, CreatedAt: at},
					&opencode.Message{ID: id + "-assistant", ExecutionID: id, Role: "assistant", Status: "complete", Parts: []opencode.Part{{Type: "text", Text: text}}},
				)
				must(state.Begin(id, at))
				state.Settle(id, "completed", at+2, "")
			}
			add("target", targetText, 1)
			for i := 0; i < unrelated; i++ {
				add(fmt.Sprintf("other-%d", i), unrelatedText(body, unrelated), int64(10+i*5))
			}
			return state.Encode()
		},
	}
}

func verifyFixture(directory string, f fixture, unrelated, body int) {
	ctx := context.Background()
	dir := filepath.Join(directory, f.name)
	must(os.MkdirAll(dir, 0o700))
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	must(err)
	defer db.Close()
	record := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: f.harnessID, Revision: 1, SessionState: f.state(unrelated, body, "target-answer"), Settings: json.RawMessage(`{}`), CreatedAt: 1, UpdatedAt: 1}, Title: "thread", Tags: []string{}, TagEmojis: map[string]string{}}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("thread:"+record.ID, record); err != nil {
			return err
		}
		return tx.SetOrder("threads", []string{record.ID})
	})
	must(err)
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{f.harnessID: productionHarness{Harness: f.harness, adapter: f.adapter}}, DataDir: dir})
	must(err)
	defer r.Close(ctx)
	if initial := f.stats.CacheStats(); initial.IndexBuilds == 0 {
		panic(f.name + ": catalog overview did not use the reader adapter")
	}
	verifyCatalogOverview(ctx, r, f, record)
	verifyScopeEquivalence(ctx, f)
	if reader, ok := f.adapter.(plugin.ReaderProjectionAdapter); ok {
		reader.EvictThread(record.ID)
	}
	scope := transport.ContentScope{Kind: "execution", Key: f.target}
	before := f.stats.CacheStats()
	coldDuration := measure(func() {
		snapshot, err := r.ReadThreadContent(ctx, record.ID, scope, nil)
		must(err)
		if snapshot == nil || !bytes.Contains(snapshot.Value, []byte("target-answer")) {
			panic(f.name + ": cold execution projection missing target content")
		}
		fmt.Printf("%s cold bytes=%d\n", f.name, len(snapshot.Value))
	})
	cold := diff(f.stats.CacheStats(), before)
	check(cold.IndexBuilds == 1 && cold.ProjectionBuilds == 1, f.name+": cold read did not build one index and projection")

	snapshot, err := r.ReadThreadContent(ctx, record.ID, scope, nil)
	must(err)
	known := snapshot.Revision
	if _, err := r.ReadThreadContent(ctx, record.ID, transport.ContentScope{Kind: "overview"}, nil); err != nil {
		panic(f.name + ": overview warm read failed: " + err.Error())
	}
	before = f.stats.CacheStats()
	sameDuration := measure(func() {
		again, err := r.ReadThreadContent(ctx, record.ID, scope, &known)
		must(err)
		if again != nil {
			panic(f.name + ": same content revision emitted a snapshot")
		}
	})
	same := diff(f.stats.CacheStats(), before)
	check(same.IndexBuilds == 0 && same.ProjectionBuilds == 0, f.name+": same-version read rebuilt parsing")

	must(r.UpdateThread(ctx, record.ID, func(t *model.ThreadRecord) error { t.Title = "metadata-only"; return nil }))
	before = f.stats.CacheStats()
	settlePublication(r)
	catalogMetadata := diff(f.stats.CacheStats(), before)
	check(catalogMetadata.IndexBuilds == 0 && catalogMetadata.ProjectionBuilds == 0, fmt.Sprintf("%s: metadata update rebuilt catalog overview: %+v", f.name, catalogMetadata))
	before = f.stats.CacheStats()
	metadataDuration := measure(func() {
		again, err := r.ReadThreadContent(ctx, record.ID, scope, &known)
		must(err)
		if again != nil {
			panic(f.name + ": metadata update emitted unchanged content")
		}
	})
	metadata := diff(f.stats.CacheStats(), before)
	check(metadata.IndexBuilds == 0 && metadata.ProjectionBuilds == 0, f.name+": metadata update rebuilt content")

	must(r.UpdateThread(ctx, record.ID, func(t *model.ThreadRecord) error {
		t.SessionState = f.state(unrelated, body*2, "target-answer")
		return nil
	}))
	settlePublication(r)
	before = f.stats.CacheStats()
	unrelatedDuration := measure(func() {
		again, err := r.ReadThreadContent(ctx, record.ID, scope, &known)
		must(err)
		if again != nil {
			panic(f.name + ": unrelated execution update emitted target snapshot")
		}
	})
	unrelatedStats := diff(f.stats.CacheStats(), before)
	check(unrelatedStats.ProjectionBuilds == 0, fmt.Sprintf("%s: unrelated update rebuilt target projection: %+v", f.name, unrelatedStats))

	must(r.UpdateThread(ctx, record.ID, func(t *model.ThreadRecord) error {
		t.SessionState = f.state(unrelated, body*2, "target-answer-updated")
		return nil
	}))
	settlePublication(r)
	before = f.stats.CacheStats()
	var targetRevision int64
	targetDuration := measure(func() {
		updated, err := r.ReadThreadContent(ctx, record.ID, scope, &known)
		must(err)
		if updated == nil || !bytes.Contains(updated.Value, []byte("target-answer-updated")) {
			panic(f.name + ": visible target update was not delivered")
		}
		targetRevision = updated.Revision
	})
	target := diff(f.stats.CacheStats(), before)
	check(target.ProjectionBuilds == 1, f.name+": visible target update did not rebuild one projection")
	again, err := r.ReadThreadContent(ctx, record.ID, scope, &targetRevision)
	must(err)
	check(again == nil, f.name+": updated revision was not skipped")

	verifyConcurrentScopes(ctx, r, f, record.ID)
	verifyCrossThread(ctx, db, r, f, dir)

	before = f.stats.CacheStats()
	metadataOnly := f.state(unrelated, body*2, "target-answer-updated")
	must(r.UpdateThread(ctx, record.ID, func(t *model.ThreadRecord) error { t.SessionState = metadataOnly; t.Title = "title-again"; return nil }))
	_, err = r.ReadThreadContent(ctx, record.ID, scope, &targetRevision)
	must(err)

	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := r.ReadThreadContent(cancelled, record.ID, scope, nil); err == nil {
		panic(f.name + ": canceled content read succeeded")
	}
	if recovered, err := r.ReadThreadContent(ctx, record.ID, scope, nil); err != nil || recovered == nil {
		panic(f.name + ": cancellation poisoned later reads")
	}

	interleaved(ctx, f, "target-answer", "target-answer-interleaved")
	fmt.Printf("%s cold=%s same=%s metadata=%s unrelated=%s target=%s builds[coldIndex=%d coldProjection=%d same=%d metadata=%d unrelatedIndex=%d unrelatedProjection=%d targetProjection=%d] cache=%dB threads=%d\n",
		f.name,
		coldDuration.Round(time.Microsecond), sameDuration.Round(time.Microsecond), metadataDuration.Round(time.Microsecond), unrelatedDuration.Round(time.Microsecond), targetDuration.Round(time.Microsecond), cold.IndexBuilds, cold.ProjectionBuilds, same.IndexBuilds+same.ProjectionBuilds,
		metadata.IndexBuilds+metadata.ProjectionBuilds, unrelatedStats.IndexBuilds, unrelatedStats.ProjectionBuilds,
		target.ProjectionBuilds, f.stats.CacheStats().Bytes, f.stats.CacheStats().Threads,
	)
	must(r.ClearHistory(ctx))
	if stats := f.stats.CacheStats(); stats.Threads > 1 {
		panic(f.name + ": history reset retained old reader Threads")
	}
}

func fixtures() []fixture {
	return []fixture{claudeFixture(), codexFixture(), piFixture(), opencodeFixture()}
}

func verifyCatalogOverview(ctx context.Context, r *core.Runtime, f fixture, record model.ThreadRecord) {
	snapshot, err := r.Snapshot()
	must(err)
	var projected json.RawMessage
	for _, thread := range snapshot.Threads {
		if thread.ID == record.ID {
			projected = thread.SessionState
			break
		}
	}
	if projected == nil {
		panic(f.name + ": catalog overview missing Thread")
	}
	reader := f.adapter.(plugin.ReaderProjectionAdapter)
	result, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: record.ID, ContentID: sessioncache.Identity(record.SessionState), State: record.SessionState, Scope: model.RendererScope{Kind: "overview"}, Generation: 1})
	must(err)
	if result == nil || !equivalentProjection(f.name, projected, result.Value) {
		panic(f.name + ": catalog overview differs from ReaderProjectionAdapter")
	}
}

func verifyLargeEntry(ctx context.Context, f fixture) {
	state := f.state(0, 70<<20, "target-answer")
	adapter := f.newAdapter()
	reader := adapter.(plugin.ReaderProjectionAdapter)
	result, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "large", ContentID: sessioncache.Identity(state), State: state, Scope: model.RendererScope{Kind: "overview"}, Generation: 1})
	must(err)
	if result == nil {
		panic(f.name + ": large overview projection missing")
	}
	stats := adapter.(statsProvider).CacheStats()
	if stats.RetainedBytes < 64<<20 || stats.RetainedThreads != 1 {
		panic(f.name + ": large entry was not retained above the old 64 MiB cap")
	}
	fmt.Printf("%s reader large-entry retained=%dB live=%dB\n", f.name, stats.RetainedBytes, stats.LiveBytes)
	reader.EvictThread("large")
}

func verifyHistoryEquivalence(ctx context.Context) {
	claudeState := claude.NewState()
	claudeTurn := claudeState.NewTurn("target", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, claude.Settings{})
	claudeTurn.Text = "answer"
	claudeTurn.Status = "completed"
	finished := claudeTurn.UpdatedAt
	claudeTurn.FinishedAt = &finished
	claudeState.ForkHistory = map[string]any{"sourceSessionId": "source", "items": []any{
		map[string]any{"id": "prompt", "kind": "user-message", "content": "prompt", "createdAt": 1},
		map[string]any{"id": "plan", "kind": "plan", "plan": []any{map[string]any{"step": "hidden"}}, "createdAt": 2},
	}}
	claudeRaw, err := claudeState.Encode()
	must(err)
	checkReaderEquivalence(ctx, "claude-history", claude.NewStateAdapter(), claudeRaw, model.RendererScope{Kind: "execution", Key: "fork-history"}, model.RendererScope{Kind: "turn", Key: "fork-history"})

	opencodeState := &opencode.State{Version: 1, NativeSessionID: "ses_target", Messages: []*opencode.Message{
		{ID: "inherited-user", ExecutionID: "old", Role: "user", Text: "prompt", Inherited: true},
		{ID: "inherited-assistant", ExecutionID: "old", Role: "assistant", Status: "complete", Inherited: true, Parts: []opencode.Part{{Type: "text", Text: "answer"}}},
	}, Executions: []*model.PublicExecution{}, Interactions: []*opencode.Interaction{}, ForkSource: &opencode.ForkSource{SessionID: "source", Transcript: opencode.Object{}}}
	opencodeRaw := opencodeState.Encode()
	checkReaderEquivalence(ctx, "opencode-history", opencode.NewStateAdapter(), opencodeRaw, model.RendererScope{Kind: "execution", Key: "opencode-fork-history"}, model.RendererScope{Kind: "turn", Key: "opencode-fork-history"})

	codexCurrent := codex.EmptyState(1)
	codexCurrent = codex.StageExecution(codexCurrent, "target", codex.Map{"parts": []any{codex.Map{"kind": "text", "text": "prompt"}}}, 2, nil)
	codexCurrent = codex.ReduceEvent(codexCurrent, "target", codex.Map{"type": "text-final", "itemId": "answer", "text": "answer", "at": 3})
	codexCurrent = codex.SettleExecution(codexCurrent, "target", "completed", 4, "")
	codexHistory := codex.EmptyState(7)
	codexHistory["forkHistory"] = codexCurrent["turns"]
	codexRaw := encode(codexHistory)
	checkReaderEquivalence(ctx, "codex-history", codex.NewSessionStateAdapter(), codexRaw, model.RendererScope{Kind: "execution", Key: "turn:target"}, model.RendererScope{Kind: "turn", Key: "turn:target"})
}

func equivalentProjection(name string, full, reader json.RawMessage) bool {
	if !strings.HasPrefix(name, "codex") {
		return bytes.Equal(full, reader)
	}
	var left, right map[string]any
	if json.Unmarshal(full, &left) != nil || json.Unmarshal(reader, &right) != nil {
		return false
	}
	// Narrow Codex states normalize the Thread-level timestamp to the target
	// execution and retained global facts; all other fields must match.
	leftState, rightState := left, right
	if left["kind"] == "deferred-execution" {
		leftState, _ = left["state"].(map[string]any)
		rightState, _ = right["state"].(map[string]any)
	}
	if leftState == nil || rightState == nil {
		return false
	}
	leftState["updatedAt"] = rightState["updatedAt"]
	normalized, err := json.Marshal(left)
	if err != nil {
		return false
	}
	return bytes.Equal(normalized, reader)
}

func checkReaderEquivalence(ctx context.Context, name string, adapter plugin.SessionStateAdapter, state json.RawMessage, scopes ...model.RendererScope) {
	reader := adapter.(plugin.ReaderProjectionAdapter)
	reader.EvictThread(name)
	defer reader.EvictThread(name)
	for _, scope := range scopes {
		full, err := adapter.ProjectRenderer(state, scope)
		must(err)
		snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: name, ContentID: sessioncache.Identity(state), State: state, Scope: scope})
		must(err)
		if snapshot == nil || !equivalentProjection(name, full, snapshot.Value) {
			panic(name + ": scoped history projection differs from the production full-scope projection")
		}
	}
}

func verifyScopeEquivalence(ctx context.Context, f fixture) {
	reader := f.adapter.(plugin.ReaderProjectionAdapter)
	for _, state := range []json.RawMessage{f.state(8, 256<<10, "target-answer"), f.state(0, 0, "target-answer")} {
		reader.EvictThread("equivalence")
		for _, scope := range []model.RendererScope{{Kind: "execution", Key: f.target}, {Kind: "turn", Key: f.target}} {
			full, err := f.adapter.ProjectRenderer(state, scope)
			must(err)
			snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "equivalence", ContentID: sessioncache.Identity(state), State: state, Scope: scope})
			must(err)
			if snapshot == nil || !equivalentProjection(f.name, full, snapshot.Value) {
				panic(f.name + ": scoped reader projection differs from the production full-scope projection for " + scope.Kind)
			}
		}
	}
	reader.EvictThread("equivalence")
}

func verifyConcurrentScopes(ctx context.Context, r *core.Runtime, f fixture, threadID string) {
	scopes := []transport.ContentScope{{Kind: "overview"}, {Kind: "execution", Key: f.target}, {Kind: "thread"}}
	sequential := make([][]byte, len(scopes))
	for i, scope := range scopes {
		snapshot, err := r.ReadThreadContent(ctx, threadID, scope, nil)
		must(err)
		sequential[i] = bytes.Clone(snapshot.Value)
	}
	concurrent := make([][]byte, len(scopes))
	var group sync.WaitGroup
	for i, scope := range scopes {
		i, scope := i, scope
		group.Add(1)
		go func() {
			defer group.Done()
			snapshot, err := r.ReadThreadContent(ctx, threadID, scope, nil)
			if err != nil {
				panic(err)
			}
			concurrent[i] = bytes.Clone(snapshot.Value)
		}()
	}
	group.Wait()
	for i := range scopes {
		if !bytes.Equal(sequential[i], concurrent[i]) {
			panic(f.name + ": concurrent scope projection changed another reader's output")
		}
	}
}

func verifyCrossThread(ctx context.Context, db *store.Store, r *core.Runtime, f fixture, directory string) {
	second := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "second", HarnessID: f.harnessID, Revision: 1, SessionState: f.state(2, 4096, "second-target"), Settings: json.RawMessage(`{}`), CreatedAt: 1, UpdatedAt: 1}, Title: "second", Tags: []string{}, TagEmojis: map[string]string{}}
	_, err := db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("thread:"+second.ID, second); err != nil {
			return err
		}
		return tx.SetOrder("threads", []string{"thread", second.ID})
	})
	must(err)
	first, err := r.ReadThreadContent(ctx, "thread", transport.ContentScope{Kind: "execution", Key: f.target}, nil)
	must(err)
	other, err := r.ReadThreadContent(ctx, "second", transport.ContentScope{Kind: "execution", Key: f.target}, nil)
	must(err)
	if !bytes.Contains(first.Value, []byte("target-answer")) || !bytes.Contains(other.Value, []byte("second-target")) || bytes.Contains(first.Value, []byte("second-target")) {
		panic(f.name + ": Thread reader cache crossed session identities")
	}
	before := f.stats.CacheStats().Threads
	must(r.DeleteThread(ctx, "second"))
	after := f.stats.CacheStats().Threads
	if after >= before {
		panic(f.name + ": deletion did not evict the Thread reader generation")
	}
	_ = directory
}

func interleaved(ctx context.Context, f fixture, firstText, secondText string) {
	first := f.state(2, 4096, firstText)
	second := f.state(2, 4096, secondText)
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		i := i
		group.Add(1)
		go func() {
			defer group.Done()
			state, expected := first, firstText
			if i%2 == 1 {
				state, expected = second, secondText
			}
			reader := f.adapter.(plugin.ReaderProjectionAdapter)
			snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "interleaved", ContentID: sessioncache.Identity(state), State: state, Scope: model.RendererScope{Kind: "execution", Key: f.target}})
			if err != nil {
				panic(err)
			}
			if snapshot == nil || !bytes.Contains(snapshot.Value, []byte(expected)) {
				panic(f.name + ": concurrent content versions crossed reader values")
			}
		}()
	}
	group.Wait()
	evict, ok := f.adapter.(plugin.ReaderProjectionAdapter)
	if ok {
		evict.EvictThread("interleaved")
	}
}

func measureReader(ctx context.Context, f fixture, unrelated, body int) {
	adapter := f.newAdapter()
	reader := adapter.(plugin.ReaderProjectionAdapter)
	stats := adapter.(statsProvider)
	scope := model.RendererScope{Kind: "execution", Key: f.target}
	state := f.state(unrelated, body, "target-answer")
	contentID := sessioncache.Identity(state)
	verifyCanceledReader(ctx, f, state, contentID, scope)
	before := stats.CacheStats()
	var coldRevision int64
	var wire int
	coldDuration := measure(func() {
		snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "reader", ContentID: contentID, State: state, Scope: scope, Generation: 1})
		must(err)
		if snapshot == nil {
			panic(f.name + ": reader cold projection missing")
		}
		coldRevision, wire = snapshot.Revision, len(snapshot.Value)
	})
	cold := diff(stats.CacheStats(), before)
	sharedScopes := []model.RendererScope{{Kind: "overview"}, {Kind: "thread"}, {Kind: "turn", Key: f.target}}
	sharedRevisions := make([]int64, len(sharedScopes))
	before = stats.CacheStats()
	for i, shared := range sharedScopes {
		snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "reader", ContentID: contentID, State: state, Scope: shared, Generation: 2})
		must(err)
		if snapshot == nil {
			panic(f.name + ": shared scope projection missing")
		}
		sharedRevisions[i] = snapshot.Revision
	}
	shared := diff(stats.CacheStats(), before)
	check(shared.IndexBuilds == 0 && shared.ProjectionBuilds == int64(len(sharedScopes)), f.name+": shared scopes did not reuse one index")
	before = stats.CacheStats()
	for i, shared := range sharedScopes {
		snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "reader", ContentID: contentID, State: state, Scope: shared, Known: &sharedRevisions[i], Generation: 2})
		must(err)
		if snapshot != nil {
			panic(f.name + ": repeated shared scope emitted unchanged projection")
		}
	}
	sharedRepeat := diff(stats.CacheStats(), before)
	check(sharedRepeat.IndexBuilds == 0 && sharedRepeat.ProjectionBuilds == 0, f.name+": repeated shared scope rebuilt")
	before = stats.CacheStats()
	sameDuration := measure(func() {
		snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "reader", ContentID: contentID, State: state, Scope: scope, Known: &coldRevision, Generation: 2})
		must(err)
		if snapshot != nil {
			panic(f.name + ": reader repeated unchanged projection")
		}
	})
	same := diff(stats.CacheStats(), before)
	unrelatedState := f.state(unrelated, body*2, "target-answer")
	if f.name == "codex" {
		var before, after map[string]any
		if json.Unmarshal(state, &before) != nil || json.Unmarshal(unrelatedState, &after) != nil || before["updatedAt"] == after["updatedAt"] {
			panic("codex fixture did not advance the Thread timestamp for an unrelated execution")
		}
	}
	unrelatedID := sessioncache.Identity(unrelatedState)
	before = stats.CacheStats()
	unrelatedDuration := measure(func() {
		snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "reader", ContentID: unrelatedID, State: unrelatedState, Scope: scope, Known: &coldRevision, Generation: 3})
		must(err)
		if snapshot != nil {
			panic(f.name + ": reader emitted unrelated update")
		}
	})
	unrelatedStats := diff(stats.CacheStats(), before)
	updated := f.state(unrelated, body*2, "target-answer-updated")
	updatedID := sessioncache.Identity(updated)
	before = stats.CacheStats()
	var updatedRevision int64
	targetDuration := measure(func() {
		snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "reader", ContentID: updatedID, State: updated, Scope: scope, Known: &coldRevision, Generation: 4})
		must(err)
		if snapshot == nil || !bytes.Contains(snapshot.Value, []byte("target-answer-updated")) {
			panic(f.name + ": reader did not deliver visible target update")
		}
		updatedRevision = snapshot.Revision
	})
	target := diff(stats.CacheStats(), before)
	bounds := verifyReaderBounds(ctx, f, state, contentID, scope)
	check(cold.IndexBuilds == 1 && cold.ProjectionBuilds == 1, f.name+": reader cold build count mismatch")
	check(same.IndexBuilds == 0 && same.ProjectionBuilds == 0, f.name+": reader same-version build count mismatch")
	check(unrelatedStats.IndexBuilds == 1 && unrelatedStats.ProjectionBuilds == 0, f.name+": reader unrelated build count mismatch")
	check(target.ProjectionBuilds == 1, f.name+": reader target build count mismatch")
	_ = updatedRevision
	fmt.Printf("%s reader cold=%s same=%s unrelated=%s target=%s builds[cold=%d same=%d sharedIndex=%d sharedProjection=%d sharedRepeat=%d unrelatedIndex=%d unrelatedProjection=%d target=%d] wire=%dB cache=%dB\n",
		f.name,
		coldDuration.Round(time.Microsecond), sameDuration.Round(time.Microsecond), unrelatedDuration.Round(time.Microsecond), targetDuration.Round(time.Microsecond), cold.IndexBuilds+cold.ProjectionBuilds, same.IndexBuilds+same.ProjectionBuilds,
		shared.IndexBuilds, shared.ProjectionBuilds, sharedRepeat.IndexBuilds+sharedRepeat.ProjectionBuilds,
		unrelatedStats.IndexBuilds, unrelatedStats.ProjectionBuilds, target.ProjectionBuilds,
		wire, stats.CacheStats().Bytes,
	)
	fmt.Printf("%s reader bounds cache=%dB threads=%d\n", f.name, bounds.Bytes, bounds.Threads)
	reader.EvictThread("reader")
	inuse, alloc, sys := heapSnapshot()
	fmt.Printf("%s reader heap[inuse=%d alloc=%d sys=%d]\n", f.name, inuse, alloc, sys)
}

func verifyCanceledReader(ctx context.Context, f fixture, state json.RawMessage, contentID string, scope model.RendererScope) {
	adapter := f.newAdapter()
	reader := adapter.(plugin.ReaderProjectionAdapter)
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	start := time.Now()
	_, err := reader.ProjectReader(cancelled, plugin.ReaderRequest{ThreadID: "cancelled", ContentID: contentID, State: state, Scope: scope, Generation: 1})
	if !errors.Is(err, context.Canceled) {
		panic(f.name + ": canceled reader did not return context cancellation")
	}
	if elapsed := time.Since(start); elapsed > 200*time.Millisecond {
		panic(f.name + ": canceled reader scanned a large state")
	}
	reader.EvictThread("cancelled")
}

func verifyReaderBounds(ctx context.Context, f fixture, state json.RawMessage, contentID string, scope model.RendererScope) sessioncache.Stats {
	stats := f.newAdapter()
	reader := stats.(plugin.ReaderProjectionAdapter)
	for i := 0; i < 96; i++ {
		key := fmt.Sprintf("other-%d", i)
		_, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "bounds", ContentID: contentID, State: state, Scope: model.RendererScope{Kind: "turn", Key: key}, Generation: int64(i + 1)})
		must(err)
	}
	small := f.state(0, 0, "target-answer")
	smallID := sessioncache.Identity(small)
	for i := 0; i < 300; i++ {
		_, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: fmt.Sprintf("empty-%d", i), ContentID: smallID, State: small, Scope: scope, Generation: 1})
		must(err)
	}
	result := stats.(statsProvider).CacheStats()
	check(result.Bytes <= sessioncache.DefaultBudget, f.name+": reader cache exceeded byte budget")
	check(result.Threads <= 256, f.name+": reader cache exceeded Thread cap")
	reader.EvictThread("bounds")
	for i := 0; i < 300; i++ {
		reader.EvictThread(fmt.Sprintf("empty-%d", i))
	}
	return result
}

func settlePublication(r *core.Runtime) {
	r.Publish()
	// Let the store's coalescing publisher timer pass so it cannot overlap the
	// next isolated reader measurement.
	time.Sleep(60 * time.Millisecond)
	r.Publish()
}

func measure(run func()) time.Duration {
	start := time.Now()
	run()
	return time.Since(start)
}

func heapSnapshot() (inuse, alloc, sys uint64) {
	goruntime.GC()
	var stats goruntime.MemStats
	goruntime.ReadMemStats(&stats)
	return stats.HeapInuse, stats.HeapAlloc, stats.Sys
}

func diff(after, before sessioncache.Stats) sessioncache.Stats {
	return sessioncache.Stats{
		IndexBuilds: after.IndexBuilds - before.IndexBuilds, IndexHits: after.IndexHits - before.IndexHits,
		ProjectionBuilds: after.ProjectionBuilds - before.ProjectionBuilds, ProjectionHits: after.ProjectionHits - before.ProjectionHits,
		Bytes: after.Bytes - before.Bytes, Threads: after.Threads - before.Threads,
	}
}

func unrelatedText(body, unrelated int) string {
	length := max(1, body/max(1, unrelated))
	return strings.Repeat("u", length) + fmt.Sprintf(":v%d", length)
}

func encode(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	must(err)
	return raw
}

func check(condition bool, message string) {
	if !condition {
		panic(message)
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
