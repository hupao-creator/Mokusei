package diagnostics

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

const toolFileBytes int64 = 16 * 1024 * 1024
const toolTotalBytes int64 = 256 * 1024 * 1024
const toolRetentionDays = 14

// ToolLogger shares the profile lease and private-file primitives with Logger,
// but owns a separate retention budget. Callers wait for writes and fsync; there
// is no lossy queue and logging failures never authorize repeating side effects.
type ToolLogger struct {
	mu                        sync.Mutex
	directory, journalID, day string
	sequence                  uint64
	file                      *os.File
	size                      int64
	index                     int
	closed                    bool
	poison                    error
}

func NewToolLogger(directory string) (*ToolLogger, error) {
	if err := privateDirectory(directory); err != nil {
		return nil, err
	}
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return nil, err
	}
	l := &ToolLogger{directory: directory, journalID: hex.EncodeToString(id[:])}
	if err := l.prune(time.Now().UTC()); err != nil {
		return nil, err
	}
	return l, nil
}

// Record receives trusted identities from Runtime, but still bounds/redacts all
// strings: native IDs and error messages can contain arbitrary external text.
func (l *ToolLogger) Record(event plugin.ToolInvocation) error {
	if l == nil {
		return errors.New("tool journal unavailable")
	}
	meta, _ := json.Marshal(event)
	var fields map[string]any
	if err := json.Unmarshal(meta, &fields); err != nil {
		return err
	}
	truncated := []string{}
	redacted := []string{}
	for key, value := range fields {
		if text, ok := value.(string); ok {
			text, count := redactToolText(text)
			if count != 0 {
				redacted = append(redacted, key)
			}
			if len(text) > 1024 {
				text = utf8Prefix(text, 1024)
				truncated = append(truncated, key)
				if key == "callId" {
					fields["callIdTruncated"] = true
				}
			}
			fields[key] = text
		}
	}
	// Scope is a host identity (possibly a private absolute path), never user prose.
	if len(event.Scope.Scope) > 4096 {
		fields["scope"] = plugin.ScopeBinding{Kind: event.Scope.Kind, Scope: utf8Prefix(event.Scope.Scope, 4096)}
		truncated = append(truncated, "scope")
	}
	if len(truncated) != 0 {
		sort.Strings(truncated)
		fields["metadataTruncated"] = truncated
	}
	if len(redacted) != 0 {
		sort.Strings(redacted)
		fields["metadataRedacted"] = redacted
	}
	fields["payloadPolicy"] = "private-redacted-v1"
	if event.Event == "tool.started" {
		fields["input"] = captureToolPayload(event.Input)
	}
	if event.Event == "tool.finished" {
		fields["output"] = captureToolPayload(event.Output)
		if event.Error != nil {
			// Retain structured causes and their types, including joined failures,
			// without exposing panic payloads or losing a diagnostic to service limits.
			chain := []map[string]any{}
			chainIncomplete := false
			var visit func(error, int)
			visit = func(err error, depth int) {
				if err == nil {
					return
				}
				if depth > 8 || len(chain) >= 16 {
					chainIncomplete = true
					return
				}
				message := err.Error()
				originalBytes := len(message)
				redactions := 0
				if len(message) > toolDecodeLimit {
					message = "[omitted:over-decode-limit]"
				} else {
					message, redactions = redactToolText(message)
				}
				chain = append(chain, map[string]any{"type": reflect.TypeOf(err).String(), "message": utf8Prefix(message, 16384), "originalBytes": originalBytes, "redactions": redactions, "messageTruncated": len(message) > 16384 || originalBytes > toolDecodeLimit})
				switch v := err.(type) {
				case interface{ Unwrap() []error }:
					for _, child := range v.Unwrap() {
						visit(child, depth+1)
					}
				case interface{ Unwrap() error }:
					visit(v.Unwrap(), depth+1)
				}
			}
			visit(event.Error, 0)
			raw, _ := json.Marshal(map[string]any{"chain": chain, "chainIncomplete": chainIncomplete})
			fields["error"] = captureToolPayload(raw)
		}
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return errors.New("tool journal closed")
	}
	if l.poison != nil {
		return l.poison
	}
	l.sequence++
	fields["journalId"], fields["sequence"] = l.journalID, l.sequence
	data, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	if len(data) > 4*1024*1024 {
		return errors.New("tool journal entry exceeds bound")
	}
	data = append(data, '\n')
	now := time.Now().UTC()
	if err = l.prepare(now, int64(len(data))); err != nil {
		return err
	}
	previous := l.size
	n, err := l.file.Write(data)
	l.size += int64(n)
	if err != nil || n != len(data) {
		// Never append another JSON object behind a partial line.
		if truncateErr := l.file.Truncate(previous); truncateErr != nil {
			l.poison = truncateErr
		}
		l.size = previous
		return errors.Join(err, io.ErrShortWrite, l.poison)
	}
	return errors.Join(l.file.Sync(), l.prune(now))
}

