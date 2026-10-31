package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"reflect"
	"testing"
	"time"
)

// A second real process verifies the OS epoch; a matching label alone would
// not catch an accidental process-relative clock or a unit conversion error.
func TestSharedRawClockHasCrossProcessEpoch(t *testing.T) {
	if os.Getenv("MOKUSEI_CI_CLOCK_PROBE") == "1" {
		observation, err := observeClock()
		if err != nil {
			t.Fatal(err)
		}
		if err := json.NewEncoder(os.Stdout).Encode(clockEnvelope{
			MeasurementClockVersion: measurementClockVersion, MeasurementClockID: measurementClockID(),
			ClockOriginUptimeNanoseconds: observation.UptimeNanoseconds, ClockObservation: observation,
		}); err != nil {
			t.Fatal(err)
		}
		os.Exit(0)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	before := sourceTestRaw(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "-test.run=^TestSharedRawClockHasCrossProcessEpoch$")
	command.Env = append(os.Environ(), "MOKUSEI_CI_CLOCK_PROBE=1")
	raw, err := command.Output()
	after := sourceTestRaw(t)
	if err != nil {
		t.Fatal(err)
	}
	var envelope clockEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatalf("child clock JSON: %v / %q", err, raw)
	}
	observation := envelope.ClockObservation
	if envelope.MeasurementClockVersion != 2 || envelope.MeasurementClockID != measurementClockID() ||
		envelope.ClockOriginUptimeNanoseconds <= 0 || observation.UncertaintyNanoseconds < 0 ||
		observation.UptimeNanoseconds+observation.UncertaintyNanoseconds < before ||
		observation.UptimeNanoseconds-observation.UncertaintyNanoseconds > after {
		t.Fatalf("child clock does not share this process epoch: [%d,%d] %#v", before, after, envelope)
	}
}

func TestRawDeadlineWaitDoesNotReturnBeforeItsClock(t *testing.T) {
	deadline := sourceTestRaw(t) + int64(3*time.Millisecond)
	if err := waitUntilRaw(context.Background(), deadline); err != nil {
		t.Fatal(err)
	}
	if after := sourceTestRaw(t); after < deadline {
		t.Fatalf("timer woke before the authoritative raw deadline: %d < %d", after, deadline)
	}
}

func TestRawWindowsAndSourceGatesIgnoreUTCJumps(t *testing.T) {
	start := boundary{ActualUptimeNanoseconds: 1_000_000_000_000, ActualUnixNano: 20_000_000_000,
		UserSeconds: 1, SystemSeconds: 2}
	end := boundary{ActualUptimeNanoseconds: start.ActualUptimeNanoseconds + int64(20*time.Second),
		ActualUnixNano: start.ActualUnixNano + int64(20*time.Second), UserSeconds: 3, SystemSeconds: 4}
	event := sourceEvent{Index: 0, PlannedUptimeNanoseconds: start.ActualUptimeNanoseconds + 1,
		EnqueuedUptimeNanoseconds: start.ActualUptimeNanoseconds + int64(60*time.Millisecond),
		DequeuedUptimeNanoseconds: start.ActualUptimeNanoseconds + int64(61*time.Millisecond),
		SentUptimeNanoseconds:     start.ActualUptimeNanoseconds + int64(62*time.Millisecond),
		AcceptedUptimeNanoseconds: start.ActualUptimeNanoseconds + int64(65*time.Millisecond), CommitSucceeded: true}
	published := publication{PublishedUptimeNanoseconds: start.ActualUptimeNanoseconds + int64(64*time.Millisecond),
		DirtyCards: 1, MutationBytes: 20, EncodedNDJSONBytes: 100}
	baseline := measureWindow(start, end, []sourceEvent{event}, []publication{published})
	if baseline.CPU.WallSeconds != 20 || baseline.CPU.CPUSeconds != 4 || baseline.CPU.CPUPercent != 20 ||
		baseline.Enqueued != 1 || baseline.Accepted != 1 || baseline.Publishes != 1 {
		t.Fatalf("bad raw baseline: %#v", baseline)
	}
	// Realtime may jump backward, forward, or even cross zero. It cannot decide
	// whether a measured operation exists or which formal window contains it.
	start.ActualUnixNano, end.ActualUnixNano = 90_000_000_000, -30_000_000_000
	event.PlannedUnixNano, event.EnqueuedUnixNano, event.SentUnixNano = 0, -1, 1<<62
	event.AcceptedUnixNano, published.PublishedUnixNano = 0, -123
	changed := measureWindow(start, end, []sourceEvent{event}, []publication{published})
	baseline.StartUnixNano, baseline.EndUnixNano = 0, 0
	changed.StartUnixNano, changed.EndUnixNano = 0, 0
	if !reflect.DeepEqual(baseline, changed) {
		t.Fatalf("UTC changed measured work: before=%#v after=%#v", baseline, changed)
	}
	if gate := sourceDeadline([]sourceEvent{event}, true); gate["wouldFail"] != true || gate["exceededCount"] != 1 {
		t.Fatalf("raw enqueue failure was hidden by unrelated UTC: %#v", gate)
	}
	event.EnqueuedUptimeNanoseconds = event.PlannedUptimeNanoseconds + int64(time.Millisecond)
	if gate := sourceDeadline([]sourceEvent{event}, true); gate["wouldFail"] != false {
		t.Fatalf("UTC jump caused an enqueue failure: %#v", gate)
	}
}

