package main

import (
	"encoding/json"
	"fmt"
	"math"
	"runtime"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type sourceEvent struct {
	Index            int    `json:"index"`
	CardID           string `json:"cardID"`
	Sequence         int    `json:"seq"`
	PlannedUnixNano  int64  `json:"plannedUnixNano"`
	SentUnixNano     int64  `json:"sentUnixNano"`
	AcceptedUnixNano int64  `json:"acceptedUnixNano"`
	Error            string `json:"error,omitempty"`
}

type publication struct {
	PublishedUnixNano  int64    `json:"publishedUnixNano"`
	BaseRevision       int64    `json:"baseRevision"`
	Revision           int64    `json:"revision"`
	DirtyCards         int      `json:"dirtyCards"`
	MutationBytes      int      `json:"mutationBytes"`
	EncodedNDJSONBytes int      `json:"encodedNDJSONBytes"`
	CardIDs            []string `json:"cardIDs"`
	Sequences          []int64  `json:"seqs"`
}

type boundary struct {
	PlannedUnixNano int64   `json:"plannedUnixNano"`
	ActualUnixNano  int64   `json:"actualUnixNano"`
	ElapsedSeconds  float64 `json:"elapsedSeconds"`
	UserSeconds     float64 `json:"userSeconds"`
	SystemSeconds   float64 `json:"systemSeconds"`
	MaximumRSSBytes int64   `json:"maximumRSSBytes"`
}

type cpuMeasurement struct {
	CPUSeconds  float64 `json:"cpuSeconds"`
	WallSeconds float64 `json:"wallSeconds"`
	CPUPercent  float64 `json:"cpuPercent"`
}

type windowMeasurement struct {
	StartUnixNano       int64          `json:"startUnixNano"`
	EndUnixNano         int64          `json:"endUnixNano"`
	CPU                 cpuMeasurement `json:"cpu"`
	Planned             int            `json:"planned"`
	Sent                int            `json:"sent"`
	Accepted            int            `json:"accepted"`
	Publishes           int            `json:"publishes"`
	ChangedCards        int            `json:"changedCards"`
	DirtyCardMean       float64        `json:"dirtyCardMean"`
	DirtyCardHistogram  map[int]int    `json:"dirtyCardHistogram"`
	MutationBytes       int            `json:"mutationBytes"`
	EncodedNDJSONBytes  int            `json:"encodedNDJSONBytes"`
	MaxSourceLatenessMS float64        `json:"maxSourceLatenessMilliseconds"`
}

func sampleBoundary(origin time.Time, planned int64) (boundary, error) {
	var usage syscall.Rusage
	before := time.Now()
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		return boundary{}, err
	}
	rss := usage.Maxrss
	if runtime.GOOS != "darwin" {
		rss *= 1024
	}
	return boundary{PlannedUnixNano: planned, ActualUnixNano: before.UnixNano(), ElapsedSeconds: before.Sub(origin).Seconds(),
		UserSeconds:   float64(usage.Utime.Sec) + float64(usage.Utime.Usec)/1e6,
		SystemSeconds: float64(usage.Stime.Sec) + float64(usage.Stime.Usec)/1e6, MaximumRSSBytes: rss}, nil
}

func (b *benchmark) recordPublication(raw json.RawMessage) {
	// Publication callbacks are counted at the real production boundary. Only
	// identity/revision fields are decoded; copied session JSON is not retained.
	item := publication{PublishedUnixNano: time.Now().UnixNano(), MutationBytes: len(raw),
		EncodedNDJSONBytes: len(raw) + b.wireOverhead, CardIDs: []string{}, Sequences: []int64{}}
	var mutation struct {
		BaseRevision int64 `json:"baseRevision"`
		Revision     int64 `json:"revision"`
		Threads      *struct {
			Upserts []struct {
				ID       string `json:"id"`
				Revision int64  `json:"revision"`
			} `json:"upserts"`
		} `json:"threads"`
	}
	if err := json.Unmarshal(raw, &mutation); err != nil {
		b.fail("publication decode: " + err.Error())
		return
	}
	item.BaseRevision, item.Revision = mutation.BaseRevision, mutation.Revision
	if mutation.Threads != nil {
		item.DirtyCards = len(mutation.Threads.Upserts)
		for _, record := range mutation.Threads.Upserts {
			item.CardIDs = append(item.CardIDs, record.ID)
			item.Sequences = append(item.Sequences, record.Revision-1)
		}
	}
	b.mu.Lock()
	b.publications = append(b.publications, item)
	b.mu.Unlock()
}

