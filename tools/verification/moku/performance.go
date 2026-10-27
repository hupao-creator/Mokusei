package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	runtimepkg "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

type mokuPerformanceOptions struct {
	enabled           bool
	swiftNoteExposure bool
	selected          string
	samples           int
	iterations        int
	threads           int
	threadBytes       int
}

func parseMokuPerformanceOptions() (mokuPerformanceOptions, error) {
	var options mokuPerformanceOptions
	flags := flag.NewFlagSet("moku", flag.ContinueOnError)
	flags.BoolVar(&options.enabled, "performance", false, "emit fixed-workload performance samples as JSON instead of running contract replays")
	flags.BoolVar(&options.swiftNoteExposure, "swift-note-exposure", false, "run real Swift note exposure through authenticated Runtime and Moku context")
	flags.StringVar(&options.selected, "performance-case", "all", "all, context, tools, or queue")
	flags.IntVar(&options.samples, "samples", 5, "independent samples per performance case")
	flags.IntVar(&options.iterations, "iterations", 20, "operations per allocation/latency sample")
	flags.IntVar(&options.threads, "threads", 64, "ordinary Threads in the context snapshot fixture")
	flags.IntVar(&options.threadBytes, "thread-bytes", 32*1024, "native history payload bytes per ordinary Thread")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return options, err
	}
	if flags.NArg() != 0 || options.samples < 1 || options.samples > 100 || options.iterations < 1 || options.iterations > 10000 || options.threads < 1 || options.threads > 10000 || options.threadBytes < 0 || options.threadBytes > 1024*1024 {
		return options, errors.New("invalid Moku performance dimensions")
	}
	switch options.selected {
	case "all", "context", "tools", "queue":
	default:
		return options, errors.New("performance-case must be all, context, tools, or queue")
	}
	return options, nil
}

type mokuPerformanceSample struct {
	Case        string  `json:"case"`
	Sample      int     `json:"sample"`
	Iterations  int     `json:"iterations"`
	Threads     int     `json:"threads,omitempty"`
	ThreadBytes int     `json:"threadBytes,omitempty"`
	LatencyNS   int64   `json:"latencyNs"`
	NSPerOp     float64 `json:"nsPerOp"`
	Allocs      uint64  `json:"allocs"`
	AllocsPerOp float64 `json:"allocsPerOp"`
	Bytes       uint64  `json:"bytes"`
	BytesPerOp  float64 `json:"bytesPerOp"`
	ThreadReads int64   `json:"threadReads"`
}

