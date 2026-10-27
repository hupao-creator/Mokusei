package moku

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

const ledgerSchemaVersion = 2

type LedgerOptions struct {
	WriteSnapshot                func(context.Context, string, []byte) error
	Now                          func() time.Time
	FlushDebounce                time.Duration
	OnBackgroundPersistenceError func(error)
}

// TelemetryLedger is scoped by composition to one Harness and one private file.
// Neither samples nor persisted facts contain a provider identity; only the
// owning Harness resolves native model names and opaque attribution keys.
type TelemetryLedger struct {
	Path           string
	mu             sync.Mutex
	windows        []ledgerWindow
	recentIDs      []string
	recentSet      map[string]struct{}
	pending        []pendingUsage
	pendingSet     map[string]struct{}
	pendingBytes   int
	dirty          bool
	disposed       bool
	timer          *time.Timer
	timerVersion   uint64
	flushGate      chan struct{}
	closeDone      chan struct{}
	closeErr       error
	writeSnapshot  func(context.Context, string, []byte) error
	now            func() time.Time
	debounce       time.Duration
	backgroundFail func(error)
}

var _ plugin.TelemetryLedger = (*TelemetryLedger)(nil)

type ledgerPersistedSnapshot struct {
	SchemaVersion           int            `json:"schemaVersion"`
	GeneratedAt             float64        `json:"generatedAt"`
	Windows                 []ledgerWindow `json:"windows"`
	RecentSampleIDs         []string       `json:"recentSampleIds"`
	PendingExecutionSamples []pendingUsage `json:"pendingExecutionSamples"`
}

func OpenTelemetryLedger(path string, options LedgerOptions) (*TelemetryLedger, error) {
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.FlushDebounce <= 0 {
		options.FlushDebounce = 15 * time.Second
	}
	if options.WriteSnapshot == nil {
		options.WriteSnapshot = func(ctx context.Context, path string, data []byte) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				return err
			}
			return profile.AtomicWrite(path, data)
		}
	}
	ledger := &TelemetryLedger{
		Path: path, windows: []ledgerWindow{}, recentIDs: []string{}, pending: []pendingUsage{},
		recentSet: make(map[string]struct{}), pendingSet: make(map[string]struct{}),
		flushGate: make(chan struct{}, 1), now: options.Now, debounce: options.FlushDebounce,
		writeSnapshot: options.WriteSnapshot, backgroundFail: options.OnBackgroundPersistenceError,
	}
	ledger.flushGate <- struct{}{}
	if snapshot, err := loadLedgerSnapshot(path); err == nil {
		ledger.windows = snapshot.Windows
		ledger.recentIDs = snapshot.RecentSampleIDs
		ledger.pending = snapshot.PendingExecutionSamples
	} else if !errors.Is(err, os.ErrNotExist) {
		// A malformed current-format ledger is quarantined rather than migrated or
		// partially trusted. Quarantine failures must not prevent runtime startup.
		_ = os.Rename(path, path+".corrupt-"+strconv.FormatInt(ledger.now().UnixMilli(), 10))
	}
	for _, id := range ledger.recentIDs {
		ledger.recentSet[id] = struct{}{}
	}
	for _, sample := range ledger.pending {
		ledger.pendingSet[sample["sampleId"].(string)] = struct{}{}
		ledger.pendingBytes += pendingUsageBytes(sample)
	}
	return ledger, nil
}

func (l *TelemetryLedger) Record(ctx context.Context, raw json.RawMessage) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	var sample map[string]any
	if err := json.Unmarshal(raw, &sample); err != nil || sample == nil {
		return errors.New("invalid Moku telemetry sample")
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.disposed {
		return errors.New("Moku telemetry ledger 已关闭")
	}
	changed := false
	switch sample["type"] {
	case "execution-usage":
		id, _ := sample["sampleId"].(string)
		if !validSampleID(id) {
			return nil
		}
		if _, exists := l.recentSet[id]; exists {
			return nil
		}
		if _, exists := l.pendingSet[id]; exists {
			return nil
		}
		normalized, valid := normalizeExecutionUsageSample(sample)
		if !valid {
			return nil
		}
		if len(l.windows) == 0 {
			l.rememberPendingLocked(normalized)
		} else {
			l.applyExecutionUsageLocked(normalized)
			// An inapplicable substantive sample is consumed once real windows
			// exist. Otherwise it could form an unbounded deferred retry queue.
			l.rememberIDLocked(id)
		}
		changed = true
	case "window-reading":
		if _, ok := sample["windows"].([]any); !ok {
			return errors.New("invalid Moku telemetry windows")
		}
		changed = l.recordWindowReadingLocked(sample)
	default:
		return errors.New("invalid Moku telemetry sample type")
	}
	if changed {
		l.markDirtyLocked()
	}
	return nil
}