func measureWindow(start, end boundary, events []sourceEvent, publications []publication) windowMeasurement {
	result := windowMeasurement{StartUnixNano: start.ActualUnixNano, EndUnixNano: end.ActualUnixNano,
		DirtyCardHistogram: map[int]int{}}
	if start.ActualUnixNano == 0 || end.ActualUnixNano <= start.ActualUnixNano {
		return result
	}
	result.CPU = cpuMeasurement{CPUSeconds: end.UserSeconds + end.SystemSeconds - start.UserSeconds - start.SystemSeconds,
		WallSeconds: end.ElapsedSeconds - start.ElapsedSeconds}
	if result.CPU.WallSeconds > 0 {
		result.CPU.CPUPercent = 100 * result.CPU.CPUSeconds / result.CPU.WallSeconds
	}
	inside := func(at int64) bool { return at >= start.ActualUnixNano && at < end.ActualUnixNano }
	for _, event := range events {
		if inside(event.PlannedUnixNano) {
			result.Planned++
		}
		if inside(event.SentUnixNano) {
			result.Sent++
			result.MaxSourceLatenessMS = math.Max(result.MaxSourceLatenessMS, float64(event.SentUnixNano-event.PlannedUnixNano)/1e6)
		}
		if inside(event.AcceptedUnixNano) {
			result.Accepted++
		}
	}
	for _, publication := range publications {
		if !inside(publication.PublishedUnixNano) {
			continue
		}
		result.Publishes++
		result.ChangedCards += publication.DirtyCards
		result.DirtyCardHistogram[publication.DirtyCards]++
		result.MutationBytes += publication.MutationBytes
		result.EncodedNDJSONBytes += publication.EncodedNDJSONBytes
	}
	if result.Publishes > 0 {
		result.DirtyCardMean = float64(result.ChangedCards) / float64(result.Publishes)
	}
	return result
}