func TestClockEnvelopeIsFlatAndFreshOnEachResponse(t *testing.T) {
	origin, err := observeClock()
	if err != nil {
		t.Fatal(err)
	}
	b := &benchmark{origin: origin}
	envelope, err := b.observeEnvelope()
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(schedule{clockEnvelope: envelope, SourceProtocolVersion: sourceProtocolVersion,
		SourceQueueCapacity: sourceQueueCapacity})
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		MeasurementClockVersion      int              `json:"measurementClockVersion"`
		MeasurementClockID           string           `json:"measurementClockID"`
		ClockOriginUptimeNanoseconds int64            `json:"clockOriginUptimeNanoseconds"`
		ClockObservation             clockObservation `json:"clockObservation"`
	}
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.MeasurementClockVersion != 2 || decoded.MeasurementClockID != measurementClockID() ||
		decoded.ClockOriginUptimeNanoseconds != origin.UptimeNanoseconds || decoded.ClockObservation.UptimeNanoseconds <= 0 {
		t.Fatalf("start schedule lost its required top-level clock identity: %s", encoded)
	}
	before := sourceTestRaw(t)
	value := map[string]any{}
	if err := b.attachClock(value); err != nil {
		t.Fatal(err)
	}
	after := sourceTestRaw(t)
	observation := value["clockObservation"].(clockObservation)
	if observation.UptimeNanoseconds < before || observation.UptimeNanoseconds > after ||
		value["clockOriginUptimeNanoseconds"] != origin.UptimeNanoseconds {
		t.Fatalf("response reused an old observation or changed origin: %#v", value)
	}
}

func TestSuccessfulCommitIsRetainedWhenAcceptedClockReadFails(t *testing.T) {
	clockFailure := errors.New("OS raw clock read failed")
	reads, commits := 0, 0
	var receipt sourceEvent
	event, err := executeSourceEventWithClock(context.Background(), sourceEvent{
		PlannedUptimeNanoseconds: 50, EnqueuedUptimeNanoseconds: 100, DequeuedUptimeNanoseconds: 200},
		func() error { return nil }, func() error { commits++; return nil },
		func(value sourceEvent) { receipt = value }, func() (sourceInstant, error) {
			reads++
			if reads == 3 {
				return sourceInstant{}, clockFailure
			}
			return sourceInstant{UptimeNanoseconds: int64(reads) * 1000, ElapsedNano: int64(reads) * 1000}, nil
		})
	if !errors.Is(err, clockFailure) || commits != 1 || !event.CommitSucceeded || !receipt.CommitSucceeded ||
		event.AcceptedUptimeNanoseconds != 0 || event.AcceptedElapsedNanoseconds != 0 ||
		event.CompletedUptimeNanoseconds == 0 || event.Error == "" {
		t.Fatalf("committed work disappeared or acquired an invented accepted time: %#v / %v", event, err)
	}
	queue := queueAt([]sourceEvent{event}, event.CompletedUptimeNanoseconds, 1)
	if queue["failed"] != 0 || queue["acceptanceTimingUnavailable"] != 1 || len(unacceptedIndices([]sourceEvent{event})) != 0 {
		t.Fatalf("missing acceptance time was misreported as a failed/unaccepted commit: %#v", queue)
	}
}
