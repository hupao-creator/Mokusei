package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

const streamFragment = "0123456789abcdef0123456789abcdef"
const streamAnswer = "Stream fixture complete"

type streamStore struct {
	mu                                   sync.Mutex
	state                                json.RawMessage
	commits                              int
	bytes                                int64
	statusOnly                           int
	lastReasoning, lastAnswer, lastLabel string
	sawPlanning, resumedAnalysis         bool
	inspectStatus                        bool
	reject                               error
	rejected                             chan struct{}
	finished                             chan struct{}
	once                                 sync.Once
}

func (s *streamStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage{}, s.state...)
}

func (s *streamStore) Commit(_ context.Context, raw json.RawMessage) error {
	s.mu.Lock()
	if s.reject != nil {
		err := s.reject
		if s.rejected != nil {
			close(s.rejected)
			s.rejected = nil
		}
		s.mu.Unlock()
		return err
	}
	s.mu.Unlock()
	// Exercise the production public projection for every durable version, as
	// Runtime does; this fixture intentionally excludes SQLite and publication.
	observation, err := codex.NewSessionStateAdapter().Project(raw)
	if err != nil {
		return err
	}
	s.mu.Lock()
	if s.inspectStatus {
		current := codex.LatestTurn(decoded(raw))
		reasoning, answer, label := text(current["reasoning"]), text(current["answer"]), text(current["statusLabel"])
		if current["status"] == "running" && label == "正在分析" && s.lastLabel == label && reasoning != "" && reasoning == s.lastReasoning && answer == s.lastAnswer {
			s.statusOnly++
		}
		if label == "正在制定计划" {
			s.sawPlanning = true
		}
		if s.sawPlanning && label == "正在分析" {
			s.resumedAnalysis = true
		}
		s.lastReasoning, s.lastAnswer, s.lastLabel = reasoning, answer, label
	}
	s.commits++
	s.bytes += int64(len(raw))
	s.state = append(json.RawMessage{}, raw...)
	s.mu.Unlock()
	if observation.LatestExecution != nil && observation.LatestExecution.Terminal() {
		s.once.Do(func() { close(s.finished) })
	}
	return nil
}

type streamSample struct {
	Kind                  string  `json:"kind"`
	Sample                int     `json:"sample"`
	Chunks                int     `json:"chunks"`
	MeasuredChunks        int     `json:"measuredChunks"`
	FragmentBytes         int     `json:"fragmentBytes"`
	WallMS                float64 `json:"wallMs"`
	ParentUserCPUMS       float64 `json:"parentUserCpuMs"`
	ParentSystemCPUMS     float64 `json:"parentSystemCpuMs"`
	ParentAllocatedBytes  uint64  `json:"parentAllocatedBytes"`
	ParentAllocations     uint64  `json:"parentAllocations"`
	Commits               int     `json:"commits"`
	CommittedBytes        int64   `json:"committedBytes"`
	RepeatedStatusCommits int     `json:"-"`
	ResumedAnalysis       bool    `json:"-"`
	FinalStateSHA256      string  `json:"finalStateSha256"`
}

func runStreamPerformance(ctx context.Context, root, binary string, chunks, repeats int) error {
	if chunks < 2 || chunks > 1024 || repeats < 1 || repeats > 20 {
		return fmt.Errorf("stream performance requires 2..1024 chunks and 1..20 repeats")
	}
	for _, kind := range []string{"reasoning", "text"} {
		for i := 1; i <= repeats; i++ {
			sample, err := runStreamSample(ctx, filepath.Join(root, fmt.Sprintf("%s-%d", kind, i)), binary, kind, chunks, false, false, false)
			if err != nil {
				return err
			}
			sample.Sample = i
			if err := json.NewEncoder(os.Stdout).Encode(sample); err != nil {
				return err
			}
		}
	}
	return nil
}

