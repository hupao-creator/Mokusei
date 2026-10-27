package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

const (
	receiptRetention    = 24 * time.Hour
	newCommandWindow    = 5 * time.Minute
	maxFutureSkew       = 30 * time.Second
	maxReceipts         = 5000
	maxReceiptBytes     = 32 * 1024 * 1024
	pendingReserveBytes = 512
)

var newCommandPattern = regexp.MustCompile(`^([1-9][0-9]{0,15})_[A-Za-z0-9_-]{16,80}$`)
var fingerprintPattern = regexp.MustCompile(`^[a-fA-F0-9]{64}$`)

type receipt struct {
	CommandID   string  `json:"commandId"`
	Fingerprint string  `json:"fingerprint"`
	AdmittedAt  int64   `json:"admittedAt"`
	CompletedAt *int64  `json:"completedAt,omitempty"`
	Result      *Result `json:"result,omitempty"`
}
type pendingReceipt struct {
	done   chan struct{}
	result Result
}
type ReceiptStore struct {
	mu             sync.Mutex
	path           string
	receipts       map[string]receipt
	pending        map[string]*pendingReceipt
	storageFailure error
}

// OpenReceiptStore requires the profile ownership guard to remain held for the
// store's entire lifetime. Unknown crash outcomes are recovered, never replayed.
func OpenReceiptStore(path string) (*ReceiptStore, error) {
	store := &ReceiptStore{path: path, receipts: make(map[string]receipt), pending: make(map[string]*pendingReceipt)}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > maxReceiptBytes {
		return nil, model.NewError("RECEIPT_STORAGE_FAILED", "Unable to read the command receipt store")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, model.NewError("RECEIPT_STORAGE_FAILED", "Unable to read the command receipt store")
	}
	data, err := io.ReadAll(io.LimitReader(file, maxReceiptBytes+1))
	closeErr := file.Close()
	if err != nil || closeErr != nil || len(data) > maxReceiptBytes {
		return nil, model.NewError("RECEIPT_STORAGE_FAILED", "Unable to read the command receipt store")
	}
	var document struct {
		Version  int               `json:"version"`
		Receipts []json.RawMessage `json:"receipts"`
	}
	fail := func() (*ReceiptStore, error) {
		return nil, model.NewError("RECEIPT_STORAGE_FAILED", "Unable to recover the command receipt store; refusing to replay commands")
	}
	if err = json.Unmarshal(data, &document); err != nil || document.Version != 1 || document.Receipts == nil || len(document.Receipts) > maxReceipts {
		return fail()
	}
	now := time.Now().UnixMilli()
	for _, raw := range document.Receipts {
		var item receipt
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &item) != nil || json.Unmarshal(raw, &fields) != nil || fields == nil || len(fields["admittedAt"]) == 0 || bytes.Equal(bytes.TrimSpace(fields["admittedAt"]), []byte("null")) {
			return fail()
		}
		if item.Result != nil {
			var resultFields map[string]json.RawMessage
			if json.Unmarshal(fields["result"], &resultFields) != nil {
				return fail()
			}
			ok := bytes.TrimSpace(resultFields["ok"])
			if !bytes.Equal(ok, []byte("true")) && !bytes.Equal(ok, []byte("false")) {
				return fail()
			}
		}
		if !validReceipt(item) {
			return fail()
		}
		if _, exists := store.receipts[item.CommandID]; exists {
			return fail()
		}
		// Validate duplicates even if a prior entry expired.
		store.receipts[item.CommandID] = item
	}
	store.receipts = store.unexpiredLocked(now)
	for key, item := range store.receipts {
		if item.Result == nil {
			item.CompletedAt = &now
			result := indeterminate("The runtime stopped before recording the command outcome. Inspect current state before issuing a new command.")
			item.Result = &result
			store.receipts[key] = item
		}
	}
	encoded, err := encodeReceipts(store.receipts)
	if err != nil || !fitsReceipts(store.receipts, encoded) {
		return fail()
	}
	if err = profile.AtomicWrite(path, encoded); err != nil {
		return fail()
	}
	return store, nil
}
func validReceipt(item receipt) bool {
	if len(item.CommandID) == 0 || len(item.CommandID) > 256 || !fingerprintPattern.MatchString(item.Fingerprint) || item.AdmittedAt < 0 {
		return false
	}
	if (item.CompletedAt == nil) != (item.Result == nil) {
		return false
	}
	if item.CompletedAt != nil && *item.CompletedAt < 0 {
		return false
	}
	if item.Result != nil {
		if item.Result.OK {
			return len(item.Result.Value) > 0 && json.Valid(item.Result.Value) && item.Result.Error == nil
		}
		return item.Result.Error != nil && item.Result.Error.Code != "" && len(item.Result.Value) == 0
	}
	return true
}
func indeterminate(message string) Result {
	return resultFailure(model.NewError("COMMAND_OUTCOME_INDETERMINATE", message))
}
func validateNewCommand(id string, now int64) error {
	match := newCommandPattern.FindStringSubmatch(id)
	if match == nil {
		return model.NewError("INVALID_COMMAND_ID", "New command IDs must contain a Unix millisecond timestamp, an underscore, and 16–80 random characters")
	}
	created, err := strconv.ParseInt(match[1], 10, 64)
	if err != nil || created > 9007199254740991 {
		return model.NewError("INVALID_COMMAND_ID", "Invalid command ID timestamp")
	}
	if created-now > maxFutureSkew.Milliseconds() {
		return model.NewError("INVALID_COMMAND_ID", "The command ID timestamp is more than 30 seconds in the future")
	}
	if now-created > newCommandWindow.Milliseconds() {
		return model.NewError("COMMAND_ID_EXPIRED", "The command ID is too old for a new admission. Inspect current state before issuing a new command")
	}
	return nil
}

