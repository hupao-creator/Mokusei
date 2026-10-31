package main

import (
	"math"
	"sort"
	"time"
)

func unacceptedIndices(events []sourceEvent) []int {
	indices := []int{}
	for _, event := range events {
		if event.AcceptedUnixNano == 0 {
			indices = append(indices, event.Index)
		}
	}
	return indices
}

// Boundaries use the source's monotonic clock. An event whose Store.Update
// failed has completed processing, but remains unaccepted; it is not inFlight.
func queueAt(events []sourceEvent, elapsed int64) map[string]any {
	result := map[string]any{"available": elapsed > 0, "elapsedNanoseconds": elapsed,
		"meaning": "reconstructed from monotonic event receipts; completed marks worker result recording before queue slot cleanup, not an atomic queue snapshot"}
	if elapsed <= 0 {
		return result
	}
	planned, enqueued, dequeued, sent, accepted, completed := 0, 0, 0, 0, 0, 0
	pending, inFlight, failed, unaccepted := []int{}, []int{}, []int{}, []int{}
	oldest, oldestFlight := int64(0), int64(0)
	by := func(at int64) bool { return at > 0 && at <= elapsed }
	for _, event := range events {
		if by(event.PlannedElapsedNanoseconds) {
			planned++
		}
		if !by(event.EnqueuedElapsedNanoseconds) {
			continue
		}
		enqueued++
		if !by(event.AcceptedElapsedNanoseconds) {
			unaccepted = append(unaccepted, event.Index)
		} else {
			accepted++
		}
		if !by(event.DequeuedElapsedNanoseconds) {
			pending = append(pending, event.Index)
			oldest = max(oldest, elapsed-event.EnqueuedElapsedNanoseconds)
			continue
		}
		dequeued++
		if by(event.SentElapsedNanoseconds) {
			sent++
		}
		if by(event.CompletedElapsedNanoseconds) {
			completed++
			if !by(event.AcceptedElapsedNanoseconds) {
				failed = append(failed, event.Index)
			}
		} else {
			inFlight = append(inFlight, event.Index)
			oldestFlight = max(oldestFlight, elapsed-event.DequeuedElapsedNanoseconds)
		}
	}
	result["plannedDue"], result["enqueued"], result["dequeued"] = planned, enqueued, dequeued
	result["sent"], result["accepted"], result["completed"] = sent, accepted, completed
	result["pending"], result["pendingIndices"] = len(pending), pending
	result["inFlight"], result["inFlightIndices"] = len(inFlight), inFlight
	result["failed"], result["failedIndices"] = len(failed), failed
	result["outstanding"], result["unacceptedIndices"] = enqueued-accepted, unaccepted
	result["notYetEnqueuedDue"] = planned - enqueued
	result["oldestPendingAgeMilliseconds"] = float64(oldest) / 1e6
	result["inFlightAgeMilliseconds"] = float64(oldestFlight) / 1e6
	return result
}

func sourceDeadline(events []sourceEvent, enqueue bool) map[string]any {
	observed, maximum := 0, int64(0)
	exceeded := []int{}
	for _, event := range events {
		at := event.SentElapsedNanoseconds
		if enqueue {
			at = event.EnqueuedElapsedNanoseconds
		}
		if at == 0 {
			continue
		}
		observed++
		lateness := at - event.PlannedElapsedNanoseconds
		maximum = max(maximum, lateness)
		if lateness > int64(50*time.Millisecond) {
			exceeded = append(exceeded, event.Index)
		}
	}
	return map[string]any{"thresholdMilliseconds": 50, "observedCount": observed,
		"missingCount": len(events) - observed, "exceededCount": len(exceeded), "exceededIndices": exceeded,
		"maxLatenessMilliseconds": float64(maximum) / 1e6, "wouldFail": len(exceeded) > 0,
		"isValidityGate": enqueue, "clock": "same-process monotonic elapsed nanoseconds"}
}

func timingSummary(values []int64) map[string]any {
	result := map[string]any{"count": len(values), "p50": nil, "p95": nil, "max": nil, "total": 0.0,
		"unit": "milliseconds", "percentileMethod": "nearest rank"}
	if len(values) == 0 {
		return result
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	total := int64(0)
	for _, value := range values {
		total += value
	}
	result["p50"] = float64(values[int(math.Ceil(0.50*float64(len(values))))-1]) / 1e6
	result["p95"] = float64(values[int(math.Ceil(0.95*float64(len(values))))-1]) / 1e6
	result["max"], result["total"] = float64(values[len(values)-1])/1e6, float64(total)/1e6
	return result
}

func sourceTimings(events []sourceEvent) map[string]any {
	result := map[string]any{"clock": "same-process monotonic elapsed nanoseconds; missing stages are omitted, not zero"}
	for _, metric := range []struct {
		name string
		pair func(sourceEvent) (int64, int64)
	}{
		{"enqueueLateness", func(e sourceEvent) (int64, int64) { return e.PlannedElapsedNanoseconds, e.EnqueuedElapsedNanoseconds }},
		{"legacySentLateness", func(e sourceEvent) (int64, int64) { return e.PlannedElapsedNanoseconds, e.SentElapsedNanoseconds }},
		{"queueWait", func(e sourceEvent) (int64, int64) { return e.EnqueuedElapsedNanoseconds, e.DequeuedElapsedNanoseconds }},
		{"dequeueToSent", func(e sourceEvent) (int64, int64) { return e.DequeuedElapsedNanoseconds, e.SentElapsedNanoseconds }},
		{"preparation", func(e sourceEvent) (int64, int64) {
			return e.SentElapsedNanoseconds, e.StoreUpdateStartedElapsedNanoseconds
		}},
		{"storeUpdate", func(e sourceEvent) (int64, int64) {
			return e.StoreUpdateStartedElapsedNanoseconds, e.AcceptedElapsedNanoseconds
		}},
		{"workerThroughAccepted", func(e sourceEvent) (int64, int64) { return e.SentElapsedNanoseconds, e.AcceptedElapsedNanoseconds }},
		{"enqueueThroughAccepted", func(e sourceEvent) (int64, int64) { return e.EnqueuedElapsedNanoseconds, e.AcceptedElapsedNanoseconds }},
	} {
		values := []int64{}
		for _, event := range events {
			before, after := metric.pair(event)
			if before != 0 && after != 0 {
				values = append(values, after-before)
			}
		}
		result[metric.name] = timingSummary(values)
	}
	return result
}
