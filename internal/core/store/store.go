// Package store owns the durable, serialized state boundary. Values and ordering
// are committed in one SQLite transaction and published only after COMMIT.
package store

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
)

const MaxRecordBytes = 50 * 1024 * 1024

var (
	ErrClosed         = errors.New("state store is closed")
	ErrLocked         = errors.New("state store is already open")
	ErrExpired        = errors.New("state transaction has expired")
	ErrInvalidState   = errors.New("state database does not match the current format")
	ErrRecordTooLarge = errors.New("state record exceeds 50 MiB")
)

// Store has one ordered writer. Snapshots never expose its backing byte slices.
// The callback supplied to Update must not recursively call Update or Close.
type Store struct {
	path          string
	db            *database
	lock          *os.File
	current       atomic.Pointer[snapshotData]
	admission     sync.Mutex
	closing       bool
	requests      chan request
	closed        chan struct{}
	closeErr      error
	fatal         error // writer goroutine only
	subscribersMu sync.Mutex
	subscribers   map[chan uint64]struct{}
}

type request struct {
	ctx   context.Context
	apply func(*Tx) error
	close bool
	reply chan result
}
type result struct {
	snapshot Snapshot
	err      error
}

// Open creates the current format or reopens it. Foreign schemas are rejected;
// the caller selects a new path when making an incompatible format change.
func Open(path string) (*Store, error) {
	if path == "" || path == ":memory:" {
		return nil, errors.New("state store requires a durable file path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Dir(abs), 0o700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(abs+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrLocked
		}
		return nil, err
	}
	release := func() { _ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN); _ = lock.Close() }
	db, err := openDatabase(abs)
	if err != nil {
		release()
		return nil, err
	}
	data, err := db.load()
	if err != nil {
		_ = db.close()
		release()
		return nil, err
	}
	if err = validateLifecycle(Snapshot{data}); err != nil {
		_ = db.close()
		release()
		return nil, err
	}
	s := &Store{path: abs, db: db, lock: lock, requests: make(chan request, 128), closed: make(chan struct{}), subscribers: make(map[chan uint64]struct{})}
	s.current.Store(data)
	go s.run()
	return s, nil
}

func (s *Store) Path() string       { return s.path }
func (s *Store) Snapshot() Snapshot { return Snapshot{s.current.Load()} }

// Update evaluates against the latest committed state, then commits every
// changed record and order atomically. Cancellation can prevent a transaction;
// once it starts we await its definite outcome, even if ctx is cancelled.
func (s *Store) Update(ctx context.Context, apply func(*Tx) error) (Snapshot, error) {
	if ctx == nil {
		return Snapshot{}, errors.New("nil update context")
	}
	if apply == nil {
		return Snapshot{}, errors.New("nil state transaction")
	}
	r := request{ctx: ctx, apply: apply, reply: make(chan result, 1)}
	s.admission.Lock()
	if s.closing {
		s.admission.Unlock()
		return Snapshot{}, ErrClosed
	}
	select {
	case <-ctx.Done():
		s.admission.Unlock()
		return Snapshot{}, ctx.Err()
	case s.requests <- r:
		s.admission.Unlock()
	}
	answer := <-r.reply
	return answer.snapshot, answer.err
}

// Flush waits behind all previously admitted transactions. Updates are durable
// when they return, so no deferred write or process-local journal is involved.
func (s *Store) Flush(ctx context.Context) error {
	_, err := s.Update(ctx, func(*Tx) error { return nil })
	return err
}

// Subscribe reports committed revisions and includes the current revision.
// Slow readers receive the newest revision; they must reread Snapshot rather
// than treating these notifications as a durable event stream.
func (s *Store) Subscribe() (<-chan uint64, func()) {
	ch := make(chan uint64, 1)
	s.subscribersMu.Lock()
	select {
	case <-s.closed:
		close(ch)
	default:
		s.subscribers[ch] = struct{}{}
		ch <- s.Snapshot().Revision()
	}
	s.subscribersMu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			s.subscribersMu.Lock()
			defer s.subscribersMu.Unlock()
			if _, ok := s.subscribers[ch]; ok {
				delete(s.subscribers, ch)
				close(ch)
			}
		})
	}
}

// Close fences new admissions, drains accepted work, and closes SQLite before
// releasing the file lock. A close failure retains ownership and is returned to
// the process owner; repeated calls report the same outcome.
func (s *Store) Close() error {
	s.admission.Lock()
	if !s.closing {
		s.closing = true
		s.requests <- request{close: true}
	}
	s.admission.Unlock()
	<-s.closed
	return s.closeErr
}

func (s *Store) run() {
	for r := range s.requests {
		if r.close {
			err := s.db.close()
			s.closeErr = errors.Join(s.fatal, err)
			if s.closeErr == nil {
				s.closeErr = errors.Join(syscall.Flock(int(s.lock.Fd()), syscall.LOCK_UN), s.lock.Close())
			}
			s.subscribersMu.Lock()
			close(s.closed)
			for ch := range s.subscribers {
				delete(s.subscribers, ch)
				close(ch)
			}
			s.subscribersMu.Unlock()
			return
		}
		snapshot, err := s.execute(r)
		r.reply <- result{snapshot, err}
	}
}

func (s *Store) execute(r request) (Snapshot, error) {
	if s.fatal != nil {
		return Snapshot{}, s.fatal
	}
	if err := r.ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	before := s.Snapshot()
	tx := newTx(before)
	if err := invoke(r.apply, tx); err != nil {
		return Snapshot{}, err
	}
	if err := r.ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	if !tx.changed() {
		return before, nil
	}
	next := tx.snapshot()
	if err := validateLifecycleChanges(tx, next); err != nil {
		return Snapshot{}, err
	}
	if before.Revision() == math.MaxInt64 {
		return Snapshot{}, errors.New("state revision exhausted")
	}
	next.data.revision = before.Revision() + 1
	if err := s.db.commit(tx, next.Revision()); err != nil {
		var fatal *fatalDatabaseError
		if errors.As(err, &fatal) {
			s.fatal = err
		}
		return Snapshot{}, err
	}
	s.current.Store(next.data)
	s.subscribersMu.Lock()
	for ch := range s.subscribers {
		select {
		case ch <- next.Revision():
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- next.Revision():
			default:
			}
		}
	}
	s.subscribersMu.Unlock()
	return next, nil
}

func invoke(apply func(*Tx) error, tx *Tx) (err error) {
	defer func() {
		tx.active = false
		if p := recover(); p != nil {
			err = fmt.Errorf("state transaction panicked: %v", p)
		}
	}()
	return apply(tx)
}
