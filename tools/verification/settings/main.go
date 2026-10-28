// settings runs existing Swift user flows against the real Go daemon and a
// self-executing native Codex protocol fixture. No model service is contacted.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/environment"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func main() {
	var err error
	if os.Getenv("MOKUSEI_SETTINGS_PEER") != "" {
		err = fixture()
	} else {
		err = run()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func fixture() error {
	for _, arg := range os.Args[1:] {
		if arg == "-ilc" {
			for _, entry := range os.Environ() {
				fmt.Fprint(os.Stdout, entry, "\x00")
			}
			return nil
		}
	}
	exchange := func(frame map[string]any) (map[string]any, error) {
		frame["pid"] = os.Getpid()
		raw, err := json.Marshal(frame)
		if err != nil {
			return nil, err
		}
		client := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}}
		defer client.CloseIdleConnections()
		response, err := client.Post(os.Getenv("MOKUSEI_SETTINGS_PEER"), "application/json", bytes.NewReader(raw))
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			return nil, fmt.Errorf("fixture peer HTTP %d", response.StatusCode)
		}
		var result map[string]any
		err = json.NewDecoder(io.LimitReader(response.Body, 1024*1024)).Decode(&result)
		return result, err
	}
	for _, arg := range os.Args[1:] {
		if arg == "--version" {
			if _, err := exchange(map[string]any{"method": "$version"}); err != nil {
				return err
			}
			fmt.Println("codex-cli 999.0.0")
			return nil
		}
	}
	server := false
	for _, arg := range os.Args[1:] {
		server = server || arg == "app-server"
	}
	if !server {
		return errors.New("unsupported fixture CLI arguments")
	}
	if _, err := exchange(map[string]any{"method": "$launch"}); err != nil {
		return err
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	var failures []error
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	for scanner.Scan() {
		var frame map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &frame); err != nil {
			return err
		}
		id, hasID := frame["id"]
		if !hasID || frame["method"] == nil {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			reply, err := exchange(frame)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				failures = append(failures, err)
				return
			}
			reply["id"] = id
			failures = append(failures, json.NewEncoder(os.Stdout).Encode(reply))
		}()
	}
	wg.Wait()
	return errors.Join(append(failures, scanner.Err())...)
}

type capture struct {
	mu   sync.Mutex
	data []byte
}

func (c *capture) Write(data []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.data = append(c.data, data...)
	if len(c.data) > 512*1024 {
		c.data = c.data[len(c.data)-512*1024:]
	}
	return len(data), nil
}
func (c *capture) String() string { c.mu.Lock(); defer c.mu.Unlock(); return string(c.data) }

func invoke(ctx context.Context, connection *profile.Connection, channel string, args []any) (map[string]any, error) {
	id, err := transport.CreateCommandID()
	if err != nil {
		return nil, err
	}
	raw, err := json.Marshal(map[string]any{"commandId": id, "args": args})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", fmt.Sprintf("http://127.0.0.1:%d/invoke/%s", connection.Port, channel), bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+connection.Token)
	req.Header.Set("X-Mokusei-Protocol", fmt.Sprint(transport.ProtocolVersion))
	req.Header.Set("X-Mokusei-Epoch", connection.Epoch)
	client := &http.Client{Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}}
	defer client.CloseIdleConnections()
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	var result struct {
		OK    bool           `json:"ok"`
		Value map[string]any `json:"value"`
		Error any            `json:"error"`
	}
	err = json.NewDecoder(io.LimitReader(response.Body, 32*1024*1024)).Decode(&result)
	if err != nil {
		return nil, err
	}
	if response.StatusCode != 200 || !result.OK {
		return nil, fmt.Errorf("%s failed: %v", channel, result.Error)
	}
	return result.Value, nil
}

