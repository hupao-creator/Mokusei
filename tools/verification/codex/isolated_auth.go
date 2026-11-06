package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func fixtureAccessToken(account, generation string) string {
	return fixtureAccessTokenForUser(account, "fixture-user", generation)
}

func fixtureAccessTokenForUser(account, user, generation string) string {
	return "eyJhbGciOiJub25lIn0." + base64.RawURLEncoding.EncodeToString(encoded(object{"sub": "fixture", "exp": time.Now().Add(14 * 24 * time.Hour).Unix(), "generation": generation, "https://api.openai.com/auth": object{"chatgpt_account_id": account, "chatgpt_user_id": user, "chatgpt_plan_type": "pro"}})) + ".fixture"
}

func (p *peer) authFixture(frame object) (bool, error) {
	path := os.Getenv("MOKUSEI_CODEX_AUTH_FIXTURE")
	if path == "" {
		return false, nil
	}
	method, id, params := text(frame["method"]), frame["id"], record(frame["params"])
	reply := func(result object) (bool, error) { return true, p.send(object{"id": id, "result": result}) }
	if method == "" {
		if original, ok := p.authPending[text(id)]; ok {
			delete(p.authPending, text(id))
			return true, p.send(object{"id": original, "result": frame["result"], "error": frame["error"]})
		}
		return false, nil
	}
	switch method {
	case "getAuthStatus":
		// An exclusive create detects concurrent native source reads, including
		// refresh network work that the native disk-write lock cannot serialize.
		lock, err := os.OpenFile(path+".busy", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return true, fmt.Errorf("concurrent native source authentication")
		}
		lock.Close()
		defer os.Remove(path + ".busy")
		data, err := os.ReadFile(path)
		if err != nil {
			return true, err
		}
		state := decoded(data)
		if state["block"] == true {
			if err := os.WriteFile(path+".blocked", encoded(object{"pid": os.Getpid()}), 0600); err != nil {
				return true, err
			}
			time.Sleep(time.Minute)
		}
		time.Sleep(25 * time.Millisecond)
		if params["refreshToken"] == true {
			state["forced"] = recordNumber(state["forced"]) + 1
			if next, ok := state["nextToken"]; ok {
				state["authToken"] = next
			}
			if err := os.WriteFile(path, encoded(state), 0600); err != nil {
				return true, err
			}
		}
		return reply(state)
	case "account/login/start":
		if _, err := os.Lstat(filepath.Join(os.Getenv("CODEX_HOME"), "auth.json")); !os.IsNotExist(err) {
			return true, fmt.Errorf("isolated login retained auth.json")
		}
		if !strings.Contains(strings.Join(os.Args, " "), `cli_auth_credentials_store="ephemeral"`) {
			return true, fmt.Errorf("isolated login is not ephemeral")
		}
		if params["refreshToken"] != nil {
			return true, fmt.Errorf("refresh token crossed isolation boundary")
		}
		p.authLogin = params
		return reply(object{"type": params["type"]})
	case "fixture/auth":
		return reply(p.authLogin)
	case "fixture/refresh":
		if p.authPending == nil {
			p.authPending = map[string]any{}
		}
		requestID := "auth-" + text(id)
		p.authPending[requestID] = id
		account := params["account"]
		if account == nil {
			account = p.authLogin["chatgptAccountId"]
		}
		return true, p.send(object{"id": requestID, "method": "account/chatgptAuthTokens/refresh", "params": object{"reason": "unauthorized", "previousAccountId": account}})
	}
	return false, nil
}

func recordNumber(v any) float64 { n, _ := v.(float64); return n }

