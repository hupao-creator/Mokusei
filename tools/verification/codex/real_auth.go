package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

// This is a real native OAuth refresh and external-token 401 callback. All
// credentials are synthetic and the OS denies non-loopback network traffic.
func verifyRealIsolatedAuthentication(ctx context.Context, root, native string) error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("native auth replay requires macOS sandbox-exec")
	}
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	old, refreshed := fixtureAccessToken("account-a", "native-old"), fixtureAccessToken("account-a", "native-new")
	var refreshes, rejected, accepted atomic.Int32
	provider := &localProvider{}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	endpoint := "http://" + listener.Addr().String()
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/oauth/token":
			var body object
			if json.NewDecoder(r.Body).Decode(&body) != nil || body["refresh_token"] != "fixture-refresh-original" {
				http.Error(w, "invalid fixture refresh", 400)
				return
			}
			refreshes.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(object{"access_token": refreshed, "id_token": refreshed, "refresh_token": "fixture-refresh-rotated"})
		case "/v1/responses":
			if r.Header.Get("Authorization") == "Bearer "+old {
				rejected.Add(1)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusUnauthorized)
				fmt.Fprint(w, `{"error":{"message":"fixture access token expired","type":"invalid_request_error","code":"invalid_api_key"}}`)
				return
			}
			if r.Header.Get("Authorization") != "Bearer "+refreshed {
				http.Error(w, "unexpected fixture access", 401)
				return
			}
			accepted.Add(1)
			r.Header.Set("Authorization", "Bearer local-scripted-provider-only")
			provider.ServeHTTP(w, r)
		default:
			http.Error(w, "fixture endpoint unavailable", 404)
		}
	})}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	env["CODEX_REFRESH_TOKEN_URL_OVERRIDE"] = endpoint + "/oauth/token"
	env["HTTP_PROXY"], env["HTTPS_PROXY"], env["ALL_PROXY"] = endpoint, endpoint, endpoint
	env["NO_PROXY"] = "127.0.0.1,localhost,::1"
	config := fmt.Sprintf(`model = "gpt-5.4"
model_provider = "mokusei_auth_fixture"
cli_auth_credentials_store = "file"
chatgpt_base_url = %s
check_for_update_on_startup = false
[model_providers.mokusei_auth_fixture]
name = "Local native auth fixture"
base_url = %s
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
[features]
apps = false
plugins = false
remote_plugin = false
hooks = false
memories = false
shell_snapshot = false
responses_websockets = false
responses_websockets_v2 = false
[otel]
exporter = "none"
trace_exporter = "none"
`, strconv.Quote(endpoint), strconv.Quote(endpoint+"/v1"))
	if err = os.WriteFile(filepath.Join(env["CODEX_HOME"], "config.toml"), []byte(config), 0600); err != nil {
		return err
	}
	authPath := filepath.Join(env["CODEX_HOME"], "auth.json")
	auth := object{"auth_mode": "chatgpt", "last_refresh": time.Now().UTC().Format(time.RFC3339Nano), "tokens": object{"id_token": old, "access_token": old, "refresh_token": "fixture-refresh-original", "account_id": "account-a"}}
	if err = os.WriteFile(authPath, encoded(auth), 0600); err != nil {
		return err
	}
	profile := filepath.Join(root, "loopback-only.sb")
	if err = os.WriteFile(profile, []byte("(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip \"localhost:*\"))\n"), 0600); err != nil {
		return err
	}
	wrapper := filepath.Join(root, "native-isolated")
	if err = os.WriteFile(wrapper, []byte("#!/bin/sh\nexec /usr/bin/sandbox-exec -f "+shellQuote(profile)+" "+shellQuote(native)+" \"$@\"\n"), 0700); err != nil {
		return err
	}
	launch, err := codex.PrepareIsolatedLaunch(ctx, wrapper, environmentList(env), filepath.Join(root, "harness"), "native-auth", filepath.Join(root, "work"))
	if err != nil {
		return err
	}
	child, err := codex.StartAppServer(ctx, codex.LaunchOptions{Executable: wrapper, Cwd: filepath.Join(root, "work"), Environment: launch.Environment, ConfigOverrides: launch.ConfigOverrides, Dispose: launch.Dispose, AuthSource: launch.AuthSource})
	if err != nil {
		return err
	}
	defer child.Close()
	terminal := make(chan object, 1)
	child.SetHandler(func(method string, params codex.Map, id any) {
		if method == "turn/completed" {
			select {
			case terminal <- record(params["turn"]):
			default:
			}
		}
	}, func(err error) {
		select {
		case terminal <- object{"status": "process-exit", "error": err.Error()}:
		default:
		}
	})
	thread, err := child.Call(ctx, "thread/start", object{"model": "gpt-5.4", "modelProvider": "mokusei_auth_fixture", "cwd": filepath.Join(root, "work"), "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true})
	if err != nil {
		return err
	}
	_, err = child.Call(ctx, "turn/start", object{"threadId": record(thread["thread"])["id"], "input": []any{object{"type": "text", "text": "Return the local auth verification response."}}})
	if err != nil {
		return err
	}
	select {
	case turn := <-terminal:
		if turn["status"] != "completed" {
			return fmt.Errorf("native auth execution failed: %s", encoded(turn["error"]))
		}
	case <-ctx.Done():
		return fmt.Errorf("native auth execution: %w (401=%d refresh=%d accepted=%d)", ctx.Err(), rejected.Load(), refreshes.Load(), accepted.Load())
	}
	if rejected.Load() != 1 || refreshes.Load() != 1 || accepted.Load() != 1 {
		return fmt.Errorf("native auth lifecycle count mismatch: 401=%d refresh=%d accepted=%d", rejected.Load(), refreshes.Load(), accepted.Load())
	}
	data, err := os.ReadFile(authPath)
	if err != nil {
		return err
	}
	if record(decoded(data)["tokens"])["refresh_token"] != "fixture-refresh-rotated" {
		return fmt.Errorf("native refresh did not persist in source account")
	}
	if _, err = os.Stat(filepath.Join(launch.Home, "auth.json")); !os.IsNotExist(err) {
		return fmt.Errorf("native ephemeral login wrote isolated credentials")
	}
	if err = child.Close(); err != nil {
		return err
	}
	if _, err = os.Stat(authPath); err != nil {
		return fmt.Errorf("isolated cleanup removed source account: %w", err)
	}
	fmt.Println("PASS real native external login / HTTP 401 callback / source OAuth rotation / successful native retry / no isolated credential file")
	return nil
}