func (l *TelemetryLedger) Read(ctx context.Context) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	windows := make([]any, 0, len(l.windows))
	for _, window := range l.windows {
		completed := make([]any, 0, len(window.Completed))
		for _, cycle := range window.Completed {
			completed = append(completed, publicLedgerCycle(cycle))
		}
		windows = append(windows, map[string]any{
			"id": window.ID, "metering": window.Metering,
			"ledger": map[string]any{"currentCycle": publicLedgerCycle(window.Current), "completedCycles": completed},
		})
	}
	return ledgerJSON(map[string]any{"windows": windows})
}

// Flush persists every mutation visible when, or while, the write is running.
// Only the I/O is serialized: adapters may continue recording while the disk
// write is in flight, and the flush then takes another authoritative snapshot.
func (l *TelemetryLedger) Flush(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	l.mu.Lock()
	l.clearTimerLocked()
	l.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-l.flushGate:
	}
	defer func() { l.flushGate <- struct{}{} }()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		l.mu.Lock()
		if !l.dirty {
			l.mu.Unlock()
			return nil
		}
		data, err := l.snapshotJSONLocked()
		if err != nil {
			l.mu.Unlock()
			return err
		}
		l.dirty = false
		l.mu.Unlock()
		if err := callLedgerWriter(ctx, l.writeSnapshot, l.Path, data); err != nil {
			l.mu.Lock()
			l.dirty = true
			l.mu.Unlock()
			return err
		}
	}
}

func (l *TelemetryLedger) Drain(ctx context.Context) error { return l.Flush(ctx) }

// Close revokes new samples synchronously and shares one durable shutdown among
// callers. A canceled waiter does not abandon the underlying persistence work.
func (l *TelemetryLedger) Close(ctx context.Context) error {
	l.mu.Lock()
	if l.closeDone == nil {
		l.disposed = true
		l.clearTimerLocked()
		l.closeDone = make(chan struct{})
		go func() {
			err := l.Flush(context.Background())
			l.mu.Lock()
			l.closeErr = err
			close(l.closeDone)
			l.mu.Unlock()
		}()
	}
	done := l.closeDone
	l.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-done:
		l.mu.Lock()
		defer l.mu.Unlock()
		return l.closeErr
	}
}

func (l *TelemetryLedger) applyExecutionUsageLocked(sample pendingUsage) {
	additive := sample["usageKind"] == "generation"
	_, hasUncached := nonnegativeNumber(sample["uncachedInputTokens"])
	hasTokens := false
	if additive {
		for _, field := range ledgerTokenFields {
			if field == "inputTokens" && hasUncached {
				continue
			}
			if _, valid := positiveNumber(sample[field]); valid {
				hasTokens = true
				break
			}
		}
	}
	cost, hasCost := positiveNumber(sample["costUsd"])
	observedAt, _ := finiteNumber(sample["observedAt"])
	model, _ := sample["model"].(string)
	for index := range l.windows {
		window := &l.windows[index]
		if !usageAppliesToLedger(sample, window.UsageAttribution) ||
			(window.Current.ClosesAt != nil && observedAt > *window.Current.ClosesAt) ||
			(window.Metering == "monetary" && !hasCost) {
			continue
		}
		row := modelRow(&window.Current, model)
		if additive {
			prior, _ := finiteNumber(row["usageEvents"])
			row["usageEvents"] = boundedSum(prior, 1)
		}
		if window.Metering != "monetary" && hasTokens {
			for _, field := range ledgerTokenFields {
				if field == "inputTokens" && hasUncached {
					continue
				}
				if value, valid := positiveNumber(sample[field]); valid {
					prior, _ := finiteNumber(row[field])
					row[field] = boundedSum(prior, value)
				}
			}
		}
		if hasCost {
			prior, _ := finiteNumber(row["costUsd"])
			row["costUsd"] = boundedSum(prior, cost)
		}
	}
}