func verifyIsolatedAuthentication(ctx context.Context, root, binary string) error {
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	path := filepath.Join(root, "source-account.json")
	env["MOKUSEI_CODEX_AUTH_FIXTURE"] = path
	old, rotated, refreshed := fixtureAccessToken("account-a", "old"), fixtureAccessToken("account-a", "rotated"), fixtureAccessToken("account-a", "refreshed")
	state := object{"authMethod": "chatgpt", "authToken": old, "requiresOpenaiAuth": true}
	write := func() error { return os.WriteFile(path, encoded(state), 0600) }
	if err = write(); err != nil {
		return err
	}
	start := func(owner string) (*codex.AppServer, string, error) {
		launch, err := codex.PrepareIsolatedLaunch(ctx, binary, environmentList(env), filepath.Join(root, "harness"), owner, filepath.Join(root, "work"))
		if err != nil {
			return nil, "", err
		}
		server, err := codex.StartAppServer(ctx, codex.LaunchOptions{Executable: binary, Cwd: filepath.Join(root, "work"), Environment: launch.Environment, ConfigOverrides: launch.ConfigOverrides, Dispose: launch.Dispose, AuthSource: launch.AuthSource})
		return server, launch.Home, err
	}
	first, home, err := start("first")
	if err != nil {
		return err
	}
	defer first.Close()
	second, _, err := start("second")
	if err != nil {
		return err
	}
	defer second.Close()
	login, err := first.Call(ctx, "fixture/auth", nil)
	if err != nil {
		return err
	}
	if login["type"] != "chatgptAuthTokens" || login["accessToken"] != old || login["chatgptAccountId"] != "account-a" {
		return fmt.Errorf("initial native credentials were not delegated")
	}
	state["authToken"] = rotated
	if err = write(); err != nil {
		return err
	}
	result, err := first.Call(ctx, "fixture/refresh", nil)
	if err != nil || result["accessToken"] != rotated {
		return fmt.Errorf("source rotation was not observed: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if decoded(data)["forced"] != nil {
		return fmt.Errorf("already rotated credentials forced another refresh")
	}
	// Both clients reject the same current credential. Only one source rotation
	// may occur; the second request must consume its result.
	if _, err = second.Call(ctx, "fixture/refresh", nil); err != nil {
		return err
	}
	state["nextToken"] = refreshed
	if err = write(); err != nil {
		return err
	}
	var wg sync.WaitGroup
	failures := make(chan error, 2)
	for _, server := range []*codex.AppServer{first, second} {
		wg.Add(1)
		go func(server *codex.AppServer) {
			defer wg.Done()
			result, err := server.Call(ctx, "fixture/refresh", nil)
			if err == nil && result["accessToken"] != refreshed {
				err = fmt.Errorf("concurrent refresh returned obsolete token")
			}
			failures <- err
		}(server)
	}
	wg.Wait()
	for range 2 {
		if err = <-failures; err != nil {
			return err
		}
	}
	data, err = os.ReadFile(path)
	if err != nil {
		return err
	}
	if recordNumber(decoded(data)["forced"]) != 1 {
		return fmt.Errorf("concurrent refresh rotated source more than once")
	}
	if _, err = first.Call(ctx, "fixture/refresh", object{"account": "wrong-account"}); err == nil {
		return fmt.Errorf("foreign refresh account was accepted")
	}
	state["authToken"] = fixtureAccessToken("account-b", "switched")
	if err = write(); err != nil {
		return err
	}
	if _, err = first.Call(ctx, "fixture/refresh", nil); err == nil {
		return fmt.Errorf("native account switch was silently accepted")
	}
	state["authToken"] = fixtureAccessTokenForUser("account-a", "other-user", "same-workspace")
	if err = write(); err != nil {
		return err
	}
	if _, err = first.Call(ctx, "fixture/refresh", nil); err == nil {
		return fmt.Errorf("different user in the same workspace was accepted")
	}
	state["authToken"], state["nextToken"] = refreshed, refreshed
	if err = write(); err != nil {
		return err
	}
	if _, err = first.Call(ctx, "fixture/refresh", nil); err == nil {
		return fmt.Errorf("unchanged rejected token counted as a successful refresh")
	}
	state["nextToken"] = nil
	if err = write(); err != nil {
		return err
	}
	if _, err = first.Call(ctx, "fixture/refresh", nil); err == nil {
		return fmt.Errorf("revoked native login was accepted")
	}
	// Closing during a source RPC must cancel and reap that source process.
	state["authToken"], state["block"] = refreshed, true
	if err = write(); err != nil {
		return err
	}
	pending := make(chan error, 1)
	go func() { _, err := first.Call(ctx, "fixture/refresh", nil); pending <- err }()
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	for {
		if _, err := os.Stat(path + ".blocked"); err == nil {
			break
		}
		select {
		case <-deadline.C:
			return fmt.Errorf("source authentication did not start")
		case <-time.After(5 * time.Millisecond):
		}
	}
	if err = first.Close(); err != nil {
		return err
	}
	if err = <-pending; err == nil {
		return fmt.Errorf("closed source request succeeded")
	}
	data, err = os.ReadFile(path + ".blocked")
	if err != nil {
		return err
	}
	if !errors.Is(syscall.Kill(int(recordNumber(decoded(data)["pid"])), 0), syscall.ESRCH) {
		return fmt.Errorf("closed authentication retained native source process")
	}
	os.Remove(path + ".busy") // The killed fixture cannot run its defer.
	delete(state, "block")
	// Reopen a persistent home containing an old crash snapshot without touching
	// the retained native rollout or the source account.
	if err = os.WriteFile(filepath.Join(home, "auth.json"), []byte("obsolete-refresh-token"), 0600); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(home, "rollout-marker"), []byte("history"), 0600); err != nil {
		return err
	}
	state = object{"authMethod": "apikey", "authToken": "local-fixture-key", "requiresOpenaiAuth": true}
	if err = write(); err != nil {
		return err
	}
	reopened, _, err := start("first")
	if err != nil {
		return err
	}
	defer reopened.Close()
	login, err = reopened.Call(ctx, "fixture/auth", nil)
	if err != nil || login["type"] != "apiKey" || login["apiKey"] != "local-fixture-key" {
		return fmt.Errorf("native API key not delegated: %v", err)
	}
	if _, err = os.Stat(filepath.Join(home, "rollout-marker")); err != nil {
		return err
	}
	if _, err = os.Lstat(filepath.Join(home, "auth.json")); !os.IsNotExist(err) {
		return fmt.Errorf("isolated credentials persisted")
	}
	fmt.Println("PASS isolated native auth / source rotation / concurrent refresh / account fence / failed refresh / cancellation / ephemeral API key / history retention")
	return nil
}