func runMokuPerformance(options mokuPerformanceOptions) error {
	encoder := json.NewEncoder(os.Stdout)
	if options.selected == "all" || options.selected == "context" {
		if err := measureMokuContext(options, encoder); err != nil {
			return err
		}
	}
	if options.selected == "all" || options.selected == "tools" {
		if err := measureMokuTools(options, encoder); err != nil {
			return err
		}
	}
	if options.selected == "all" || options.selected == "queue" {
		for index := 1; index <= options.samples; index++ {
			for _, measure := range []func() (mokuQueueSample, error){measurePreCancelledSubmitCancellation, measureQueuedSubmitCancellation, measurePreCancelledVoiceCancellation, measureQueuedVoiceCancellation} {
				sample, err := measure()
				if err != nil {
					return err
				}
				if err := encoder.Encode(struct {
					mokuQueueSample
					Sample     int `json:"sample"`
					Iterations int `json:"iterations"`
				}{sample, index, 1}); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// Each sample uses the actual coordinator operation. The fixture only resets
// retained audit output between operations so schema/context costs do not get
// mixed with an ever-growing conversation. Resetting performs no JSON work.
func measureMokuOperations(options mokuPerformanceOptions, name string, reads *atomic.Int64, reset func(), operation func() error, encoder *json.Encoder) error {
	reset()
	if err := operation(); err != nil {
		return err
	}
	for sampleIndex := 1; sampleIndex <= options.samples; sampleIndex++ {
		reset()
		runtime.GC()
		initialReads := reads.Load()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		var elapsed time.Duration
		for iteration := 0; iteration < options.iterations; iteration++ {
			reset()
			started := time.Now()
			if err := operation(); err != nil {
				return err
			}
			elapsed += time.Since(started)
		}
		runtime.ReadMemStats(&after)
		count := float64(options.iterations)
		sample := mokuPerformanceSample{
			Case: name, Sample: sampleIndex, Iterations: options.iterations,
			LatencyNS: elapsed.Nanoseconds(), NSPerOp: float64(elapsed.Nanoseconds()) / count,
			Allocs: after.Mallocs - before.Mallocs, AllocsPerOp: float64(after.Mallocs-before.Mallocs) / count,
			Bytes: after.TotalAlloc - before.TotalAlloc, BytesPerOp: float64(after.TotalAlloc-before.TotalAlloc) / count,
			ThreadReads: reads.Load() - initialReads,
		}
		if strings.HasPrefix(name, "context-") {
			sample.Threads, sample.ThreadBytes = options.threads, options.threadBytes
		}
		if err := encoder.Encode(sample); err != nil {
			return err
		}
	}
	return nil
}

func resetMokuPerformanceWorld(w *orchestratorWorld, owner string) func() {
	return func() {
		w.mu.Lock()
		record := w.records[owner]
		record.Transcript = nil
		w.records[owner] = record
		w.sends = nil
		w.mu.Unlock()
	}
}

func measureMokuContext(options mokuPerformanceOptions, encoder *json.Encoder) (err error) {
	root, err := os.MkdirTemp("", "mokusei-moku-performance-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, db.Close()) }()
	// Native state is a real, serialized observation with fixed-size history.
	// Runtime.Threads decodes it through Store.Snapshot.Get during each read.
	payload := strings.Repeat("x", options.threadBytes)
	native := mokuReplayRaw(model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "fixture-finished", Status: "completed", Summary: &payload}})
	_, err = db.Update(mokuReplayContext(), func(tx *store.Tx) error {
		ids := make([]string, options.threads)
		for index := range ids {
			id := fmt.Sprintf("fixture-thread-%d", index)
			ids[index] = id
			record := model.ThreadRecord{SessionRecord: model.SessionRecord{
				ID: id, HarnessID: "mock", Cwd: fmt.Sprintf("/fixture/projects/project-%d", index),
				Revision: 1, Settings: json.RawMessage(`{"model":"fixture-model"}`), SessionState: native,
				CreatedAt: 1, UpdatedAt: int64(index + 1),
			}, Title: id, Tags: []string{}, TagEmojis: map[string]string{}}
			if err := tx.Put("thread:"+id, record); err != nil {
				return err
			}
		}
		return tx.SetOrder("threads", ids)
	})
	if err != nil {
		return err
	}
	harness := &replayNativeHarness{db: db, nativeModel: "fixture-model", wake: make(chan struct{}, 128)}
	r, err := runtimepkg.New(mokuReplayContext(), runtimepkg.Config{Store: db, Harnesses: map[string]plugin.Harness{"mock": harness}, DataDir: root, DefaultCwd: root})
	if err != nil {
		return err
	}
	harness.r = r
	defer func() { err = errors.Join(err, r.Close(context.WithoutCancel(mokuReplayContext()))) }()
	w := newOrchestratorWorld()
	configuration := w.config()
	var reads atomic.Int64
	configuration.Threads = func() ([]model.ThreadRecord, error) { reads.Add(1); return r.Threads() }
	c, err := moku.New(configuration)
	if err != nil {
		return err
	}
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "fixture"}))
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("initialize context measurement")))
	reset := resetMokuPerformanceWorld(w, w.mokuRecord().ID)
	plain := orchestratorInput("fixed context measurement")
	mentioned := orchestratorInput("fixed context measurement")
	mentioned.Input.Parts = append(mentioned.Input.Parts, model.AgentInputPart{Kind: "mention", Name: "explicit", Path: "/fixture/explicit", PathType: "directory"})
	mentioned.DirectoryTag = mokuReplayString("ignored-selected-tag")
	selected := orchestratorInput("fixed context measurement")
	selected.DirectoryTag = mokuReplayString(moku.ThreadDirectoryTag("/fixture/projects/project-0"))
	for _, fixture := range []struct {
		name    string
		request moku.SubmitRequest
	}{{"context-no-directory", plain}, {"context-explicit-directory", mentioned}, {"context-selected-directory", selected}} {
		if err := measureMokuOperations(options, fixture.name, &reads, reset, func() error {
			return c.Submit(mokuReplayContext(), fixture.request)
		}, encoder); err != nil {
			return err
		}
	}
	return nil
}

func measureMokuTools(options mokuPerformanceOptions, encoder *json.Encoder) error {
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("initialize tool measurement")))
	binding := w.binding("talk")
	reset := resetMokuPerformanceWorld(w, w.mokuRecord().ID)
	var reads atomic.Int64
	for _, fixture := range []struct {
		name      string
		arguments json.RawMessage
		invalid   bool
	}{{"tool-valid", json.RawMessage(`{"text":"fixed message"}`), false}, {"tool-rejected", json.RawMessage(`{"text":"fixed message","unexpected":true}`), true}} {
		if err := measureMokuOperations(options, fixture.name, &reads, reset, func() error {
			_, err := binding.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: fixture.arguments})
			if !fixture.invalid {
				return err
			}
			var caller *plugin.ToolCallError
			if !errors.As(err, &caller) {
				return fmt.Errorf("invalid tool fixture lost caller error: %v", err)
			}
			return nil
		}, encoder); err != nil {
			return err
		}
	}
	return nil
}