func (l *TelemetryLedger) recordWindowReadingLocked(sample map[string]any) bool {
	if !validTimestamp(sample["observedAt"]) {
		return false
	}
	observedAt, _ := finiteNumber(sample["observedAt"])
	changed := false
	for _, item := range sample["windows"].([]any) {
		candidate, ok := item.(map[string]any)
		if !ok {
			continue
		}
		id := normalizedIdentifier(candidate["id"])
		metering, _ := candidate["metering"].(string)
		if id == "" || (metering != "token" && metering != "request" && metering != "monetary" && metering != "credit") {
			continue
		}
		existing := -1
		for index := range l.windows {
			if l.windows[index].ID == id {
				existing = index
				break
			}
		}
		if metering == "request" {
			if existing >= 0 {
				l.windows = append(l.windows[:existing], l.windows[existing+1:]...)
				changed = true
			}
			continue
		}
		reading := normalizedLedgerReading(observedAt, candidate)
		boundary := ledgerCycleBoundary(observedAt, candidate)
		if existing >= 0 && observedAt < l.windows[existing].Current.Latest.ObservedAt {
			continue
		}
		attribution, valid := normalizeUsageAttribution(candidate["usageAttribution"])
		if !valid {
			attribution = ledgerAttribution{Type: "unknown"}
		}
		if existing < 0 || l.windows[existing].Metering != metering || !reflect.DeepEqual(l.windows[existing].UsageAttribution, attribution) {
			if existing >= 0 {
				l.windows = append(l.windows[:existing], l.windows[existing+1:]...)
			}
			l.windows = append(l.windows, ledgerWindow{ID: id, Metering: metering, UsageAttribution: attribution, Current: newLedgerCycle(reading, boundary), Completed: []ledgerCycle{}})
			for len(l.windows) > ledgerMaxWindows {
				l.windows = dropStalestWindow(l.windows)
			}
			sortLedgerWindows(l.windows)
			changed = true
			continue
		}
		window := &l.windows[existing]
		if ledgerCycleClosed(window.Current, reading) {
			if len(window.Current.ByModel) > 0 {
				window.Completed = append([]ledgerCycle{window.Current}, window.Completed...)
				if len(window.Completed) > ledgerMaxCompletedCycles {
					window.Completed = window.Completed[:ledgerMaxCompletedCycles]
				}
			}
			window.Current = newLedgerCycle(reading, boundary)
		} else {
			window.Current.Latest = reading
		}
		changed = true
	}
	if len(l.windows) > 0 && len(l.pending) > 0 {
		pending := l.pending
		l.pending = []pendingUsage{}
		l.pendingSet = make(map[string]struct{})
		l.pendingBytes = 0
		for _, sample := range pending {
			l.applyExecutionUsageLocked(sample)
			l.rememberIDLocked(sample["sampleId"].(string))
		}
		changed = true
	}
	return changed
}

func (l *TelemetryLedger) rememberPendingLocked(sample pendingUsage) {
	l.pending = append(l.pending, sample)
	l.pendingBytes += pendingUsageBytes(sample)
	l.pendingSet[sample["sampleId"].(string)] = struct{}{}
	for len(l.pending) > ledgerMaxPendingSamples || l.pendingBytes > ledgerMaxPendingBytes {
		expired := l.pending[0]
		l.pending[0] = nil
		l.pending = l.pending[1:]
		l.pendingBytes -= pendingUsageBytes(expired)
		id := expired["sampleId"].(string)
		delete(l.pendingSet, id)
		l.rememberIDLocked(id)
	}
}

func (l *TelemetryLedger) rememberIDLocked(id string) {
	l.recentIDs = append(l.recentIDs, id)
	l.recentSet[id] = struct{}{}
	for len(l.recentIDs) > ledgerMaxRecentIDs {
		delete(l.recentSet, l.recentIDs[0])
		l.recentIDs[0] = ""
		l.recentIDs = l.recentIDs[1:]
	}
}

func (l *TelemetryLedger) markDirtyLocked() {
	l.dirty = true
	l.clearTimerLocked()
	version := l.timerVersion
	l.timer = time.AfterFunc(l.debounce, func() {
		l.mu.Lock()
		if l.disposed || version != l.timerVersion {
			l.mu.Unlock()
			return
		}
		l.timer = nil
		l.mu.Unlock()
		if err := l.Flush(context.Background()); err != nil && l.backgroundFail != nil {
			func() {
				defer func() { _ = recover() }()
				l.backgroundFail(err)
			}()
		}
	})
}

func (l *TelemetryLedger) clearTimerLocked() {
	l.timerVersion++
	if l.timer != nil {
		l.timer.Stop()
		l.timer = nil
	}
}

func newLedgerCycle(reading ledgerReading, boundary *float64) ledgerCycle {
	return ledgerCycle{First: reading, Latest: reading, ClosesAt: boundary, ByModel: []ledgerModelTotals{}}
}

