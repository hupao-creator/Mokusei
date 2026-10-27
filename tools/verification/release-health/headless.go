package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

func headless(ctx context.Context, log io.Writer, cycles int) (err error) {
	root, err := os.MkdirTemp("", "mokusei-headless-health-")
	if err != nil {
		return err
	}
	// Use a disposable HOME too: profile workspaces otherwise live outside DataDir.
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(root, "profile"), HomeDir: root})
	if err != nil {
		os.RemoveAll(root)
		return err
	}
	var pids []int
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		stopErr := daemon.Stop(cleanup, p)
		for _, pid := range pids {
			stopErr = errors.Join(stopErr, waitExit(cleanup, pid))
		}
		if stopErr != nil {
			err = errors.Join(err, fmt.Errorf("cleanup failed; retained %s: %w", root, stopErr))
			return
		}
		processLog, readErr := os.ReadFile(filepath.Join(p.DataDir, "runtime", "process.log"))
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			err = errors.Join(err, readErr)
		}
		if len(processLog) > 0 {
			_, writeErr := log.Write(processLog)
			err = errors.Join(err, writeErr)
		}
		if bytes.Contains(processLog, []byte("WARNING: DATA RACE")) || bytes.Contains(processLog, []byte("panic:")) {
			err = errors.Join(err, errors.New("headless process reported a race or panic"))
		}
		err = errors.Join(err, os.RemoveAll(root))
	}()
	binary := filepath.Join(root, "mokusei-runtime")
	if err = command(ctx, log, "./scripts/go.sh", "build", "-race", "-o", binary, "./cmd/mokusei-runtime"); err != nil {
		return err
	}
	// Deliberately omit credentials and inherited provider configuration. This gate
	// proves service health; native-codex separately proves real CLI + mock inference.
	options := daemon.LaunchOptions{Executable: binary, Directory: root, Environment: []string{"HOME=" + root, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "MOKUSEI_HEADLESS=1", "TMPDIR=" + root}}
	previous := ""
	mokuID := ""
	client := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	for cycle := 1; cycle <= cycles; cycle++ {
		started := time.Now()
		c, e := daemon.Ensure(ctx, p, options)
		if e != nil {
			return e
		}
		if c == nil {
			return errors.New("start returned no connection")
		}
		pids = append(pids, c.PID)
		if c.Epoch == previous {
			return errors.New("restart reused epoch")
		}
		previous = c.Epoch
		state, e := loadState(ctx, client, *c)
		if e != nil {
			return e
		}
		if state.DefaultCwd != p.WorkspaceRoot {
			return fmt.Errorf("workspace escaped isolated HOME: %s", state.DefaultCwd)
		}
		found := false
		for _, thread := range state.Threads {
			if thread.Moku {
				found = true
				if mokuID != "" && mokuID != thread.ID {
					return errors.New("restart replaced durable Moku thread")
				}
				mokuID = thread.ID
			}
		}
		if !found {
			return errors.New("headless state has no readable Moku shell")
		}
		again, e := daemon.Ensure(ctx, p, options)
		if e != nil {
			return e
		}
		if again == nil || again.PID != c.PID || again.Epoch != c.Epoch {
			return errors.New("repeated start changed owner")
		}
		for probe := 0; probe < 10; probe++ {
			current, e := daemon.Status(ctx, p)
			if e != nil {
				return e
			}
			if current == nil || current.Epoch != c.Epoch {
				return errors.New("healthy owner disappeared")
			}
		}
		req, e := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/health", c.Port), nil)
		if e != nil {
			return e
		}
		response, e := client.Do(req)
		if e != nil {
			return e
		}
		response.Body.Close()
		if response.StatusCode != http.StatusUnauthorized {
			return fmt.Errorf("unauthenticated health HTTP %d", response.StatusCode)
		}
		if e = daemon.Stop(ctx, p); e != nil {
			return e
		}
		if e = waitExit(ctx, c.PID); e != nil {
			return e
		}
		current, e := daemon.Status(ctx, p)
		if e != nil {
			return e
		}
		if current != nil {
			return errors.New("stop retained discoverable service")
		}
		alive, e := profile.HasLiveOwner(p)
		if e != nil {
			return e
		}
		if alive {
			return errors.New("stop retained live owner")
		}
		if e = daemon.Stop(ctx, p); e != nil {
			return fmt.Errorf("repeated stop: %w", e)
		}
		fmt.Fprintf(log, "PASS cycle %d: authenticated health, durable readable Moku shell, rejected anonymous probe, idempotent start/stop, fresh epoch, released ownership (%.2fs)\n", cycle, time.Since(started).Seconds())
	}
	return nil
}

func loadState(ctx context.Context, client *http.Client, connection profile.Connection) (model.AppState, error) {
	var state model.AppState
	id, err := transport.CreateCommandID()
	if err != nil {
		return state, err
	}
	body, err := json.Marshal(map[string]any{"commandId": id, "args": []any{}})
	if err != nil {
		return state, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/invoke/state:load", connection.Port), strings.NewReader(string(body)))
	if err != nil {
		return state, err
	}
	req.Header.Set("Authorization", "Bearer "+connection.Token)
	req.Header.Set("X-Mokusei-Protocol", strconv.Itoa(transport.ProtocolVersion))
	req.Header.Set("X-Mokusei-Epoch", connection.Epoch)
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		return state, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, transport.MaxResponseBytes+1))
	if err != nil {
		return state, err
	}
	if len(data) > transport.MaxResponseBytes {
		return state, errors.New("state response too large")
	}
	var result transport.Result
	if err = json.Unmarshal(data, &result); err != nil {
		return state, err
	}
	if response.StatusCode != http.StatusOK || !result.OK {
		return state, fmt.Errorf("state load HTTP %d: %v", response.StatusCode, result.Error)
	}
	err = json.Unmarshal(result.Value, &state)
	return state, err
}

func waitExit(ctx context.Context, pid int) error {
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for profile.IsProcessAlive(pid) {
		select {
		case <-ctx.Done():
			return fmt.Errorf("headless PID %d did not exit: %w", pid, ctx.Err())
		case <-ticker.C:
		}
	}
	return nil
}
