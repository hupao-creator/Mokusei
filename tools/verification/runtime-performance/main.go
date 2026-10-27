// Command runtime-performance measures production boundaries with local fixtures.
// Setup, warmup and cleanup are excluded; each sample starts from a fresh store.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"runtime/pprof"
	"sort"
	"strings"
	"syscall"
	"time"
)

type measurement struct {
	Sample             int     `json:"sample"`
	Operations         int     `json:"operations"`
	WallNS             int64   `json:"wallNs"`
	UserCPUNS          int64   `json:"userCpuNs"`
	SystemCPUNS        int64   `json:"systemCpuNs"`
	NSPerOperation     float64 `json:"nsPerOperation"`
	OperationsPerSec   float64 `json:"operationsPerSecond"`
	MedianNS           int64   `json:"medianNs"`
	P95NS              int64   `json:"p95Ns"`
	AllocatedBytes     uint64  `json:"allocatedBytes"`
	Allocations        uint64  `json:"allocations"`
	BytesPerOperation  float64 `json:"bytesPerOperation"`
	AllocsPerOperation float64 `json:"allocsPerOperation"`
	LiveHeapDeltaBytes int64   `json:"liveHeapDeltaBytes"`
	MaxRSSBytes        int64   `json:"processHighWaterRSSBytes"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	scenario := flag.String("scenario", "store-noop", "store-noop, store-lifecycle-append, store-work-read, runtime-list, runtime-notify, application-list")
	records := flag.Int("records", 1000, "preloaded records/events per fresh sample")
	iterations := flag.Int("iterations", 100, "measured operations per sample")
	samples := flag.Int("samples", 5, "independent samples")
	warmup := flag.Int("warmup", 1, "unmeasured operations per sample")
	label := flag.String("label", "", "source label recorded alongside the executable identity")
	cpuProfile := flag.String("cpuprofile", "", "CPU profile of measured operations (requires samples=1)")
	heapProfile := flag.String("memprofile", "", "live heap profile after measured operations (requires samples=1)")
	flag.Parse()
	if *records < 0 || *iterations < 1 || *samples < 1 || *warmup < 0 || ((*cpuProfile != "" || *heapProfile != "") && *samples != 1) {
		return errors.New("invalid scale or profile options")
	}
	prepare := prepareStoreScenario
	switch {
	case strings.HasPrefix(*scenario, "runtime-"):
		prepare = prepareRuntimeScenario
	case strings.HasPrefix(*scenario, "application-"):
		prepare = prepareApplicationScenario
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	artifact, err := os.ReadFile(executable)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(artifact)
	artifact = nil
	build, _ := debug.ReadBuildInfo()
	output := struct {
		StartedAt     string           `json:"startedAt"`
		Scenario      string           `json:"scenario"`
		SourceLabel   string           `json:"sourceLabel"`
		Records       int              `json:"records"`
		Warmup        int              `json:"warmupOperations"`
		GOOS          string           `json:"goos"`
		GOARCH        string           `json:"goarch"`
		GoVersion     string           `json:"goVersion"`
		GOMAXPROCS    int              `json:"gomaxprocs"`
		ExecutableSHA string           `json:"executableSHA256"`
		Build         *debug.BuildInfo `json:"build"`
		Profiled      bool             `json:"profiled"`
		Measurements  []measurement    `json:"measurements"`
	}{StartedAt: time.Now().UTC().Format(time.RFC3339Nano), Scenario: *scenario, SourceLabel: *label, Records: *records,
		Warmup: *warmup, GOOS: runtime.GOOS, GOARCH: runtime.GOARCH, GoVersion: runtime.Version(),
		GOMAXPROCS: runtime.GOMAXPROCS(0), ExecutableSHA: hex.EncodeToString(sum[:]), Build: build,
		Profiled: *cpuProfile != "" || *heapProfile != ""}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	for sample := 1; sample <= *samples; sample++ {
		operation, cleanup, err := prepare(ctx, *scenario, *records)
		if err != nil {
			return err
		}
		result, measureErr := measure(ctx, operation, *iterations, *warmup, *cpuProfile, *heapProfile)
		closeErr := cleanup()
		if err := errors.Join(measureErr, closeErr); err != nil {
			return fmt.Errorf("sample %d: %w", sample, err)
		}
		result.Sample = sample
		output.Measurements = append(output.Measurements, result)
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(output)
}

func measure(ctx context.Context, operation func(context.Context) error, iterations, warmup int, cpuPath, heapPath string) (measurement, error) {
	for range warmup {
		if err := operation(ctx); err != nil {
			return measurement{}, err
		}
	}
	latencies := make([]int64, iterations)
	runtime.GC()
	var cpu *os.File
	if cpuPath != "" {
		var err error
		cpu, err = os.Create(cpuPath)
		if err != nil {
			return measurement{}, err
		}
		defer cpu.Close()
		if err := pprof.StartCPUProfile(cpu); err != nil {
			return measurement{}, err
		}
		defer pprof.StopCPUProfile()
	}
	var before, after, settled runtime.MemStats
	runtime.ReadMemStats(&before)
	var cpuBefore, cpuAfter syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &cpuBefore); err != nil {
		return measurement{}, err
	}
	started := time.Now()
	for i := range iterations {
		start := time.Now()
		if err := operation(ctx); err != nil {
			return measurement{}, err
		}
		latencies[i] = time.Since(start).Nanoseconds()
	}
	elapsed := time.Since(started)
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &cpuAfter); err != nil {
		return measurement{}, err
	}
	runtime.ReadMemStats(&after)
	if cpu != nil {
		pprof.StopCPUProfile()
	}
	runtime.GC()
	runtime.ReadMemStats(&settled)
	if heapPath != "" {
		file, err := os.Create(heapPath)
		if err != nil {
			return measurement{}, err
		}
		err = pprof.WriteHeapProfile(file)
		if err = errors.Join(err, file.Close()); err != nil {
			return measurement{}, err
		}
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	rss := cpuAfter.Maxrss
	if runtime.GOOS != "darwin" {
		rss *= 1024
	}
	return measurement{Operations: iterations, WallNS: elapsed.Nanoseconds(),
		UserCPUNS: cpuAfter.Utime.Nano() - cpuBefore.Utime.Nano(), SystemCPUNS: cpuAfter.Stime.Nano() - cpuBefore.Stime.Nano(),
		NSPerOperation: float64(elapsed.Nanoseconds()) / float64(iterations), OperationsPerSec: float64(iterations) / elapsed.Seconds(),
		MedianNS: latencies[(iterations-1)/2], P95NS: latencies[(iterations*95+99)/100-1],
		AllocatedBytes: after.TotalAlloc - before.TotalAlloc, Allocations: after.Mallocs - before.Mallocs,
		BytesPerOperation: float64(after.TotalAlloc-before.TotalAlloc) / float64(iterations), AllocsPerOperation: float64(after.Mallocs-before.Mallocs) / float64(iterations),
		LiveHeapDeltaBytes: int64(settled.HeapAlloc) - int64(before.HeapAlloc), MaxRSSBytes: rss}, nil
}