func ledgerCycleClosed(cycle ledgerCycle, reading ledgerReading) bool {
	if cycle.ClosesAt != nil && reading.ObservedAt > *cycle.ClosesAt {
		return true
	}
	previous := cycle.Latest
	if previous.UsedPercent != nil && reading.UsedPercent != nil {
		drop := *previous.UsedPercent - *reading.UsedPercent
		if drop >= 30 {
			return true
		}
		return previous.UsedUnits != nil && reading.UsedUnits != nil && *reading.UsedUnits < *previous.UsedUnits && drop >= 1
	}
	return false
}

func normalizedLedgerReading(observedAt float64, value map[string]any) ledgerReading {
	reading := ledgerReading{ObservedAt: observedAt}
	if number, valid := finiteNumber(value["usedPercent"]); valid {
		reading.UsedPercent = &number
	}
	if number, valid := nonnegativeNumber(value["usedUnits"]); valid {
		reading.UsedUnits = &number
	}
	if number, valid := nonnegativeNumber(value["limitUnits"]); valid {
		reading.LimitUnits = &number
	}
	return reading
}

func ledgerCycleBoundary(observedAt float64, value map[string]any) *float64 {
	if text, ok := value["resetsAt"].(string); ok {
		for _, layout := range []string{time.RFC3339Nano, time.RFC1123, time.RFC1123Z, time.RFC850, time.ANSIC, "2006-01-02", "2006-01-02T15:04:05", "2006-01-02T15:04"} {
			location := time.UTC
			if layout == "2006-01-02T15:04:05" || layout == "2006-01-02T15:04" {
				location = time.Local
			}
			parsed, err := time.ParseInLocation(layout, text, location)
			if err == nil {
				boundary := float64(parsed.UnixMilli())
				if validTimestamp(boundary) && boundary >= observedAt {
					return &boundary
				}
			}
		}
	}
	if duration, valid := positiveNumber(value["durationMinutes"]); valid {
		boundary := observedAt + duration*60000
		if validTimestamp(boundary) {
			return &boundary
		}
	}
	return nil
}

func usageAppliesToLedger(sample pendingUsage, attribution ledgerAttribution) bool {
	if attribution.Type == "all" {
		return true
	}
	if attribution.Type != "matching" {
		return false
	}
	keys, _ := ledgerArray(sample["attributionKeys"])
	for _, expected := range attribution.Keys {
		for _, actual := range keys {
			if actual == expected {
				return true
			}
		}
	}
	return false
}

func publicLedgerCycle(cycle ledgerCycle) any {
	return map[string]any{"firstReading": publicLedgerReading(cycle.First), "latestReading": publicLedgerReading(cycle.Latest), "byModel": cycle.ByModel}
}

func publicLedgerReading(reading ledgerReading) any {
	at := time.UnixMilli(int64(math.Trunc(reading.ObservedAt))).UTC()
	formatted := at.Format("2006-01-02T15:04:05.000Z")
	if at.Year() > 9999 {
		formatted = fmt.Sprintf("+%06d", at.Year()) + at.Format("-01-02T15:04:05.000Z")
	}
	result := map[string]any{"at": formatted, "usedPercent": reading.UsedPercent}
	if reading.UsedUnits != nil {
		result["usedUnits"] = *reading.UsedUnits
	}
	if reading.LimitUnits != nil {
		result["limitUnits"] = *reading.LimitUnits
	}
	return result
}

func loadLedgerSnapshot(path string) (ledgerPersistedSnapshot, error) {
	file, err := os.Open(path)
	if err != nil {
		return ledgerPersistedSnapshot{}, err
	}
	defer file.Close()
	metadata, err := file.Stat()
	if err != nil || !metadata.Mode().IsRegular() || metadata.Size() > ledgerMaxFileBytes {
		return ledgerPersistedSnapshot{}, errors.New("ledger exceeds hard file bound or is not a regular file")
	}
	raw, err := io.ReadAll(io.LimitReader(file, ledgerMaxFileBytes+1))
	if err != nil {
		return ledgerPersistedSnapshot{}, err
	}
	if len(raw) > ledgerMaxFileBytes {
		return ledgerPersistedSnapshot{}, errors.New("ledger exceeds hard file bound")
	}
	var value map[string]any
	if json.Unmarshal(raw, &value) != nil || !ledgerOnlyKeys(value, []string{"schemaVersion", "generatedAt", "windows", "recentSampleIds", "pendingExecutionSamples"}) ||
		value["schemaVersion"] != float64(ledgerSchemaVersion) || !validTimestamp(value["generatedAt"]) {
		return ledgerPersistedSnapshot{}, errors.New("invalid current Moku telemetry ledger schema")
	}
	windowValues, valid := value["windows"].([]any)
	if !valid {
		return ledgerPersistedSnapshot{}, errors.New("invalid current Moku telemetry ledger windows")
	}
	windows := normalizeWindows(windowValues)
	if len(windows) != len(windowValues) {
		return ledgerPersistedSnapshot{}, errors.New("invalid current Moku telemetry ledger window")
	}
	recent, valid := normalizeRecentSampleIDs(value["recentSampleIds"])
	if !valid {
		return ledgerPersistedSnapshot{}, errors.New("invalid current Moku telemetry ledger sample ids")
	}
	pending, valid := normalizePendingExecutionSamples(value["pendingExecutionSamples"])
	if !valid {
		return ledgerPersistedSnapshot{}, errors.New("invalid current Moku telemetry ledger pending samples")
	}
	seen := make(map[string]struct{}, len(recent))
	for _, id := range recent {
		seen[id] = struct{}{}
	}
	for _, sample := range pending {
		if _, exists := seen[sample["sampleId"].(string)]; exists {
			return ledgerPersistedSnapshot{}, errors.New("overlapping current Moku telemetry ledger sample ids")
		}
	}
	return ledgerPersistedSnapshot{SchemaVersion: ledgerSchemaVersion, GeneratedAt: value["generatedAt"].(float64), Windows: windows, RecentSampleIDs: recent, PendingExecutionSamples: pending}, nil
}

