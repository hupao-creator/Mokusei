package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func main() {
	parent, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cli := os.Getenv("MOKUSEI_OPENCODE_FIXTURE")
	check(cli != "", "run through verification runner")
	root, err := os.MkdirTemp("", "mokusei-native-credentials-")
	must(err)
	defer os.RemoveAll(root)
	native := filepath.Join(root, "native.db")
	env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": root, "XDG_DATA_HOME": filepath.Join(root, "data"), "XDG_CACHE_HOME": filepath.Join(root, "cache"), "XDG_CONFIG_HOME": filepath.Join(root, "config"), "OPENCODE_TEST_HOME": root, "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_DB": native, "FIXTURE_ROOT": root}
	env["SYNTHETIC_KEY"] = "fixture"
	env["OPENCODE_CONFIG_CONTENT"] = `{"providers":{"fixture":{"name":"Fixture","settings":{"apiKey":"{env:SYNTHETIC_KEY}"}}},"plugins":["unsafe"],"mcp":{"unsafe":{}},"instructions":["unsafe"]}`
	{
		values, cleanup, err := oc.PrepareEnvironment(oc.Options{CWD: root, Environment: env, IsolateConfig: true}, filepath.Join(root, "bridge"))
		must(err)
		prepared := map[string]string{}
		for _, entry := range values {
			k, v, _ := strings.Cut(entry, "=")
			prepared[k] = v
		}
		check(prepared["OPENCODE_DB"] == native, "wrong database mode")
		check(prepared["XDG_CACHE_HOME"] == env["XDG_CACHE_HOME"], "wrong cache mode")
		var config map[string]any
		must(json.Unmarshal([]byte(prepared["OPENCODE_CONFIG_CONTENT"]), &config))
		check(config["mcp"] == nil && config["instructions"] == nil, "exclusive config retained ambient execution")
		check(len(config["plugins"].([]any)) == 1, "exclusive config retained ambient plugin")
		check(config["providers"].(map[string]any)["fixture"].(map[string]any)["settings"].(map[string]any)["apiKey"] == "fixture", "native provider config lost")
		must(cleanup())
	}
	ctx, cancel := context.WithTimeout(parent, 15*time.Second)
	defer cancel()
	runtime, err := oc.NewRuntime(ctx, oc.Options{CWD: root, ExecutablePath: cli, Environment: env})
	must(err)
	defer runtime.Close()
	must(runtime.ConfigureSession(ctx, "ses_fixture", oc.BridgeConfiguration{}))
	must(runtime.Request(ctx, "POST", "/api/session", oc.Object{"id": "ses_fixture", "location": oc.Object{"directory": root}}, nil))
	credential, err := runtime.ReadProviderCredential(ctx, "fixture", "fixture-model", "")
	must(err)
	check(credential.Authentication == "oauth" && credential.APIKey == "", "OAuth grant leaked into API key facts")
	for _, path := range []string{"/api/session", "/api/session/ses_unowned", "/api/experimental/session/ses_unowned/export"} {
		check(runtime.Request(ctx, "GET", path, nil, nil) != nil, "unowned session read accepted")
	}
	check(runtime.Request(ctx, "DELETE", "/api/session/ses_unowned", nil, nil) != nil, "unowned session deletion accepted")
	check(runtime.Request(ctx, "POST", "/api/experimental/session/import", oc.Object{"info": oc.Object{"id": "ses_unowned"}}, nil) != nil, "unowned import accepted")
	terminal := make(chan struct{}, 1)
	unsubscribe := runtime.Subscribe(func(event oc.Event) error {
		if event.Type == "session.execution.succeeded" {
			terminal <- struct{}{}
		}
		return nil
	}, nil)
	must(runtime.EventsReady(ctx))
	must(runtime.Request(ctx, "POST", "/api/session/ses_fixture/prompt", oc.Object{"id": "msg_fixture_user", "text": "fixture"}, nil))
	select {
	case <-terminal:
	case <-ctx.Done():
		panic("SSE completion missing")
	}
	snapshot, err := runtime.Snapshot(ctx, "ses_fixture")
	must(err)
	check(len(snapshot["messages"].([]any)) == 2, "snapshot missing messages")
	unsubscribe()
	must(runtime.Close())
	log, err := os.ReadFile(filepath.Join(root, "operations.log"))
	must(err)
	check(strings.Count(string(log), "process-start") == 1 && strings.Count(string(log), "process-exit") == 1, "native runtime did not use exactly one server")
	check(!strings.Contains(string(log), "/api/credential") && !strings.Contains(string(log), "credentialSnapshot") && !strings.Contains(string(log), "credentialRefresh"), "legacy credential transport used")
	check(!strings.Contains(string(log), "ses_unowned"), "unowned request reached native server")
	// Advisory consumers must not join a slow cold native catalog flight.
	env["FIXTURE_STARTUP_DELAY_MS"] = "3000"
	env["FIXTURE_SETTINGS"] = "1"
	h := oc.New(plugin.HostContext{Environment: func(context.Context) (map[string]string, error) { return env, nil }, ResolveExecutable: func(context.Context, string, string, string) (string, error) { return cli, nil }})
	request := plugin.SettingsRequest{Settings: json.RawMessage(`{}`), Cwd: root}
	start := time.Now()
	schema, availability, err := h.DiscoverMokuTarget(ctx, request)
	must(err)
	check(availability.Available && len(schema) == 0, "cold target was not deferred")
	check(time.Since(start) < time.Second, "target discovery waited for native startup")
	gateDeadline := time.Now().Add(3 * time.Second)
	for {
		log, err := os.ReadFile(filepath.Join(root, "operations.log"))
		must(err)
		if strings.Count(string(log), "process-start") >= 2 && strings.Count(string(log), "POST /api/rpc/mokusei.harness/refresh") >= 3 {
			break
		}
		check(time.Now().Before(gateDeadline), "background native catalog never reached startup gate")
		time.Sleep(5 * time.Millisecond)
	}
	start = time.Now()

	catalog, err := h.CachedModelCatalog(ctx, request)
	must(err)
	check(string(catalog) == `{"models":[]}`, "cold advisory catalog fabricated models")
	workspace, err := h.MokuContext(ctx, "workspace", request, nil)
	must(err)
	check(workspace == "", "workspace context read account telemetry")
	telemetry, err := h.MokuContext(ctx, "telemetry", request, nil)
	must(err)
	check(strings.Contains(telemetry, "unknown"), "cold telemetry claimed known account")
	check(time.Since(start) < time.Second, "advisory discovery waited for slow native catalog")
	fullSchema, err := h.Settings().Describe(ctx, request)
	must(err)
	check(strings.Contains(string(fullSchema), "fixture-model"), "on-demand native schema was not populated")
	warmCatalog, err := h.CachedModelCatalog(ctx, request)
	must(err)
	check(strings.Contains(string(warmCatalog), "fixture-model"), "native catalog was not warm")
	warmSchema, warmAvailability, err := h.DiscoverMokuTarget(ctx, request)
	must(err)
	check(warmAvailability.Available && len(warmSchema) == 0, "warm catalog changed deferred Target schema")
	must(h.Close())
	fmt.Println("PASS: one native server, native DB/cache, exclusive config, no credential copying, session ownership, stable cold/warm deferred Target, HTTP/SSE/export and cleanup")
}
