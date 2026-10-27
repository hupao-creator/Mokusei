// Package sqlite provides a small binding to the system SQLite library. It
// never invokes a CLI or loads a Node module. Callers own connection scheduling
// and must not close a connection concurrently with one of its operations.
package sqlite

/*
#cgo LDFLAGS: -lsqlite3
#include <sqlite3.h>
#include <stdlib.h>
static int bind_text_copy(sqlite3_stmt *s, int n, const char *v, int size) {
  return sqlite3_bind_text(s, n, v, size, SQLITE_TRANSIENT);
}
static int bind_blob_copy(sqlite3_stmt *s, int n, const void *v, int size) {
  return sqlite3_bind_blob(s, n, v, size, SQLITE_TRANSIENT);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"unsafe"
)

type DB struct{ handle *C.sqlite3 }
type Statement struct {
	db     *DB
	handle *C.sqlite3_stmt
}
type Row map[string]any
type Error struct {
	Code               int
	Operation, Message string
}

func (e *Error) Error() string {
	return fmt.Sprintf("SQLite %s (%d): %s", e.Operation, e.Code, e.Message)
}

// Open uses SQLITE_OPEN_READONLY for readers, which cannot create a missing
// file. Writers create only the file; the caller prepares its parent directory.
func Open(path string, readOnly bool) (*DB, error) {
	if path == "" || strings.ContainsRune(path, 0) {
		return nil, errors.New("invalid SQLite path")
	}
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	flags := C.int(C.SQLITE_OPEN_READWRITE | C.SQLITE_OPEN_CREATE | C.SQLITE_OPEN_FULLMUTEX)
	if readOnly {
		flags = C.SQLITE_OPEN_READONLY | C.SQLITE_OPEN_FULLMUTEX
	}
	db := &DB{}
	if code := C.sqlite3_open_v2(p, &db.handle, flags, nil); code != C.SQLITE_OK {
		err := db.error(code, "open")
		if db.handle != nil {
			_ = db.Close()
		}
		return nil, err
	}
	C.sqlite3_extended_result_codes(db.handle, 1)
	C.sqlite3_busy_timeout(db.handle, 2000)
	return db, nil
}
func (d *DB) Close() error {
	if d.handle == nil {
		return nil
	}
	if code := C.sqlite3_close(d.handle); code != C.SQLITE_OK {
		return d.error(code, "close")
	}
	d.handle = nil
	return nil
}
func (d *DB) AutoCommit() bool { return d.handle == nil || C.sqlite3_get_autocommit(d.handle) != 0 }
func (d *DB) error(code C.int, operation string) error {
	message := "connection closed"
	if d.handle != nil {
		message = C.GoString(C.sqlite3_errmsg(d.handle))
	}
	return &Error{int(code), operation, message}
}

// Exec permits multiple SQL statements only when there are no parameters.
// Parameterized statements are bound, never interpolated into SQL text.
func (d *DB) Exec(sql string, args ...any) error {
	if d.handle == nil {
		return errors.New("SQLite connection closed")
	}
	if strings.ContainsRune(sql, 0) {
		return errors.New("SQL contains NUL")
	}
	if len(args) == 0 {
		str := C.CString(sql)
		defer C.free(unsafe.Pointer(str))
		if code := C.sqlite3_exec(d.handle, str, nil, nil, nil); code != C.SQLITE_OK {
			return d.error(code, "exec")
		}
		return nil
	}
	s, err := d.Prepare(sql)
	if err != nil {
		return err
	}
	defer s.Close()
	if err = s.bindAll(args); err != nil {
		return err
	}
	for {
		row, err := s.Step()
		if err != nil {
			return err
		}
		if !row {
			return nil
		}
	}
}
func (d *DB) Query(sql string, args ...any) ([]Row, error) {
	s, err := d.Prepare(sql)
	if err != nil {
		return nil, err
	}
	defer s.Close()
	if err = s.bindAll(args); err != nil {
		return nil, err
	}
	rows := []Row{}
	for {
		row, err := s.Step()
		if err != nil {
			return nil, err
		}
		if !row {
			return rows, nil
		}
		values := make(Row, int(C.sqlite3_column_count(s.handle)))
		for i := 0; i < int(C.sqlite3_column_count(s.handle)); i++ {
			name := C.GoString(C.sqlite3_column_name(s.handle, C.int(i)))
			if _, exists := values[name]; exists {
				return nil, fmt.Errorf("duplicate SQLite result column %q", name)
			}
			switch C.sqlite3_column_type(s.handle, C.int(i)) {
			case C.SQLITE_NULL:
				values[name] = nil
			case C.SQLITE_INTEGER:
				values[name] = s.Integer(i)
			case C.SQLITE_FLOAT:
				values[name] = float64(C.sqlite3_column_double(s.handle, C.int(i)))
			case C.SQLITE_TEXT:
				values[name] = s.Text(i)
			case C.SQLITE_BLOB:
				values[name] = s.Blob(i)
			}
		}
		rows = append(rows, values)
	}
}
func (d *DB) Prepare(sql string) (*Statement, error) {
	if d.handle == nil {
		return nil, errors.New("SQLite connection closed")
	}
	if strings.ContainsRune(sql, 0) {
		return nil, errors.New("SQL contains NUL")
	}
	str := C.CString(sql)
	defer C.free(unsafe.Pointer(str))
	s := &Statement{db: d}
	var tail *C.char
	if code := C.sqlite3_prepare_v2(d.handle, str, -1, &s.handle, &tail); code != C.SQLITE_OK {
		return nil, d.error(code, "prepare")
	}
	if s.handle == nil {
		return nil, errors.New("empty SQL statement")
	}
	if strings.TrimSpace(C.GoString(tail)) != "" {
		_ = s.Close()
		return nil, errors.New("expected one SQL statement")
	}
	return s, nil
}
func (s *Statement) bindAll(args []any) error {
	if int(C.sqlite3_bind_parameter_count(s.handle)) != len(args) {
		return errors.New("SQLite parameter count mismatch")
	}
	for i, arg := range args {
		if err := s.Bind(i+1, arg); err != nil {
			return err
		}
	}
	return nil
}
func (s *Statement) Bind(index int, value any) error {
	if s.handle == nil {
		return errors.New("SQLite statement closed")
	}
	var code C.int
	switch v := value.(type) {
	case nil:
		code = C.sqlite3_bind_null(s.handle, C.int(index))
	case string:
		if len(v) > math.MaxInt32 {
			return errors.New("SQLite text binding too large")
		}
		str := C.CString(v)
		defer C.free(unsafe.Pointer(str))
		code = C.bind_text_copy(s.handle, C.int(index), str, C.int(len(v)))
	case []byte:
		if len(v) > math.MaxInt32 {
			return errors.New("SQLite blob binding too large")
		}
		if len(v) == 0 {
			code = C.sqlite3_bind_zeroblob(s.handle, C.int(index), 0)
		} else {
			buf := C.CBytes(v)
			defer C.free(buf)
			code = C.bind_blob_copy(s.handle, C.int(index), buf, C.int(len(v)))
		}
	case int:
		code = C.sqlite3_bind_int64(s.handle, C.int(index), C.sqlite3_int64(v))
	case int64:
		code = C.sqlite3_bind_int64(s.handle, C.int(index), C.sqlite3_int64(v))
	case uint64:
		if v > math.MaxInt64 {
			return errors.New("SQLite integer binding overflow")
		}
		code = C.sqlite3_bind_int64(s.handle, C.int(index), C.sqlite3_int64(v))
	case float64:
		code = C.sqlite3_bind_double(s.handle, C.int(index), C.double(v))
	case bool:
		var n C.int
		if v {
			n = 1
		}
		code = C.sqlite3_bind_int(s.handle, C.int(index), n)
	default:
		return fmt.Errorf("unsupported SQLite binding %T", value)
	}
	if code != C.SQLITE_OK {
		return s.db.error(code, "bind")
	}
	return nil
}
func (s *Statement) Step() (bool, error) {
	if s.handle == nil {
		return false, errors.New("SQLite statement closed")
	}
	switch code := C.sqlite3_step(s.handle); code {
	case C.SQLITE_ROW:
		return true, nil
	case C.SQLITE_DONE:
		return false, nil
	default:
		return false, s.db.error(code, "step")
	}
}
func (s *Statement) Integer(col int) int64 {
	return int64(C.sqlite3_column_int64(s.handle, C.int(col)))
}
func (s *Statement) Text(col int) string {
	return C.GoStringN((*C.char)(unsafe.Pointer(C.sqlite3_column_text(s.handle, C.int(col)))), C.sqlite3_column_bytes(s.handle, C.int(col)))
}
func (s *Statement) Blob(col int) []byte {
	return C.GoBytes(C.sqlite3_column_blob(s.handle, C.int(col)), C.sqlite3_column_bytes(s.handle, C.int(col)))
}
func (s *Statement) Close() error {
	if s.handle == nil {
		return nil
	}
	code := C.sqlite3_finalize(s.handle)
	s.handle = nil
	if code != C.SQLITE_OK {
		return s.db.error(code, "finalize")
	}
	return nil
}
