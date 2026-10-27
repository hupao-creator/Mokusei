package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
)

const schemaVersion = 1
const applicationID = 0x4d4f4b53 // MOKS: Mokusei Go transaction store

type database struct{ handle *sqlite.DB }
type fatalDatabaseError struct{ err error }

func (e *fatalDatabaseError) Error() string {
	return "state database requires reopening: " + e.err.Error()
}
func (e *fatalDatabaseError) Unwrap() error { return e.err }

func openDatabase(path string) (_ *database, err error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err = file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, err
	}
	if err = file.Close(); err != nil {
		return nil, err
	}
	handle, err := sqlite.Open(path, false)
	if err != nil {
		return nil, err
	}
	db := &database{handle: handle}
	defer func() {
		if err != nil {
			_ = db.close()
		}
	}()
	version, err := db.integer("PRAGMA user_version")
	if err != nil {
		return nil, err
	}
	app, err := db.integer("PRAGMA application_id")
	if err != nil {
		return nil, err
	}
	if version == 0 && app == 0 {
		count, e := db.integer("SELECT count(*) FROM sqlite_master")
		if e != nil {
			return nil, e
		}
		if count != 0 {
			return nil, ErrInvalidState
		}
	} else if version != schemaVersion || app != applicationID {
		return nil, ErrInvalidState
	}
	if version == 0 {
		if err = db.exec("PRAGMA page_size=8192"); err != nil {
			return nil, err
		}
	}
	if err = db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON; PRAGMA wal_autocheckpoint=1000"); err != nil {
		return nil, err
	}
	mode, err := db.text("PRAGMA journal_mode")
	if err != nil {
		return nil, err
	}
	if mode != "wal" {
		return nil, errors.New("SQLite WAL mode unavailable")
	}
	sync, err := db.integer("PRAGMA synchronous")
	if err != nil {
		return nil, err
	}
	if sync != 2 {
		return nil, errors.New("SQLite FULL synchronous mode unavailable")
	}
	if version == 0 {
		err = db.exec(fmt.Sprintf(`BEGIN IMMEDIATE;
CREATE TABLE records (key TEXT PRIMARY KEY, body BLOB NOT NULL CHECK(length(body)<=52428800)) STRICT;
CREATE TABLE entity_order (kind TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0), id TEXT NOT NULL, PRIMARY KEY(kind,position), UNIQUE(kind,id)) STRICT;
CREATE TABLE store_meta (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL CHECK(revision>=0)) STRICT;
INSERT INTO store_meta VALUES (1,0);
PRAGMA application_id=%d;
PRAGMA user_version=%d;
COMMIT;`, applicationID, schemaVersion))
		if err != nil {
			_ = db.exec("ROLLBACK")
			return nil, err
		}
	}
	if err = db.validateSchema(); err != nil {
		return nil, err
	}
	return db, nil
}

func (d *database) validateSchema() error {
	// Version and application ID are not sufficient: reject additional objects
	// (including triggers), or altered constraints, in an otherwise marked file.
	expected := map[string]string{
		"records":      "CREATE TABLE records (key TEXT PRIMARY KEY, body BLOB NOT NULL CHECK(length(body)<=52428800)) STRICT",
		"entity_order": "CREATE TABLE entity_order (kind TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0), id TEXT NOT NULL, PRIMARY KEY(kind,position), UNIQUE(kind,id)) STRICT",
		"store_meta":   "CREATE TABLE store_meta (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL CHECK(revision>=0)) STRICT",
	}
	s, err := d.prepare("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL")
	if err != nil {
		return err
	}
	defer s.Close()
	for {
		row, err := s.Step()
		if err != nil {
			return err
		}
		if !row {
			break
		}
		name, definition := s.Text(0), s.Text(1)
		if expected[name] != definition {
			return ErrInvalidState
		}
		delete(expected, name)
	}
	if len(expected) != 0 {
		return ErrInvalidState
	}
	return nil
}

func (d *database) load() (_ *snapshotData, err error) {
	if err = d.exec("BEGIN"); err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			_ = d.exec("ROLLBACK")
		}
	}()
	data := &snapshotData{records: make(map[string]*storedRecord), orders: make(map[string][]string)}
	if err = d.readMeta(data); err != nil {
		return nil, err
	}
	if err = d.readRecords(data); err != nil {
		return nil, err
	}
	if err = d.readOrders(data); err != nil {
		return nil, err
	}
	if err = d.exec("COMMIT"); err != nil {
		return nil, err
	}
	return data, nil
}