func (l *TelemetryLedger) snapshotJSONLocked() ([]byte, error) {
	// Normalize detached copies, so bounded persistence compaction cannot mutate
	// the current in-memory window or lose a pending sample's exact-once identity.
	encoded, err := ledgerJSON(ledgerPersistedSnapshot{SchemaVersion: ledgerSchemaVersion, Windows: l.windows, RecentSampleIDs: l.recentIDs, PendingExecutionSamples: l.pending})
	if err != nil {
		return nil, err
	}
	var copied map[string]any
	if err := json.Unmarshal(encoded, &copied); err != nil {
		return nil, err
	}
	pending, valid := normalizePendingExecutionSamples(copied["pendingExecutionSamples"])
	if !valid {
		return nil, errors.New("invalid in-memory Moku telemetry ledger pending samples")
	}
	recent, valid := normalizeRecentSampleIDs(copied["recentSampleIds"])
	if !valid {
		recent = []string{}
	}
	generatedAt := float64(l.now().UnixMilli())
	if !validTimestamp(generatedAt) {
		generatedAt = float64(time.Now().UnixMilli())
	}
	snapshot := ledgerPersistedSnapshot{SchemaVersion: ledgerSchemaVersion, GeneratedAt: generatedAt, Windows: normalizeWindows(copied["windows"]), RecentSampleIDs: recent, PendingExecutionSamples: pending}
	encoded, err = ledgerJSON(snapshot)
	if err != nil {
		return nil, err
	}
	for len(encoded) > ledgerMaxFileBytes && dropOldestLedgerCompleted(snapshot.Windows) {
		encoded, err = ledgerJSON(snapshot)
		if err != nil {
			return nil, err
		}
	}
	for len(encoded) > ledgerMaxFileBytes && len(snapshot.Windows) > 0 {
		snapshot.Windows = dropStalestWindow(snapshot.Windows)
		encoded, err = ledgerJSON(snapshot)
		if err != nil {
			return nil, err
		}
	}
	for len(encoded) > ledgerMaxFileBytes && len(snapshot.RecentSampleIDs) > 0 {
		snapshot.RecentSampleIDs = snapshot.RecentSampleIDs[1:]
		encoded, err = ledgerJSON(snapshot)
		if err != nil {
			return nil, err
		}
	}
	if len(encoded) > ledgerMaxFileBytes {
		return nil, errors.New("Moku telemetry ledger exceeds hard file bound")
	}
	return encoded, nil
}

func dropOldestLedgerCompleted(windows []ledgerWindow) bool {
	selected := -1
	oldest := math.Inf(1)
	for index := range windows {
		cycles := windows[index].Completed
		if len(cycles) > 0 && cycles[len(cycles)-1].Latest.ObservedAt < oldest {
			selected = index
			oldest = cycles[len(cycles)-1].Latest.ObservedAt
		}
	}
	if selected < 0 {
		return false
	}
	window := &windows[selected]
	window.Completed = window.Completed[:len(window.Completed)-1]
	return true
}

func callLedgerWriter(ctx context.Context, writer func(context.Context, string, []byte) error, path string, data []byte) (err error) {
	defer func() {
		if value := recover(); value != nil {
			err = fmt.Errorf("Moku telemetry persistence panicked: %v", value)
		}
	}()
	return writer(ctx, path, data)
}