// Execute durably admits a command before executing it. The operation's lifetime
// is independent of the HTTP request: a disconnect must not cancel admitted work.
// Cancellation may stop a duplicate waiter; its original command keeps running.
func (s *ReceiptStore) Execute(ctx context.Context, id, fingerprint string, run func() (any, error)) (Result, error) {
	if len(id) == 0 || len(id) > 256 {
		return Result{}, model.NewError("INVALID_COMMAND_ID", "Command IDs must contain between 1 and 256 characters")
	}
	if !fingerprintPattern.MatchString(fingerprint) {
		return Result{}, model.NewError("INVALID_COMMAND_FINGERPRINT", "Command fingerprints must be SHA-256 hex digests")
	}
	s.mu.Lock()
	now := time.Now().UnixMilli()
	next := s.unexpiredLocked(now)
	if existing, ok := next[id]; ok {
		if existing.Fingerprint != fingerprint {
			s.mu.Unlock()
			return Result{}, model.NewError("COMMAND_ID_REUSED", "This command ID was already used for a different request")
		}
		if pending, active := s.pending[id]; active {
			s.mu.Unlock()
			select {
			case <-pending.done:
				return cloneResult(pending.result), nil
			case <-ctx.Done():
				return Result{}, ctx.Err()
			}
		}
		if existing.Result != nil {
			result := cloneResult(*existing.Result)
			s.mu.Unlock()
			return result, nil
		}
		s.mu.Unlock()
		return Result{}, model.NewError("RECEIPT_STORAGE_FAILED", "The command receipt has no available outcome")
	}
	if err := validateNewCommand(id, now); err != nil {
		s.mu.Unlock()
		return Result{}, err
	}
	if s.storageFailure != nil {
		err := s.storageFailure
		s.mu.Unlock()
		return Result{}, err
	}
	if len(next) >= maxReceipts {
		s.mu.Unlock()
		return Result{}, model.NewError("RECEIPT_CAPACITY_EXCEEDED", "Command receipt capacity is exhausted. Retry after receipts expire")
	}
	next[id] = receipt{CommandID: id, Fingerprint: fingerprint, AdmittedAt: now}
	document, err := encodeReceipts(next)
	if err != nil || !fitsReceipts(next, document) {
		s.mu.Unlock()
		return Result{}, model.NewError("RECEIPT_CAPACITY_EXCEEDED", "Command receipt storage is full. Retry after receipts expire")
	}
	if err = profile.AtomicWrite(s.path, document); err != nil {
		s.storageFailure = model.NewError("RECEIPT_STORAGE_FAILED", "Unable to durably admit the command. Restart the runtime before retrying")
		failure := s.storageFailure
		s.mu.Unlock()
		return Result{}, failure
	}
	pending := &pendingReceipt{done: make(chan struct{})}
	s.pending[id] = pending
	s.receipts = next
	s.mu.Unlock()
	var result Result
	func() {
		// A buggy handler must still settle its admitted receipt and release drain.
		defer func() {
			if recover() != nil {
				result = indeterminate("The command handler panicked before returning its outcome. Inspect current state before issuing a new command.")
			}
		}()
		value, runErr := run()
		if runErr != nil {
			result = resultFailure(runErr)
			return
		}
		raw, marshalErr := json.Marshal(value)
		if marshalErr != nil {
			result = indeterminate("The command ran, but its result was not JSON serializable. Inspect current state before issuing a new command.")
			return
		}
		result = Result{OK: true, Value: raw}
	}()
	s.mu.Lock()
	next = make(map[string]receipt, len(s.receipts))
	for key, item := range s.receipts {
		next[key] = item
	}
	completed := next[id]
	completedAt := time.Now().UnixMilli()
	completed.CompletedAt = &completedAt
	completed.Result = &result
	next[id] = completed
	document, err = encodeReceipts(next)
	if err != nil || !fitsReceipts(next, document) {
		result = indeterminate("The command ran, but its result exceeded receipt storage capacity. Inspect current state before issuing a new command.")
		completed.Result = &result
		next[id] = completed
		document, _ = encodeReceipts(next)
	}
	if err = profile.AtomicWrite(s.path, document); err != nil {
		result = indeterminate("The command ran, but its outcome could not be durably recorded. Inspect current state before issuing a new command.")
		completed.Result = &result
		next[id] = completed
		s.storageFailure = model.NewError("RECEIPT_STORAGE_FAILED", "Command receipt storage failed. Restart the runtime before issuing new commands")
	}
	s.receipts = next
	delete(s.pending, id)
	pending.result = cloneResult(result)
	close(pending.done)
	s.mu.Unlock()
	return cloneResult(result), nil
}
func (s *ReceiptStore) unexpiredLocked(now int64) map[string]receipt {
	next := make(map[string]receipt, len(s.receipts))
	for key, item := range s.receipts {
		if item.CompletedAt == nil || now-*item.CompletedAt < receiptRetention.Milliseconds() {
			next[key] = item
		}
	}
	return next
}
func encodeReceipts(items map[string]receipt) ([]byte, error) {
	// Stable output makes recovery reviewable; admission order has no semantics.
	keys := make([]string, 0, len(items))
	for key := range items {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	entries := make([]receipt, 0, len(items))
	for _, key := range keys {
		entries = append(entries, items[key])
	}
	return json.Marshal(struct {
		Version  int       `json:"version"`
		Receipts []receipt `json:"receipts"`
	}{1, entries})
}
func fitsReceipts(items map[string]receipt, document []byte) bool {
	size := len(document)
	for _, item := range items {
		if item.Result == nil {
			size += pendingReserveBytes
		}
	}
	return size <= maxReceiptBytes
}
func cloneResult(value Result) Result {
	value.Value = bytes.Clone(value.Value)
	if value.Error != nil {
		failure := *value.Error
		value.Error = &failure
	}
	return value
}
