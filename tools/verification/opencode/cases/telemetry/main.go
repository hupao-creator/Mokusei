// Replay the native OAuth telemetry path without a real profile or network.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode/accounttelemetry"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}

type consoleTransport struct {
	local http.RoundTripper
	calls atomic.Int64
}

func (t *consoleTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Hostname() == "127.0.0.1" {
		return t.local.RoundTrip(req)
	}
	check(req.Method == "GET" && req.URL.Scheme == "https" && req.URL.Host == "opencode.ai", "unexpected nonlocal request")
	check(req.Header.Get("Authorization") == "Bearer synthetic-console-access" && req.Header.Get("x-org-id") == "org_fixture", "native OAuth workspace lost")
	now := time.Now()
	at := func(d time.Duration) string { return now.Add(d).UTC().Format(time.RFC3339) }
	var body any
	switch req.URL.Path {
	case "/console/api/orgs/current":
		body = oc.Object{"org": oc.Object{"id": "org_fixture"}, "hasGoSubscription": true}
	case "/console/api/billing/status":
		body = oc.Object{"billingMode": "prepaid", "mode": "pay-as-you-go", "balanceMicroCents": "0"}
	case "/console/api/go/status":
		t.calls.Add(1)
		body = oc.Object{"product": "go", "useBalance": false, "access": oc.Object{"startsAt": at(-time.Hour), "endsAt": at(time.Hour), "meters": oc.Object{"fiveHour": oc.Object{"usedMicroCents": "25", "limitMicroCents": "100", "startsAt": at(-time.Hour), "resetsAt": at(time.Hour)}, "week": oc.Object{"usedMicroCents": "50", "limitMicroCents": "100", "resetsAt": at(time.Hour)}, "month": oc.Object{"usedMicroCents": "75", "limitMicroCents": "100", "resetsAt": at(time.Hour)}}}}
	default:
		panic("native OAuth used legacy API-key usage or an unrelated route")
	}
	raw, err := json.Marshal(body)
	must(err)
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(raw))), Header: http.Header{}}, nil
}
func main() {
	fixture := os.Getenv("MOKUSEI_OPENCODE_FIXTURE")
	check(fixture != "", "run through verification runner")
	root, err := os.MkdirTemp("", "mokusei-console-telemetry-")
	must(err)
	defer os.RemoveAll(root)
	transport := &consoleTransport{local: http.DefaultTransport}
	http.DefaultTransport = transport
	defer func() { http.DefaultTransport = transport.local }()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	for i, route := range []string{"https://opencode.ai/zen/go/v1", "https://opencode.ai/inference/go/openai/v1", "https://opencode.ai/inference/openai/v1"} {
		cwd := filepath.Join(root, fmt.Sprint(i))
		must(os.MkdirAll(cwd, 0700))
		env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": cwd, "XDG_CONFIG_HOME": filepath.Join(cwd, "config"), "XDG_DATA_HOME": filepath.Join(cwd, "data"), "OPENCODE_TEST_HOME": cwd, "OPENCODE_DB": filepath.Join(cwd, "native.db"), "FIXTURE_ROOT": cwd, "FIXTURE_CONSOLE": route}
		h := oc.New(plugin.HostContext{Environment: func(context.Context) (map[string]string, error) { return env, nil }, ResolveExecutable: func(context.Context, string, string, string) (string, error) { return fixture, nil }})
		req := plugin.SettingsRequest{Cwd: cwd, Settings: json.RawMessage(`{}`)}
		var native map[string]any
		for {
			raw, err := h.MokuContext(ctx, "telemetry", req, nil)
			must(err)
			check(!strings.Contains(raw, "synthetic-console-access"), "native Moku output leaked access")
			must(json.Unmarshal([]byte(raw), &native))
			if native["availability"] == "available" {
				break
			}
			if native["availability"] == "error" || native["availability"] == "unavailable" {
				panic(fmt.Sprintf("native OAuth telemetry failed for %s: %v", route, native))
			}
			select {
			case <-ctx.Done():
				panic("native OAuth telemetry never refreshed")
			case <-time.After(25 * time.Millisecond):
			}
		}
		ws := native["windows"].([]any)
		check(len(ws) == 3, "native OAuth windows missing")
		for j, want := range []float64{25, 50, 75} {
			check(ws[j].(map[string]any)["usedPercent"] == want, "native percentage lost")
		}
		raw, err := accounttelemetry.ReadConsoleGoTelemetry(ctx, accounttelemetry.ClientOptions{}, accounttelemetry.ConsoleAccount{AccessToken: "synthetic-console-access", OrgID: "org_fixture", ExpiresAt: time.Now().Add(time.Hour)})
		must(err)
		var independent map[string]any
		must(json.Unmarshal(raw, &independent))
		for j, w := range independent["windows"].([]any) {
			check(w.(map[string]any)["id"] == ws[j].(map[string]any)["id"], "native and independent Console account windows diverged")
		}
		must(h.Close())
	}
	// A provider name alone must not authorize an OAuth account on a foreign
	// endpoint or an official-looking route carrying a query override.
	for _, route := range []string{"https://opencode.ai.evil.invalid/zen/go/v1", "https://opencode.ai/zen/go/v1?override=1"} {
		cwd := filepath.Join(root, "refused")
		must(os.MkdirAll(cwd, 0700))
		env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": cwd, "OPENCODE_DB": filepath.Join(cwd, "native.db"), "FIXTURE_ROOT": cwd, "FIXTURE_CONSOLE": route}
		runtime, err := oc.NewRuntime(ctx, oc.Options{CWD: cwd, Environment: env, ExecutablePath: fixture})
		must(err)
		account, err := runtime.ReadConsoleAccount(ctx, "opencode-go", "fixture-model", "")
		must(err)
		check(account == nil, "unverified native route borrowed Console capacity")
		must(runtime.Close())
	}
	check(transport.calls.Load() >= 6, "native telemetry never reached Console status")
	fmt.Println("PASS: native Console OAuth windows, official Go/generic routes, shared independent IDs, no legacy endpoint or real account access")
}
