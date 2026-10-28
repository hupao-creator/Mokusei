// Command moku-system exercises production Moku composition through a real native
// CLI and a loopback model provider. Fixtures never open a user's runtime profile.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/composition"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const defaultScenarioTimeout = 90 * time.Second

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
func run() error {
	native := flag.String("codex", "", "absolute native Codex binary")
	evidence := flag.String("evidence", "", "new directory for synthetic provider transcript")
	faults := flag.String("faults", "", "comma-separated role=429|500|truncate; each injected once (moku,child,report,tag,read)")
	scopes := flag.Int("scopes", 1, "one Inbox task, or 2-3 tasks in independent directories")
	actions := flag.String("actions", "read,archive,unarchive,settings", "action sequence: read,archive,unarchive,settings,followup,fork,interrupt,delete,clear")
	scenarioTimeout := flag.Duration("scenario-timeout", defaultScenarioTimeout, "total in-process scenario budget; does not change 30s convergence waits")
	flag.Parse()
	return runScenarioOptions(*native, *evidence, *faults, *scopes, strings.Split(*actions, ","), *scenarioTimeout)
}
func runCase(nativePath, evidencePath, faultSpec string) error {
	return runScenario(nativePath, evidencePath, faultSpec, 1)
}
func runScenario(nativePath, evidencePath, faultSpec string, scopes int) error {
	return runScenarioActions(nativePath, evidencePath, faultSpec, scopes, []string{"read", "archive", "unarchive", "settings"})
}
func runScenarioActions(nativePath, evidencePath, faultSpec string, scopes int, actions []string) error {
	return runScenarioOptions(nativePath, evidencePath, faultSpec, scopes, actions, defaultScenarioTimeout)
}
func runScenarioOptions(nativePath, evidencePath, faultSpec string, scopes int, actions []string, scenarioTimeout time.Duration) (err error) {
	if scenarioTimeout <= 0 {
		return errors.New("scenario timeout must be positive")
	}
	if scopes < 1 || scopes > 3 {
		return errors.New("scopes must be 1..3")
	}
	native, evidence, faults := &nativePath, &evidencePath, &faultSpec
	if *native == "" {
		return errors.New("-codex is required")
	}
	root, err := os.MkdirTemp("", "mokusei-moku-system-")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			fmt.Fprintln(os.Stderr, "RETAINED", root)
		} else {
			os.RemoveAll(root)
		}
	}()
	for _, p := range []string{"bin", "home", "native", "tmp", "profile/mokusei-go-state-v1"} {
		if err = os.MkdirAll(filepath.Join(root, p), 0700); err != nil {
			return err
		}
	}
	plan, e := parseFaults(*faults)
	if e != nil {
		return e
	}
	var convergence object
	mock := &provider{faultPlan: plan, faultHits: map[string]int{}, children: map[string]string{}, scopeChecks: map[string]bool{}}
	if scopes > 1 {
		home, e := os.UserHomeDir()
		if e != nil {
			return e
		}
		scopeRoot, e := os.MkdirTemp(home, ".mokusei-system-scopes-")
		if e != nil {
			return e
		}
		defer func() {
			if err != nil {
				fmt.Fprintln(os.Stderr, "RETAINED SCOPES", scopeRoot)
			} else {
				err = errors.Join(err, os.RemoveAll(scopeRoot))
			}
		}()
		for i := 0; i < scopes; i++ {
			dir := filepath.Join(scopeRoot, fmt.Sprintf("scope-%d", i+1))
			if err = os.Mkdir(dir, 0700); err != nil {
				return err
			}
			dir, err = filepath.EvalSymlinks(dir)
			if err != nil {
				return err
			}
			if directorytag.Scope(dir) != dir {
				return fmt.Errorf("test workspace is not an independent scope: %s", dir)
			}
			mock.workspaces = append(mock.workspaces, dir)
		}
	}
	server := httptest.NewServer(mock)
	defer server.Close()
	defer func() {
		if *evidence != "" {
			e := os.Mkdir(*evidence, 0700)
			if e == nil {
				mock.mu.Lock()
				e = os.WriteFile(filepath.Join(*evidence, "provider.json"), encoded(object{"requests": mock.requests, "actions": actions, "scopes": scopes, "scenarioTimeout": scenarioTimeout.String(), "failures": mock.failures, "blockedEgress": mock.blocked, "faultPlan": mock.faultPlan, "faultHits": mock.faultHits, "scopeChecks": mock.scopeChecks, "outcomeError": fmt.Sprint(err)}), 0600)
				mock.mu.Unlock()
				if err != nil && convergence != nil {
					e = errors.Join(e, os.WriteFile(filepath.Join(*evidence, "convergence.json"), encoded(convergence), 0600))
				}
			}
			err = errors.Join(err, e)
		}
	}()
	config := fmt.Sprintf(`model = "gpt-5.4"
model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
web_search = "disabled"
[model_providers.fixture]
name = "System fixture"
base_url = %s
wire_api = "responses"
env_key = "FIXTURE_KEY"
requires_openai_auth = false
supports_websockets = false
[features]
apps = false
plugins = false
remote_plugin = false
hooks = false
goals = false
memories = false
shell_snapshot = false
multi_agent = false
image_generation = false
responses_websockets = false
responses_websockets_v2 = false
[otel]
exporter = "none"
trace_exporter = "none"
`, strconv.Quote(server.URL+"/v1"))
	if err = os.WriteFile(filepath.Join(root, "native/config.toml"), []byte(config), 0600); err != nil {
		return err
	}
	sandbox := filepath.Join(root, "loopback.sb")
	if err = os.WriteFile(sandbox, []byte("(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip \"localhost:*\"))\n"), 0600); err != nil {
		return err
	}
	wrapper := filepath.Join(root, "bin/codex")
	if err = os.WriteFile(wrapper, []byte("#!/bin/sh\nexec /usr/bin/sandbox-exec -f "+quote(sandbox)+" "+quote(*native)+" \"$@\"\n"), 0700); err != nil {
		return err
	}
	env := map[string]string{"HOME": filepath.Join(root, "home"), "PATH": filepath.Join(root, "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": filepath.Join(root, "native"), "CODEX_SQLITE_HOME": filepath.Join(root, "native"), "TMPDIR": filepath.Join(root, "tmp"), "FIXTURE_KEY": "fixture-only", "HTTP_PROXY": server.URL, "HTTPS_PROXY": server.URL, "ALL_PROXY": server.URL, "NO_PROXY": "127.0.0.1,localhost,::1"}
	probeCtx, probeCancel := context.WithTimeout(context.Background(), 20*time.Second)
	envList := []string{}
	for k, v := range env {
		envList = append(envList, k+"="+v)
	}
	probe, probeErr := codex.StartAppServer(probeCtx, codex.LaunchOptions{Executable: wrapper, Cwd: root, Environment: envList})
	if probeErr != nil {
		probeCancel()
		return probeErr
	}
	catalog, probeErr := probe.Call(probeCtx, "model/list", object{"limit": 100, "includeHidden": false})
	probeErr = errors.Join(probeErr, probe.Close())
	probeCancel()
	if probeErr != nil {
		return probeErr
	}
	modelID, effort := "", ""
	for _, raw := range list(catalog["data"]) {
		m := record(raw)
		if m["isDefault"] == true {
			modelID = text(m["model"])
			effort = text(m["defaultReasoningEffort"])
			break
		}
	}
	if modelID == "" || effort == "" {
		return errors.New("native catalog has no explicit default model/effort")
	}
	mock.model, mock.effort = modelID, effort
	config = strings.Replace(config, `model = "gpt-5.4"`, "model = "+strconv.Quote(modelID), 1)
	if err = os.WriteFile(filepath.Join(root, "native/config.toml"), []byte(config), 0600); err != nil {
		return err
	}
	fmt.Println("NATIVE MODEL", modelID, effort)
	p, err := profile.Resolve(profile.Options{HomeDir: env["HOME"], DataDir: filepath.Join(root, "profile")})
	if err != nil {
		return err
	}
	owner, err := profile.Acquire(p)
	if err != nil {
		return err
	}
	defer func() {
		err = errors.Join(err, owner.Release())
	}()
	db, err := store.Open(filepath.Join(root, "profile/mokusei-go-state-v1/state.sqlite"))
	if err != nil {
		return err
	}
	settings := model.DefaultSettings([]string{"codex", "claude", "pi", "opencode"})
	settings.Moku.HostHarnessPreference = "codex"
	settings.Moku.TargetHarnessIDs = []string{"codex"}
	for _, id := range []string{"claude", "pi", "opencode"} {
		settings.Harnesses[id] = json.RawMessage(`{"threadSettings":{}}`)
	}
	settings.PluginEnabled = map[string]bool{"harness:claude": false, "harness:pi": false, "harness:opencode": false, "context:artificial-analysis": false, "extension:report": true, "extension:tag": true}
	selection := json.RawMessage(encoded(object{"useDefaultThreadSettings": false, "threadSettings": object{"model": modelID, "thinking": object{"mode": "effort", "effort": effort}, "serviceTier": "default", "permissionMode": "full-access"}}))
	settings.Harnesses["codex"] = selection
	settings.Moku.ExecutionHarnesses["codex"] = selection
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		if e := tx.Put("settings", settings); e != nil {
			return e
		}
		return tx.Put("settings-revision", int64(1))
	})
	err = errors.Join(err, db.Close())
	if err != nil {
		return err
	}
	fmt.Printf("SCENARIO timeout=%s scopes=%d actions=%d startedAt=%s\n", scenarioTimeout, scopes, len(actions), time.Now().UTC().Format(time.RFC3339Nano))
	ctx, cancel := context.WithTimeout(context.Background(), scenarioTimeout)
	defer cancel()
	bootstrap := composition.New(composition.Options{Profile: p, Environment: env, Headless: true, Log: func(k string, e error) { fmt.Fprintln(os.Stderr, k, e) }})
	defer func() {
		c, stop := context.WithTimeout(context.Background(), 30*time.Second)
		defer stop()
		err = errors.Join(err, bootstrap.Close(c))
	}()
	host, err := bootstrap.Initialize(ctx)
	if err != nil {
		return err
	}

	api, err := transport.Start(transport.Options{Profile: p, Epoch: owner.Epoch, Host: host})
	if err != nil {
		return err
	}
	defer func() {
		if api != nil {
			cleanup, stop := context.WithTimeout(context.Background(), 30*time.Second)
			defer stop()
			err = errors.Join(err, api.Close(cleanup))
		}
	}()
	client := &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	invoke := func(channel string, args []any, target any) error {
		return invoke(ctx, client, api.Connection, channel, args, target)
	}
	submitArgs := []any{object{"input": object{"parts": []any{object{"kind": "text", "text": "SYSTEM_CHAIN_START: create the child and record completion"}}}}}
	commandID, e := transport.CreateCommandID()
	if e != nil {
		return e
	}
	var first, second json.RawMessage
	if err = invokeWithID(ctx, client, api.Connection, commandID, "moku:submit", submitArgs, &first); err != nil {
		return err
	}
	if err = invokeWithID(ctx, client, api.Connection, commandID, "moku:submit", submitArgs, &second); err != nil {
		return err
	}
	if !bytes.Equal(first, second) {
		return errors.New("repeated command changed its receipt")
	}
	fmt.Println("PASS identical HTTP command replay returns identical receipt")
	for {
		mock.mu.Lock()
		failures := append([]string{}, mock.failures...)
		mock.mu.Unlock()
		if len(failures) > 0 {
			return fmt.Errorf("mock/oracle rejected request: %v", failures)
		}
		var state model.AppState
		if err = invoke("state:load", []any{}, &state); err != nil {
			return err
		}
		children, done, note := 0, true, false
		tagged, reportReady := true, false
		reportCount := 0
		hostDone := false
		for _, t := range state.Threads {
			if t.Moku {
				hostDone = t.Observation.LatestExecution != nil && t.Observation.LatestExecution.Terminal()
				note = t.Note != nil && t.Note.Text == "SYSTEM_CHAIN_VERIFIED"
			} else {
				children++
				hasTag := false
				for _, tag := range t.Tags {
					if strings.HasPrefix(tag, "Verified") {
						hasTag = true
					}
				}
				tagged = tagged && hasTag
				done = done && t.Observation.LatestExecution != nil && t.Observation.LatestExecution.Status == "completed" && t.Observation.LatestExecution.Summary != nil && *t.Observation.LatestExecution.Summary == "SYSTEM_CHILD_DONE"
			}
		}
		for _, a := range state.ApplicationThreads {
			if a.Ref.TypeID == "report.document" && a.Title == "System chain report" {
				reportCount++
			}
		}
		reportReady = reportCount == scopes
		var pending []plugin.MokuDelivery
		deliveryErr := invoke("moku:deliveries", []any{}, &pending)
		convergence = object{"sampledAt": time.Now().UTC(), "state": state, "children": children, "done": done, "note": note, "hostDone": hostDone, "tagged": tagged, "report": reportReady, "pendingDeliveries": pending, "deliveryError": fmt.Sprint(deliveryErr)}
		if deliveryErr != nil {
			return deliveryErr
		}
		if hostDone && children == 0 {
			return errors.New("Moku completed without invoking create_thread")
		}
		if children > scopes {
			return fmt.Errorf("created %d children", children)
		}
		if children == scopes && done && note && hostDone && tagged && reportReady && len(state.AgentRuns) == 0 {
			if len(pending) == 0 {
				if err = verifyFanout(state, mock.workspaces); err != nil {
					return err
				}
				mock.mu.Lock()
				failures := append([]string{}, mock.failures...)
				for role := range mock.faultPlan {
					if mock.faultHits[role] != 1 {
						failures = append(failures, "fault was not exercised: "+role)
					}
				}
				for _, scope := range mock.workspaces {
					for _, role := range []string{"report-read", "tag-write"} {
						if !mock.scopeChecks[scope+"/"+role] {
							failures = append(failures, "missing scope rejection proof: "+scope+"/"+role)
						}
					}
				}
				receipts := map[string]bool{}
				for _, request := range mock.requests {
					ids := []string{"system_note"}
					for i := 0; i < scopes; i++ {
						ids = append(ids, createCallID(i))
					}
					for _, id := range ids {
						if hasResult(request["input"], id) {
							receipts[id] = true
						}
					}
				}
				mock.mu.Unlock()
				for i := 0; i < scopes; i++ {
					if !receipts[createCallID(i)] {
						failures = append(failures, "missing child receipt")
					}
				}
				if len(failures) != 0 || !receipts["system_create"] || !receipts["system_note"] {
					return fmt.Errorf("provider audit failed: failures=%v receipts=%v", failures, receipts)
				}
				state, err = exerciseActions(ctx, invoke, host.(actionHost), mock, state, actions)
				if err != nil {
					return err
				}
				// Stop all owners before reopening the same durable profile. The closures
				// below reference these variables, so cleanup follows the new owner.
				if err = api.Close(ctx); err != nil {
					return err
				}
				if err = bootstrap.Close(ctx); err != nil {
					return err
				}
				if err = owner.Release(); err != nil {
					return err
				}
				owner, err = profile.Acquire(p)
				if err != nil {
					return err
				}
				bootstrap = composition.New(composition.Options{Profile: p, Environment: env, Headless: true, Log: func(k string, e error) { fmt.Fprintln(os.Stderr, k, e) }})
				host, err = bootstrap.Initialize(ctx)
				if err != nil {
					return err
				}
				api, err = transport.Start(transport.Options{Profile: p, Epoch: owner.Epoch, Host: host})
				if err != nil {
					return err
				}
				var replayed json.RawMessage
				if err = invokeWithID(ctx, client, api.Connection, commandID, "moku:submit", submitArgs, &replayed); err != nil {
					return fmt.Errorf("restart receipt replay: %w", err)
				}
				if !bytes.Equal(first, replayed) {
					return errors.New("restart changed durable command receipt")
				}
				conflicting := []any{object{"input": object{"parts": []any{object{"kind": "text", "text": "CONFLICTING_COMMAND_MUST_NOT_EXECUTE"}}}}}
				conflictErr := invokeWithID(ctx, client, api.Connection, commandID, "moku:submit", conflicting, nil)
				if conflictErr == nil || !strings.Contains(conflictErr.Error(), "COMMAND_ID_REUSED") {
					return fmt.Errorf("changed-body command reuse was not rejected: %v", conflictErr)
				}
				fmt.Println("PASS restart receipt replay and changed-body reuse rejection")
				var restored model.AppState
				if err = invoke("state:load", []any{}, &restored); err != nil {
					return err
				}
				if err = verifyRestored(state, restored); err != nil {
					return err
				}
				fmt.Println("PASS graceful restart: task execution, note, Report, Tag and identities retained")
				fmt.Println("PASS production HTTP -> Moku -> real Codex/mock LLM -> create_thread -> child completion -> durable notification -> update_note; scoped Report/read fork and Tag assignment")
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("composition chain incomplete children=%d done=%v note=%v hostDone=%v tagged=%v report=%v agentRuns=%s pendingDeliveries=%s: %w", children, done, note, hostDone, tagged, reportReady, encoded(state.AgentRuns), encoded(pending), ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
}
func invoke(ctx context.Context, c *http.Client, connection profile.Connection, channel string, args []any, target any) error {
	id, err := transport.CreateCommandID()
	if err != nil {
		return err
	}
	return invokeWithID(ctx, c, connection, id, channel, args, target)
}
func invokeWithID(ctx context.Context, c *http.Client, connection profile.Connection, id, channel string, args []any, target any) error {
	req, err := http.NewRequestWithContext(ctx, "POST", fmt.Sprintf("http://127.0.0.1:%d/invoke/%s", connection.Port, channel), bytes.NewReader(encoded(object{"commandId": id, "args": args})))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+connection.Token)
	req.Header.Set("X-Mokusei-Protocol", strconv.Itoa(transport.ProtocolVersion))
	req.Header.Set("X-Mokusei-Epoch", connection.Epoch)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	b, err := io.ReadAll(io.LimitReader(res.Body, transport.MaxResponseBytes+1))
	if err != nil {
		return err
	}
	if len(b) > transport.MaxResponseBytes {
		return errors.New("oversized response")
	}
	var result transport.Result
	if err = json.Unmarshal(b, &result); err != nil {
		return err
	}
	if !result.OK {
		return fmt.Errorf("%s: %v", channel, result.Error)
	}
	if target != nil {
		return json.Unmarshal(result.Value, target)
	}
	return nil
}

func verifyRestored(before, after model.AppState) error {
	if !bytes.Equal(encoded(before.Settings), encoded(after.Settings)) || before.SettingsRevision != after.SettingsRevision {
		return errors.New("restart altered saved settings")
	}
	if len(before.Threads) != len(after.Threads) || len(before.ApplicationThreads) != len(after.ApplicationThreads) {
		return errors.New("restart changed thread/report counts")
	}
	for _, expected := range before.Threads {
		found := false
		for _, actual := range after.Threads {
			if actual.ID == expected.ID {
				found = true
				if (actual.Archived != nil && *actual.Archived) != (expected.Archived != nil && *expected.Archived) {
					return errors.New("restart altered task archive state")
				}
				if string(encoded(actual.Observation.LatestExecution)) != string(encoded(expected.Observation.LatestExecution)) || string(encoded(actual.Note)) != string(encoded(expected.Note)) || string(encoded(actual.Tags)) != string(encoded(expected.Tags)) {
					return fmt.Errorf("restart altered task/note/tag %s", actual.ID)
				}
			}
		}
		if !found {
			return errors.New("restart lost thread identity")
		}
	}
	for _, expected := range before.ApplicationThreads {
		found := false
		for _, actual := range after.ApplicationThreads {
			if actual.ID == expected.ID {
				found = true
				if actual.Archived != expected.Archived {
					return errors.New("restart altered Report archive state")
				}
				if string(encoded(actual.View)) != string(encoded(expected.View)) || string(encoded(actual.Tags)) != string(encoded(expected.Tags)) {
					return errors.New("restart altered Report projection")
				}
			}
		}
		if !found {
			return errors.New("restart lost Report")
		}
	}
	return nil
}

func parseFaults(value string) (map[string]string, error) {
	plan := map[string]string{}
	if value == "" {
		return plan, nil
	}
	for _, entry := range strings.Split(value, ",") {
		parts := strings.Split(entry, "=")
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid fault %q", entry)
		}
		role, mode := parts[0], parts[1]
		switch role {
		case "moku", "child", "report", "tag", "read":
		default:
			return nil, fmt.Errorf("unknown fault role %q", role)
		}
		switch mode {
		case "429", "500", "truncate":
		default:
			return nil, fmt.Errorf("unknown fault mode %q", mode)
		}
		if _, exists := plan[role]; exists {
			return nil, fmt.Errorf("duplicate fault role %q", role)
		}
		plan[role] = mode
	}
	return plan, nil
}