func run() (failure error) {
	runtimePath := flag.String("runtime", ".build/go/mokusei-runtime", "production runtime binary")
	artifacts := flag.String("artifacts", "", "retain Swift output and diagnostic evidence")
	flag.Parse()
	if flag.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	executable, err := filepath.Abs(*runtimePath)
	if err != nil {
		return err
	}
	if _, err = os.Stat(executable); err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "mokusei-go-settings-")
	if err != nil {
		return err
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(root, "profile")})
	if err != nil {
		return err
	}
	if err = seedThreadSettings(p, root); err != nil {
		return err
	}
	bin := filepath.Join(root, "bin")
	if err = os.Mkdir(bin, 0700); err != nil {
		return err
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	fixturePath := filepath.Join(bin, "codex")
	if err = os.Symlink(self, fixturePath); err != nil {
		return err
	}
	var mu sync.Mutex
	var calls, unexpected []string
	nativeModels := []any{map[string]any{"model": "settings-a", "displayName": "Settings A", "isDefault": true, "supportedReasoningEfforts": []any{map[string]any{"reasoningEffort": "low"}, map[string]any{"reasoningEffort": "high"}}, "defaultReasoningEffort": "low", "defaultServiceTier": nil, "serviceTiers": []any{map[string]any{"id": "priority"}}}, map[string]any{"model": "settings-b", "displayName": "Settings B", "supportedReasoningEfforts": []any{map[string]any{"reasoningEffort": "medium"}}, "defaultReasoningEffort": "medium", "defaultServiceTier": "priority", "serviceTiers": []any{map[string]any{"id": "priority"}}}}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	peer := &http.Server{ReadHeaderTimeout: 5 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var frame map[string]any
		if err := json.NewDecoder(io.LimitReader(r.Body, 1024*1024)).Decode(&frame); err != nil {
			http.Error(w, "invalid fixture request", 400)
			return
		}
		method, _ := frame["method"].(string)
		mu.Lock()
		calls = append(calls, method)
		mu.Unlock()
		var result any = map[string]any{}
		switch method {
		case "$version", "$launch":
		case "initialize":
			result = map[string]any{"userAgent": "codex/999.0.0"}
		case "model/list":
			result = map[string]any{"data": nativeModels}
		case "config/read":
			result = map[string]any{"config": map[string]any{"model": "settings-a", "model_reasoning_effort": "low", "service_tier": "default", "approvals_reviewer": "user"}}
		case "configRequirements/read":
			result = map[string]any{"requirements": nil}
		case "plugin/installed":
			result = map[string]any{"marketplaces": []any{}}
		case "account/read":
			result = map[string]any{"account": map[string]any{"type": "chatgpt"}}
		case "account/rateLimits/read":
			result = map[string]any{"rateLimits": map[string]any{}}
		default:
			mu.Lock()
			unexpected = append(unexpected, method)
			mu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": -32601, "message": "unsupported fixture method"}})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"result": result})
	})}
	go func() { _ = peer.Serve(listener) }()
	defer peer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	child := exec.Command(executable, "serve", "--data-dir", p.DataDir)
	child.Dir = root
	child.Env = environment.Slice(map[string]string{"HOME": os.Getenv("HOME"), "PATH": bin, "SHELL": fixturePath, "CODEX_CLI_PATH": fixturePath, "CODEX_INSTALL_DIR": bin, "MOKUSEI_SETTINGS_PEER": "http://" + listener.Addr().String(), "OPENCODE_DB": ":memory:", "MOKUSEI_DEBUG_LOG": "summary", "LANG": "en_US.UTF-8", "GORACE": "halt_on_error=1 atexit_sleep_ms=0"})
	var runtimeLog capture
	child.Stdout = &runtimeLog
	child.Stderr = &runtimeLog
	if err = child.Start(); err != nil {
		return err
	}
	exited := make(chan error, 1)
	go func() { exited <- child.Wait() }()
	var swiftOutput capture
	defer func() {
		stopCtx, stopCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer stopCancel()
		stopErr := daemon.Stop(stopCtx, p)
		if stopErr == nil {
			select {
			case err := <-exited:
				stopErr = err
			case <-stopCtx.Done():
				stopErr = stopCtx.Err()
			}
		}
		failure = errors.Join(failure, stopErr)
		if *artifacts != "" {
			_ = os.MkdirAll(*artifacts, 0700)
			_ = os.WriteFile(filepath.Join(*artifacts, "swift-output.txt"), []byte(swiftOutput.String()), 0600)
			_ = os.WriteFile(filepath.Join(*artifacts, "runtime-output.txt"), []byte(runtimeLog.String()), 0600)
			mu.Lock()
			data, _ := json.MarshalIndent(map[string]any{"calls": calls, "unexpected": unexpected, "passed": failure == nil}, "", "  ")
			mu.Unlock()
			_ = os.WriteFile(filepath.Join(*artifacts, "settings-native.json"), data, 0600)
		}
		if failure == nil {
			_ = os.RemoveAll(filepath.Dir(p.WorkspaceRoot))
			_ = os.RemoveAll(root)
		} else {
			fmt.Fprintln(os.Stderr, "Settings fixture retained:", root, "\n", runtimeLog.String())
		}
	}()
	startupCtx, startupCancel := context.WithTimeout(ctx, 15*time.Second)
	defer startupCancel()
	var connection *profile.Connection
	for {
		connection, err = daemon.Status(startupCtx, p)
		if err != nil {
			return err
		}
		if connection != nil {
			break
		}
		select {
		case err = <-exited:
			exited <- err
			return fmt.Errorf("runtime exited during startup: %v", err)
		case <-startupCtx.Done():
			return startupCtx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
	state, err := invoke(ctx, connection, "state:load", []any{})
	if err != nil {
		return err
	}
	plugins, _ := state["plugins"].([]any)
	foundContext := false
	for _, raw := range plugins {
		entry, _ := raw.(map[string]any)
		if strings.HasPrefix(fmt.Sprint(entry["key"]), "provider:") {
			return errors.New("removed Provider plugin appeared in production catalog")
		}
		if entry["key"] != "context:artificial-analysis" {
			continue
		}
		if foundContext {
			return fmt.Errorf("incorrect Artificial Analysis plugin ownership: %v", entry)
		}
		foundContext = true
	}
	if !foundContext {
		return errors.New("Context plugin missing from production catalog")
	}
	// Validate the CLI through defaults only. An executionOwner here would
	// initialize saved profiles before the native workspace can exercise cold
	// acquisition and its streamed source changes.
	presentation, err := invoke(ctx, connection, "harness:settings-presentation", []any{map[string]any{"scope": "global", "harnessId": "codex"}})
	if err != nil {
		return err
	}
	value, _ := presentation["value"].(map[string]any)
	cli, _ := value["cli"].(map[string]any)
	if cli["executable"] != fixturePath {
		return fmt.Errorf("unexpected native executable: %v", cli)
	}
	prefetchURL, closePrefetch, err := prefetchProxy(connection)
	if err != nil {
		return err
	}
	defer closePrefetch()
	swift := swiftfixture.Test(ctx, "--filter", "NativeSettingsUserFlows")
	swift.Env = append(os.Environ(), "MOKUSEI_SETTINGS_TEST_PROFILE="+p.DataDir, "MOKUSEI_SETTINGS_PREFETCH_URL="+prefetchURL)
	swift.Stdout = io.MultiWriter(os.Stdout, &swiftOutput)
	swift.Stderr = io.MultiWriter(os.Stderr, &swiftOutput)
	swift.WaitDelay = 5 * time.Second
	if err = swift.Run(); err != nil {
		return err
	}
	if !regexp.MustCompile(`dailySettingsFlow.*passed`).MatchString(swiftOutput.String()) {
		return errors.New("Swift user flow was skipped or did not pass")
	}
	logs, err := os.ReadDir(filepath.Join(p.DataDir, "runtime", "debug-logs"))
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	var diagnostics bytes.Buffer
	for _, entry := range logs {
		if !strings.HasSuffix(entry.Name(), ".jsonl") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(p.DataDir, "runtime", "debug-logs", entry.Name()))
		if err != nil {
			return err
		}
		diagnostics.Write(raw)
		for _, line := range bytes.Split(raw, []byte("\n")) {
			var record map[string]any
			if json.Unmarshal(line, &record) == nil {
				if name, ok := record["evt"].(string); ok {
					seen[name] = true
				}
			}
		}
	}
	for _, name := range []string{"edit", "composition", "close", "validation", "save", "conflict", "retry", "command"} {
		if !seen["settings.client."+name] {
			return fmt.Errorf("missing native %s diagnostic", name)
		}
	}
	if *artifacts != "" {
		if err = os.MkdirAll(*artifacts, 0700); err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(*artifacts, "settings-diagnostics.jsonl"), diagnostics.Bytes(), 0600); err != nil {
			return err
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(unexpected) != 0 {
		return fmt.Errorf("unsupported native methods: %v", unexpected)
	}
	fmt.Println("PASS: real Swift settings flow, real Go daemon/SQLite, fixture Codex, all eight native diagnostic families; no model calls")
	return nil
}

// Seed a normal, idle thread through the real SQLite record format. The native
// state is the production Codex empty envelope; settings I/O uses the same CLI
// protocol fixture as the global flow, without starting a model execution.
func seedThreadSettings(p profile.Profile, cwd string) error {
	root := filepath.Join(p.DataDir, "mokusei-go-state-v1")
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		return err
	}
	at := time.Now().UnixMilli()
	native, err := json.Marshal(codex.EmptyState(at))
	if err != nil {
		_ = db.Close()
		return err
	}
	archived := false
	record := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "settings-replay-thread", HarnessID: "codex", SessionState: native, Settings: json.RawMessage(`{"model":"settings-a","thinking":{"mode":"effort","effort":"low"},"serviceTier":"default","permissionMode":"ask-for-approval"}`), Cwd: cwd, CreatedAt: at, UpdatedAt: at}, Title: "Settings replay", Archived: &archived, Tags: []string{}, TagEmojis: map[string]string{}}
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		if err := tx.Put("thread:"+record.ID, record); err != nil {
			return err
		}
		return tx.SetOrder("threads", []string{record.ID})
	})
	return errors.Join(err, db.Close())
}