func (l *ToolLogger) prepare(now time.Time, incoming int64) error {
	day := now.Format("2006-01-02")
	if l.file != nil && l.day == day && l.size+incoming <= toolFileBytes {
		return nil
	}
	if l.file != nil {
		if err := l.file.Close(); err != nil {
			l.file = nil
			return err
		}
		l.file = nil
	}
	if l.day != day {
		entries, err := l.files()
		if err != nil {
			return err
		}
		l.day, l.index = day, 0
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), "tools-"+day+"-") {
				index, _ := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(entry.Name(), "tools-"+day+"-"), ".jsonl"))
				l.index = max(l.index, index)
			}
		}
	}
	for {
		if l.index > 9999 {
			return errors.New("tool journal daily segment limit exceeded")
		}
		path := filepath.Join(l.directory, fmt.Sprintf("tools-%s-%04d.jsonl", l.day, l.index))
		file, size, err := openPrivateLog(path)
		if err != nil {
			return err
		}
		completeTail := true
		if size > 0 {
			reader, readErr := os.Open(path)
			if readErr != nil {
				file.Close()
				return readErr
			}
			var tail [1]byte
			_, readErr = reader.ReadAt(tail[:], size-1)
			closeErr := reader.Close()
			if readErr != nil || closeErr != nil {
				file.Close()
				return errors.Join(readErr, closeErr)
			}
			completeTail = tail[0] == '\n'
		}
		// A crash may leave a partial final line. Keep it as evidence and start
		// another segment rather than corrupting the next complete record too.
		if completeTail && size+incoming <= toolFileBytes {
			l.file, l.size = file, size
			return nil
		}
		if err = file.Close(); err != nil {
			return err
		}
		l.index++
	}
}

var toolFileName = regexp.MustCompile(`^tools-\d{4}-\d{2}-\d{2}-\d{4}\.jsonl$`)

func (l *ToolLogger) files() ([]os.FileInfo, error) {
	entries, err := os.ReadDir(l.directory)
	if err != nil {
		return nil, err
	}
	files := []os.FileInfo{}
	for _, entry := range entries {
		if !toolFileName.MatchString(entry.Name()) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, errors.New("tool journal segment must be regular")
		}
		files = append(files, info)
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name() < files[j].Name() })
	return files, nil
}

func (l *ToolLogger) prune(now time.Time) error {
	files, err := l.files()
	if err != nil {
		return err
	}
	cutoff := now.AddDate(0, 0, -(toolRetentionDays - 1)).Format("2006-01-02")
	var total int64
	for _, file := range files {
		total += file.Size()
	}
	for _, file := range files {
		if file.Name()[6:16] >= cutoff && total <= toolTotalBytes {
			continue
		}
		if l.file != nil && filepath.Base(l.file.Name()) == file.Name() {
			continue
		}
		if err := os.Remove(filepath.Join(l.directory, file.Name())); err != nil {
			return err
		}
		total -= file.Size()
	}
	return nil
}

func (l *ToolLogger) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	if l.file == nil {
		return l.poison
	}
	return errors.Join(l.poison, l.file.Sync(), l.file.Close())
}