func verifyStreaming(ctx context.Context, root, binary string) error {
	for _, kind := range []string{"reasoning", "text"} {
		for _, interrupted := range []bool{false, true} {
			name := fmt.Sprintf("%s-interrupted-%t", kind, interrupted)
			sample, err := runStreamSample(ctx, filepath.Join(root, name), binary, kind, 64, interrupted, true, false)
			if err != nil {
				return err
			}
			if kind == "reasoning" && sample.RepeatedStatusCommits != 0 {
				return fmt.Errorf("reasoning repeated its durable analysis status %d times", sample.RepeatedStatusCommits)
			}
			if kind == "reasoning" && !sample.ResumedAnalysis {
				return fmt.Errorf("reasoning did not resume its analysis status after native planning")
			}
		}
	}
	if _, err := runStreamSample(ctx, filepath.Join(root, "failed-flush"), binary, "reasoning", 64, true, false, true); err != nil {
		return err
	}
	fmt.Println("PASS native JSONL stream batching / analysis status transitions / terminal and interrupt content / failed flush close error")
	return nil
}

func runStreamSample(ctx context.Context, root, binary, kind string, chunks int, interrupted, inspectStatus, rejectFlush bool) (sample streamSample, err error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	env, err := isolatedEnvironment(root)
	if err != nil {
		return sample, err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	env["MOKUSEI_CODEX_REPLAY_STREAM_KIND"] = kind
	env["MOKUSEI_CODEX_REPLAY_STREAM_CHUNKS"] = strconv.Itoa(chunks)
	env["MOKUSEI_CODEX_REPLAY_STREAM_INTERRUPT"] = strconv.FormatBool(interrupted)
	env["MOKUSEI_CODEX_REPLAY_STREAM_INSPECT"] = strconv.FormatBool(inspectStatus)
	adapter := codex.New(host(root, env))
	flushFailure := errors.New("fixture streaming commit rejected")
	expectedCloseFailure := false
	defer func() {
		closeErr := adapter.Close()
		if !expectedCloseFailure || !onlyStreamFailure(closeErr, flushFailure) {
			err = errors.Join(err, closeErr)
		}
	}()
	store := &streamStore{finished: make(chan struct{}), inspectStatus: inspectStatus}
	settings := object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "ask-for-approval", "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"}
	thread := model.SessionRecord{ID: "stream-thread", Cwd: filepath.Join(root, "work"), Settings: encoded(settings)}
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: thread.ID, RequireExplicitSettings: true, ReadThread: func() model.SessionRecord { return thread }, SessionState: store})
	if err != nil {
		return sample, err
	}
	defer func() {
		closeErr := handle.Close()
		if !expectedCloseFailure || !onlyStreamFailure(closeErr, flushFailure) {
			err = errors.Join(err, closeErr)
		}
	}()
	// Release a peer waiting at the first-chunk barrier even if an assertion
	// fails, so cleanup never waits behind the fixture's own gate.
	release := filepath.Join(root, "stream-release")
	defer os.WriteFile(release, nil, 0600)
	finish := filepath.Join(root, "stream-finish")
	defer os.WriteFile(finish, nil, 0600)
	if err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "stream-execution", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "fixture-stream"}}}}); err != nil {
		return sample, err
	}
	if err = awaitStreamFile(ctx, filepath.Join(root, "stream-ready")); err != nil {
		return sample, err
	}
	first := codex.LatestTurn(decoded(store.Read()))
	if kind == "reasoning" && (first["reasoning"] != streamFragment || first["statusLabel"] != "正在分析" || first["status"] != "running") {
		return sample, fmt.Errorf("first native reasoning chunk did not publish running analysis before its protocol barrier")
	}
	// Text has no immediate-status boundary; wait out its existing 50 ms timer
	// before starting counters so both modes measure the same remaining chunks.
	if kind == "text" {
		for text(codex.LatestTurn(decoded(store.Read()))["answer"]) != streamFragment {
			select {
			case <-ctx.Done():
				return sample, ctx.Err()
			case <-time.After(time.Millisecond):
			}
		}
	}
	store.mu.Lock()
	beforeCommits, beforeBytes, beforeStatus := store.commits, store.bytes, store.statusOnly
	rejected := make(chan struct{})
	if rejectFlush {
		store.reject, store.rejected = flushFailure, rejected
	}
	store.mu.Unlock()
	runtime.GC()
	var beforeMemory, afterMemory runtime.MemStats
	var beforeCPU, afterCPU syscall.Rusage
	runtime.ReadMemStats(&beforeMemory)
	if err = syscall.Getrusage(syscall.RUSAGE_SELF, &beforeCPU); err != nil {
		return sample, err
	}
	started := time.Now()
	if err = os.WriteFile(release, nil, 0600); err != nil {
		return sample, err
	}
	if rejectFlush {
		select {
		case <-rejected:
		case <-ctx.Done():
			return sample, ctx.Err()
		}
		if closeErr := handle.Close(); !onlyStreamFailure(closeErr, flushFailure) {
			return sample, fmt.Errorf("close lost streaming flush failure: %v", closeErr)
		}
		expectedCloseFailure = true
		return sample, nil
	}
	streamStatusCommits := 0
	if interrupted || inspectStatus {
		if err = awaitStreamFile(ctx, filepath.Join(root, "stream-emitted")); err != nil {
			return sample, err
		}
		// Terminal handling also commits full text and background observations;
		// count redundant analysis status only before those legitimate boundaries.
		store.mu.Lock()
		streamStatusCommits = store.statusOnly - beforeStatus
		store.mu.Unlock()
	}
	if interrupted {
		if err = handle.Interrupt(ctx); err != nil {
			return sample, err
		}
	} else if inspectStatus {
		if err = os.WriteFile(finish, nil, 0600); err != nil {
			return sample, err
		}
	}
	select {
	case <-store.finished:
	case <-ctx.Done():
		return sample, ctx.Err()
	}
	elapsed := time.Since(started)
	if err = syscall.Getrusage(syscall.RUSAGE_SELF, &afterCPU); err != nil {
		return sample, err
	}
	runtime.ReadMemStats(&afterMemory)
	final := decoded(store.Read())
	turn := codex.LatestTurn(final)
	wantStatus := "completed"
	if interrupted {
		wantStatus = "interrupted"
	}
	wantText, wantReasoning := strings.Repeat(streamFragment, chunks), ""
	if kind == "reasoning" {
		wantText, wantReasoning = streamAnswer, wantText
		if interrupted {
			wantText = ""
		}
	}
	if turn["status"] != wantStatus || text(turn["answer"]) != wantText || text(turn["reasoning"]) != wantReasoning {
		return sample, fmt.Errorf("native %s stream final state differs: status=%v text=%d reasoning=%d", kind, turn["status"], len(text(turn["answer"])), len(text(turn["reasoning"])))
	}
	normalizeStreamState(final)
	sum := sha256.Sum256(encoded(final))
	store.mu.Lock()
	sample = streamSample{Kind: kind, Chunks: chunks, MeasuredChunks: chunks - 1, FragmentBytes: len(streamFragment), WallMS: float64(elapsed) / float64(time.Millisecond), ParentUserCPUMS: float64(afterCPU.Utime.Nano()-beforeCPU.Utime.Nano()) / float64(time.Millisecond), ParentSystemCPUMS: float64(afterCPU.Stime.Nano()-beforeCPU.Stime.Nano()) / float64(time.Millisecond), ParentAllocatedBytes: afterMemory.TotalAlloc - beforeMemory.TotalAlloc, ParentAllocations: afterMemory.Mallocs - beforeMemory.Mallocs, Commits: store.commits - beforeCommits, CommittedBytes: store.bytes - beforeBytes, RepeatedStatusCommits: streamStatusCommits, ResumedAnalysis: store.resumedAnalysis, FinalStateSHA256: fmt.Sprintf("%x", sum)}
	store.mu.Unlock()
	return sample, nil
}