func (d *database) readMeta(data *snapshotData) error {
	s, err := d.prepare("SELECT id,revision FROM store_meta")
	if err != nil {
		return err
	}
	defer s.Close()
	row, err := s.Step()
	if err != nil {
		return err
	}
	if !row || s.Integer(0) != 1 || s.Integer(1) < 0 {
		return ErrInvalidState
	}
	data.revision = uint64(s.Integer(1))
	data.eventRevision = data.revision
	data.lifecycleRevision = data.revision
	row, err = s.Step()
	if err != nil {
		return err
	}
	if row {
		return ErrInvalidState
	}
	return nil
}
func (d *database) readRecords(data *snapshotData) error {
	sizes, err := d.prepare("SELECT key,length(body) FROM records")
	if err != nil {
		return err
	}
	for {
		row, e := sizes.Step()
		if e != nil {
			_ = sizes.Close()
			return e
		}
		if !row {
			break
		}
		if e = validKey(sizes.Text(0)); e != nil {
			_ = sizes.Close()
			return ErrInvalidState
		}
		if n := sizes.Integer(1); n < 1 || n > MaxRecordBytes {
			_ = sizes.Close()
			return ErrRecordTooLarge
		}
	}
	if err = sizes.Close(); err != nil {
		return err
	}
	s, err := d.prepare("SELECT key,body FROM records")
	if err != nil {
		return err
	}
	defer s.Close()
	for {
		row, e := s.Step()
		if e != nil {
			return e
		}
		if !row {
			break
		}
		raw := s.Blob(1)
		if !utf8.Valid(raw) || !json.Valid(raw) {
			return ErrInvalidState
		}
		data.records[s.Text(0)] = newStoredRecord(raw)
	}
	return nil
}
func (d *database) readOrders(data *snapshotData) error {
	s, err := d.prepare("SELECT kind,position,id FROM entity_order ORDER BY kind,position")
	if err != nil {
		return err
	}
	defer s.Close()
	for {
		row, e := s.Step()
		if e != nil {
			return e
		}
		if !row {
			break
		}
		kind, id := s.Text(0), s.Text(2)
		if validKey(kind) != nil || validKey(id) != nil || s.Integer(1) != int64(len(data.orders[kind])) {
			return ErrInvalidState
		}
		data.orders[kind] = append(data.orders[kind], id)
	}
	return nil
}

func (d *database) commit(tx *Tx, revision uint64) (err error) {
	if err = d.exec("BEGIN IMMEDIATE"); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			if !d.handle.AutoCommit() {
				if rollback := d.exec("ROLLBACK"); rollback != nil {
					err = &fatalDatabaseError{errors.Join(err, rollback)}
				}
			} else {
				// SQLite may auto-roll back after an I/O error. Do not continue
				// from an assumed in-memory baseline after uncertain storage I/O.
				err = &fatalDatabaseError{err}
			}
		}
	}()
	keys := make([]string, 0, len(tx.writes))
	for key := range tx.writes {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if body := tx.writes[key]; body == nil {
			err = d.run("DELETE FROM records WHERE key=?", key)
		} else {
			err = d.run("INSERT INTO records(key,body) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET body=excluded.body", key, []byte(body.body))
		}
		if err != nil {
			return err
		}
	}
	kinds := make([]string, 0, len(tx.orders))
	for kind := range tx.orders {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	for _, kind := range kinds {
		if err = d.run("DELETE FROM entity_order WHERE kind=?", kind); err != nil {
			return err
		}
		for i, id := range tx.orders[kind] {
			if err = d.run("INSERT INTO entity_order(kind,position,id) VALUES (?,?,?)", kind, int64(i), id); err != nil {
				return err
			}
		}
	}
	if err = d.run("UPDATE store_meta SET revision=? WHERE id=1", int64(revision)); err != nil {
		return err
	}
	return d.exec("COMMIT")
}

func (d *database) close() error                                  { return d.handle.Close() }
func (d *database) exec(sql string) error                         { return d.handle.Exec(sql) }
func (d *database) prepare(sql string) (*sqlite.Statement, error) { return d.handle.Prepare(sql) }
func (d *database) run(sql string, args ...any) error             { return d.handle.Exec(sql, args...) }
func (d *database) integer(sql string) (int64, error) {
	s, err := d.prepare(sql)
	if err != nil {
		return 0, err
	}
	defer s.Close()
	row, err := s.Step()
	if err != nil {
		return 0, err
	}
	if !row {
		return 0, ErrInvalidState
	}
	return s.Integer(0), nil
}
func (d *database) text(sql string) (string, error) {
	s, err := d.prepare(sql)
	if err != nil {
		return "", err
	}
	defer s.Close()
	row, err := s.Step()
	if err != nil {
		return "", err
	}
	if !row {
		return "", ErrInvalidState
	}
	return s.Text(0), nil
}
