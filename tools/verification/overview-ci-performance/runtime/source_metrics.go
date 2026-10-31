package main

import (
	"math"
	"sort"
	"time"
)

func unacceptedIndices(events []sourceEvent) []int {
	indices := []int{}
	for _, event := range events {
		if !event.CommitSucceeded {
			indices = append(indices, event.Index)
		}
	}
	return indices
}

// Boundaries use the source's monotonic clock. An event whose Store.Update
// failed has completed processing, but remains unaccepted; it is not inFlight.
func queueAt(events []sourceEvent, uptime, origin int64) map[string]any {
	result := map[string]any{"available": uptime > 0, "uptimeNanoseconds": uptime, "elapsedNanoseconds": max(0, uptime-origin),
		"meaning": "reconstructed from shared raw event receipts; completed marks worker result recording before queue slot cleanup, not an atomic queue snapshot"}
	if uptime <= 0 {
		return result
	}
	planned, enqueued, dequeued, sent, accepted, completed := 0, 0, 0, 0, 0, 0
	pending, inFlight, failed, unaccepted, acceptanceTimingUnavailable := []int{}, []int{}, []int{}, []int{}, []int{}
	oldest, oldestFlight := int64(0), int64(0)
	by := func(at int64) bool { return at > 0 && at <= uptime }
	for _, event := range events {
		if by(event.PlannedUptimeNanoseconds) {
			planned++
		}
		if !by(event.EnqueuedUptimeNanoseconds) {
			continue
		}
		enqueued++
		if !by(event.AcceptedUptimeNanoseconds) {
			unaccepted = append(unaccepted, event.Index)
		} else {
			accepted++
		}
		if !by(event.DequeuedUptimeNanoseconds) {
			pending = append(pending, event.Index)
			oldest = max(oldest, uptime-event.EnqueuedUptimeNanoseconds)
			continue
		}
		dequeued++
		if by(event.SentUptimeNanoseconds) {
			sent++
		}
		if by(event.CompletedUptimeNanoseconds) {
			completed++
			if !event.CommitSucceeded {
				failed = append(failed, event.Index)
			} else if event.AcceptedUptimeNanoseconds == 0 {
				// Completion proves that the successful return already happened,
				// but a failed clock read supplies no exact acceptance timestamp.
				// Preserve that distinction instead of calling the commit failed.
				acceptanceTimingUnavailable = append(acceptanceTimingUnavailable, event.Index)
			}
		} else {
			inFlight = append(inFlight, event.Index)
			oldestFlight = max(oldestFlight, uptime-event.DequeuedUptimeNanoseconds)
		}
	}
	result["plannedDue"], result["enqueued"], result["dequeued"] = planned, enqueued, dequeued
	result["sent"], result["accepted"], result["completed"] = sent, accepted, completed
	result["pending"], result["pendingIndices"] = len(pending), pending
	result["inFlight"], result["inFlightIndices"] = len(inFlight), inFlight
	result["failed"], result["failedIndices"] = len(failed), failed
	result["acceptanceTimingUnavailable"], result["acceptanceTimingUnavailableIndices"] = len(acceptanceTimingUnavailable), acceptanceTimingUnavailable
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
		at := event.SentUptimeNanoseconds
		if enqueue {
			at = event.EnqueuedUptimeNanoseconds
		}
		if at == 0 {
			continue
		}
		observed++
		lateness := at - event.PlannedUptimeNanoseconds
		maximum = max(maximum, lateness)
		if lateness > int64(50*time.Millisecond) {
			exceeded = append(exceeded, event.Index)
		}
	}
	return map[string]any{"thresholdMilliseconds": 50, "observedCount": observed,
		"missingCount": len(events) - observed, "exceededCount": len(exceeded), "exceededIndices": exceeded,
		"maxLatenessMilliseconds": float64(maximum) / 1e6, "wouldFail": len(exceeded) > 0,
		"isValidityGate": enqueue, "clock": measurementClockID() + "; shared absolute raw nanoseconds"}
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
	result := map[string]any{"clock": measurementClockID() + "; shared absolute raw nanoseconds; missing stages are omitted, not zero"}
	for _, metric := range []struct {
		name string
		pair func(sourceEvent) (int64, int64)
	}{
		{"enqueueLateness", func(e sourceEvent) (int64, int64) { return e.PlannedUptimeNanoseconds, e.EnqueuedUptimeNanoseconds }},
		{"legacySentLateness", func(e sourceEvent) (int64, int64) { return e.PlannedUptimeNanoseconds, e.SentUptimeNanoseconds }},
		{"queueWait", func(e sourceEvent) (int64, int64) { return e.EnqueuedUptimeNanoseconds, e.DequeuedUptimeNanoseconds }},
		{"dequeueToSent", func(e sourceEvent) (int64, int64) { return e.DequeuedUptimeNanoseconds, e.SentUptimeNanoseconds }},
		{"preparation", func(e sourceEvent) (int64, int64) {
			return e.SentUptimeNanoseconds, e.StoreUpdateStartedUptimeNanoseconds
		}},
		{"storeUpdate", func(e sourceEvent) (int64, int64) {
			return e.StoreUpdateStartedUptimeNanoseconds, e.AcceptedUptimeNanoseconds
		}},
		{"workerThroughAccepted", func(e sourceEvent) (int64, int64) { return e.SentUptimeNanoseconds, e.AcceptedUptimeNanoseconds }},
		{"enqueueThroughAccepted", func(e sourceEvent) (int64, int64) { return e.EnqueuedUptimeNanoseconds, e.AcceptedUptimeNanoseconds }},
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