func onlyStreamFailure(err, expected error) bool {
	if err == expected {
		return true
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		children := joined.Unwrap()
		if len(children) == 0 {
			return false
		}
		for _, child := range children {
			if !onlyStreamFailure(child, expected) {
				return false
			}
		}
		return true
	}
	return false
}

func normalizeStreamState(value any) {
	switch value := value.(type) {
	case map[string]any:
		for _, key := range []string{"createdAt", "updatedAt", "finishedAt"} {
			delete(value, key)
		}
		if strings.HasPrefix(text(value["id"]), "tl:") {
			value["id"] = "timeline"
		}
		for _, child := range value {
			normalizeStreamState(child)
		}
	case []any:
		for _, child := range value {
			normalizeStreamState(child)
		}
	}
}

func awaitStreamFile(ctx context.Context, path string) error {
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !os.IsNotExist(err) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Millisecond):
		}
	}
}

func (p *peer) streamFixture(method string, params object, id any) (bool, error) {
	kind := os.Getenv("MOKUSEI_CODEX_REPLAY_STREAM_KIND")
	if kind == "" {
		return false, nil
	}
	chunks, err := strconv.Atoi(os.Getenv("MOKUSEI_CODEX_REPLAY_STREAM_CHUNKS"))
	if err != nil || chunks < 2 || chunks > 1024 {
		return true, fmt.Errorf("invalid native stream chunk count")
	}
	root := os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT")
	if method == "" && id == "stream-emitted" {
		if err := os.WriteFile(filepath.Join(root, "stream-emitted"), nil, 0600); err != nil {
			return true, err
		}
		if os.Getenv("MOKUSEI_CODEX_REPLAY_STREAM_INTERRUPT") == "true" {
			return true, nil
		}
		ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer cancel()
		if err := awaitStreamFile(ctx, filepath.Join(root, "stream-finish")); err != nil {
			return true, err
		}
		return true, p.streamComplete(kind, chunks)
	}
	if method == "" && id == "stream-ready" {
		if err := os.WriteFile(filepath.Join(root, "stream-ready"), nil, 0600); err != nil {
			return true, err
		}
		ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer cancel()
		if err := awaitStreamFile(ctx, filepath.Join(root, "stream-release")); err != nil {
			return true, err
		}
		for i := 1; i < chunks; i++ {
			if kind == "reasoning" && i == chunks/2 && os.Getenv("MOKUSEI_CODEX_REPLAY_STREAM_INSPECT") == "true" {
				if err := p.event("item/plan/delta", object{"threadId": p.session, "turnId": p.turn}); err != nil {
					return true, err
				}
			}
			if err := p.streamDelta(kind); err != nil {
				return true, err
			}
		}
		if os.Getenv("MOKUSEI_CODEX_REPLAY_STREAM_INTERRUPT") == "true" || os.Getenv("MOKUSEI_CODEX_REPLAY_STREAM_INSPECT") == "true" {
			return true, p.send(object{"id": "stream-emitted", "method": "currentTime/read", "params": object{}})
		}
		return true, p.streamComplete(kind, chunks)
	}
	if method != "turn/start" {
		return false, nil
	}
	p.turnNumber++
	p.turn = fmt.Sprintf("fixture-turn-%d", p.turnNumber)
	if err := p.event("turn/started", object{"threadId": p.session, "turn": object{"id": p.turn}}); err != nil {
		return true, err
	}
	if err := p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}}); err != nil {
		return true, err
	}
	if err := p.streamDelta(kind); err != nil {
		return true, err
	}
	return true, p.send(object{"id": "stream-ready", "method": "currentTime/read", "params": object{}})
}

func (p *peer) streamComplete(kind string, chunks int) error {
	answer := strings.Repeat(streamFragment, chunks)
	if kind == "reasoning" {
		if err := p.event("item/completed", object{"threadId": p.session, "turnId": p.turn, "item": object{"id": "reasoning", "type": "reasoning", "summary": []any{answer}}}); err != nil {
			return err
		}
		answer = streamAnswer
	}
	return p.completed(answer)
}

func (p *peer) streamDelta(kind string) error {
	method, itemID := "item/agentMessage/delta", "answer-"+p.turn
	if kind == "reasoning" {
		method, itemID = "item/reasoning/summaryTextDelta", "reasoning"
	}
	return p.event(method, object{"threadId": p.session, "turnId": p.turn, "itemId": itemID, "delta": streamFragment})
}