func (b *benchmark) result() map[string]any {
	observation, sampleErr := sampleBoundary(b.origin, 0)
	b.mu.Lock()
	state, done := b.state, b.sourceDone
	var plan *schedule
	if b.schedule != nil {
		copy := *b.schedule
		plan = &copy
	}
	boundaries := make(map[string]boundary, len(b.boundaries)+1)
	for key, value := range b.boundaries {
		boundaries[key] = value
	}
	events := append([]sourceEvent{}, b.events...)
	publications := append([]publication{}, b.publications...)
	records := append([]model.ThreadRecord{}, b.records[:activeCount]...)
	errors := append([]string{}, b.errors...)
	b.mu.Unlock()
	boundaries["observationEnd"] = observation
	if sampleErr != nil {
		errors = append(errors, sampleErr.Error())
	}
	final := make([]cardExpectation, 0, activeCount)
	for _, record := range records {
		value, err := expectedCard(record, b.adapter)
		if err != nil {
			errors = append(errors, err.Error())
			continue
		}
		final = append(final, value)
	}
	warmup := measureWindow(boundaries["warmupStart"], boundaries["formalStart"], events, publications)
	formal := measureWindow(boundaries["formalStart"], boundaries["formalEnd"], events, publications)
	tail := measureWindow(boundaries["formalEnd"], observation, events, publications)
	planned, accepted, rate := 0, 0, 0
	if b.options.condition != "R0" {
		planned, rate = 1000, 40
	}
	for _, event := range events {
		if event.AcceptedUnixNano != 0 {
			accepted++
		}
	}
	invalid := append([]string{}, errors...)
	if plan == nil {
		invalid = append(invalid, "source was not started")
	}
	if _, ok := boundaries["formalEnd"]; !ok {
		invalid = append(invalid, "formal end boundary was not sampled")
	}
	if !done {
		invalid = append(invalid, "source has not finished all planned updates")
	}
	if len(events) != planned || accepted != planned {
		invalid = append(invalid, "planned/sent/accepted totals do not match")
	}
	for _, name := range []string{"warmupStart", "formalStart", "formalEnd"} {
		if mark, ok := boundaries[name]; ok && math.Abs(float64(mark.ActualUnixNano-mark.PlannedUnixNano)) > float64(50*time.Millisecond) {
			invalid = append(invalid, name+" sampling missed its schedule by more than 50ms")
		}
	}
	for _, event := range events {
		if event.SentUnixNano-event.PlannedUnixNano > int64(50*time.Millisecond) {
			invalid = append(invalid, fmt.Sprintf("source event %d missed its independent deadline by more than 50ms", event.Index))
			break
		}
	}
	if len(final) != len(b.expected) {
		invalid = append(invalid, "final public card projections are missing")
	} else {
		for index := range final {
			if final[index] != b.expected[index] {
				invalid = append(invalid, "final public seq/identity/text mismatch for "+final[index].ID)
			}
		}
	}
	lastAccepted, lastPublication := int64(0), int64(0)
	for _, event := range events {
		if event.AcceptedUnixNano > lastAccepted {
			lastAccepted = event.AcceptedUnixNano
		}
	}
	for _, publication := range publications {
		if publication.PublishedUnixNano > lastPublication {
			lastPublication = publication.PublishedUnixNano
		}
	}
	return map[string]any{
		"schemaVersion": 1, "condition": b.options.condition, "seed": b.options.seed, "n": cardCount, "k": activeCount,
		"state": state, "sourceComplete": done, "valid": len(invalid) == 0, "invalidReasons": invalid,
		"load": map[string]any{"kind": "synthetic public message content", "nativeEvent": "text-final", "stableItemID": true,
			"a4Semantics": "strict cumulative prefix; four ASCII source bytes per card event; not provider text-delta",
			"s4Semantics": "240-byte ASCII sliding replacement", "recordRecency": "fixed to isolate content from ordering",
			"provider":            "external Codex environment unavailable; production discovery/settings routes retained",
			"sourceRatePerSecond": rate, "sourceClock": "independent Go monotonic deadlines; no UI pacing"},
		"cpu": formal.CPU,
		"source": map[string]any{"planned": planned, "sent": len(events), "accepted": accepted,
			"warmupSent": warmup.Sent, "formalSent": formal.Sent, "tailSent": tail.Sent, "errors": errors,
			"nominalWarmupEvents": planned / 5, "nominalFormalEvents": planned * 4 / 5},
		"publish": map[string]any{"formalCount": formal.Publishes, "tailCount": tail.Publishes,
			"dirtyCardMean": formal.DirtyCardMean, "dirtyCardHistogram": formal.DirtyCardHistogram,
			"wireBytes": formal.EncodedNDJSONBytes, "mutationBytes": formal.MutationBytes,
			"wireByteMeaning": "production publication envelope encoded bytes including NDJSON newline; socket delivery unobserved"},
		"schedule": plan, "boundaries": boundaries,
		"windows": map[string]windowMeasurement{"warmup": warmup, "formal": formal, "tail": tail},
		"tail": map[string]any{"observationSeconds": tail.CPU.WallSeconds, "lastAcceptedUnixNano": lastAccepted,
			"lastPublicationUnixNano": lastPublication, "meaning": "post-formal observation interval; not a queue drain duration"},
		"expectedCards": b.expected, "finalCards": final, "sourceEvents": events, "publications": publications,
		"measurementClock": "actual boundary rusage user+system divided by actual monotonic wall seconds; single-core percent",
		"countWindows":     "half-open actual rusage boundary intervals; warmup and tail are never included in formal counts",
	}
}
