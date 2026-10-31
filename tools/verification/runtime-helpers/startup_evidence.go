package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

type helperStartupEvidence struct{ root, directory string }

func helperArtifactDirectory(args []string) (string, error) {
	var directory string
	for i := 0; i < len(args); i++ {
		if args[i] != "--artifacts" {
			continue
		}
		if directory != "" || i+1 == len(args) || args[i+1] == "" || strings.HasPrefix(args[i+1], "--") {
			return "", errors.New("--artifacts requires one output directory")
		}
		i++
		var err error
		directory, err = filepath.Abs(args[i])
		if err != nil {
			return "", err
		}
	}
	return directory, nil
}

// Register after RemoveAll so the original panic's files are copied before the
// owned temporary profile disappears. A capture failure never replaces it.
func (e helperStartupEvidence) onPanic() {
	if failure := recover(); failure != nil {
		e.capture("panic")
		panic(failure)
	}
}

func (e helperStartupEvidence) capture(stage string) {
	if e.directory == "" {
		return
	}
	if err := e.retain(stage); err != nil {
		fmt.Fprintf(os.Stderr, "Runtime helper evidence capture failed (%s): %v\n", stage, err)
	}
}

func (e helperStartupEvidence) retain(stage string) error {
	started := time.Now().UnixNano()
	destination := filepath.Join(e.directory, stage)
	if err := os.MkdirAll(e.directory, 0700); err != nil {
		return err
	}
	if err := os.Mkdir(destination, 0700); err != nil {
		return err
	}
	root, err := os.OpenRoot(e.root)
	if err != nil {
		return err
	}
	defer root.Close()
	records := []map[string]any{}
	for _, name := range []string{"daemon", "failed-shutdown-go", "failed-shutdown-swift"} {
		relative := filepath.Join(name, "runtime")
		runtime, err := root.OpenRoot(relative)
		if err != nil {
			records = append(records, map[string]any{"path": relative, "error": err.Error()})
			continue
		}
		names := []string{"process.log", "process.log.previous", "startup-error.json", "owner.json", "connection.json"}
		entries, readErr := fs.ReadDir(runtime.FS(), ".")
		launches := 0
		for _, entry := range entries {
			file := entry.Name()
			if !strings.HasPrefix(file, "launch-") || !strings.HasSuffix(file, ".json") {
				continue
			}
			launches++
			if launches <= 64 {
				names = append(names, file)
			}
		}
		if readErr != nil || launches > 64 {
			record := map[string]any{"path": relative, "launchFiles": launches, "launchLimit": 64}
			if readErr != nil {
				record["directoryReadError"] = readErr.Error()
			}
			records = append(records, record)
		}
		for _, file := range names {
			records = append(records, retainStartupFile(runtime, file, relative, destination))
		}
		_ = runtime.Close()
	}
	data, err := json.MarshalIndent(map[string]any{"schemaVersion": 1, "stage": stage,
		"captureStartedUnixNanoseconds": started, "captureFinishedUnixNanoseconds": time.Now().UnixNano(),
		"ownedTemporaryRoot": e.root, "files": records,
		"meaning": "Failure-time diagnostic snapshots, not atomic ownership observations; only this replay's temporary profiles are read"}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(destination, "manifest.json"), append(data, '\n'), 0600)
}

func retainStartupFile(root *os.Root, name, relative, destination string) map[string]any {
	path := filepath.Join(relative, name)
	record := map[string]any{"path": path}
	if strings.HasPrefix(name, "launch-") && strings.HasSuffix(name, ".json") {
		pid, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(name, "launch-"), ".json"))
		if err != nil || pid <= 0 {
			record["filenameMetadataError"] = "launch filename does not contain a positive process ID"
		} else {
			record["launchFilenamePID"] = pid
		}
	}
	info, err := root.Lstat(name)
	if err != nil {
		record["error"] = err.Error()
		return record
	}
	record["sourceBytes"] = info.Size()
	if !info.Mode().IsRegular() {
		record["error"] = "not a regular file; no link or special file followed"
		return record
	}
	// Root confines reads to this owned profile. Nonblocking open prevents a
	// replaced FIFO from hanging diagnostics; SameFile requires the same regular
	// inode that Lstat inspected before opening it.
	file, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		record["error"] = err.Error()
		return record
	}
	current, err := file.Stat()
	if err != nil || !current.Mode().IsRegular() || !os.SameFile(info, current) {
		_ = file.Close()
		record["error"] = "file changed identity or type before reading"
		return record
	}
	limit := int64(64 * 1024)
	if strings.HasPrefix(name, "process.log") {
		limit = 2 * 1024 * 1024
	}
	data, readErr := io.ReadAll(io.LimitReader(file, limit+1))
	if err = errors.Join(readErr, file.Close()); err != nil {
		record["error"] = err.Error()
		return record
	}
	record["truncated"] = int64(len(data)) > limit
	if int64(len(data)) > limit {
		data = data[:limit]
	}
	output := filepath.Join(destination, path)
	if err = os.MkdirAll(filepath.Dir(output), 0700); err == nil {
		err = os.WriteFile(output, data, 0600)
	}
	if err != nil {
		record["error"] = err.Error()
		return record
	}
	digest := sha256.Sum256(data)
	record["copiedBytes"], record["copiedSHA256"] = len(data), hex.EncodeToString(digest[:])
	var identity struct {
		PID int `json:"pid"`
	}
	if strings.HasSuffix(name, ".json") {
		if err := json.Unmarshal(data, &identity); err != nil {
			record["jsonDecodeError"] = err.Error()
		} else if identity.PID > 0 {
			record["pid"], record["processAliveAtRead"] = identity.PID, profile.IsProcessAlive(identity.PID)
		}
	}
	return record
}
