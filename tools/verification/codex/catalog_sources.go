package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

// Exercise the production adapter source capture, not NewCatalog's factory seam.
func verifyCatalogSources(ctx context.Context, root, binary string) error {
	var failures []error
	for _, routing := range []bool{false, true} {
		for _, scenario := range []string{"state", "keychain", "environment", "auth", "config", "dependency", "ancestor", "large-home", "churn", "rpc-error", "partial-auto", "cancel"} {
			if routing && scenario == "partial-auto" {
				continue
			}
			if !routing && (scenario == "dependency" || scenario == "ancestor" || scenario == "large-home") {
				continue
			}
			dir := filepath.Join(root, fmt.Sprintf("%t-%s", routing, scenario))
			if err := verifyCatalogSource(ctx, dir, binary, scenario, routing); err != nil {
				failure := fmt.Errorf("catalog %s routing=%t: %w", scenario, routing, err)
				fmt.Println("FAIL", failure)
				failures = append(failures, failure)
				continue
			}
			fmt.Printf("PASS Codex catalog source: %s routing=%t\n", scenario, routing)
		}
	}
	return errors.Join(failures...)
}

func verifyCatalogSource(ctx context.Context, root, binary, scenario string, routing bool) error {
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	env["CODEX_HOME"] = filepath.Join(env["HOME"], ".codex")
	env["CODEX_SQLITE_HOME"] = env["CODEX_HOME"]
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["MOKUSEI_CODEX_CATALOG_SOURCE"] = root
	env["MOKUSEI_CODEX_CATALOG_SCENARIO"] = scenario
	env["GORACE"] = "atexit_sleep_ms=0"
	cwd := filepath.Join(env["HOME"], "project", "work")
	bin := filepath.Join(root, "bin")
	for _, path := range []string{env["CODEX_HOME"], cwd, bin, filepath.Join(env["HOME"], "Library", "Keychains")} {
		if err = os.MkdirAll(path, 0700); err != nil {
			return err
		}
	}
	if err = os.Symlink(binary, filepath.Join(bin, "codex")); err != nil {
		return err
	}
	env["PATH"] = bin + string(os.PathListSeparator) + env["PATH"]
	config := filepath.Join(env["CODEX_HOME"], "config.toml")
	modelPath := filepath.Join(root, "catalog-model.json")
	content := "model = \"original-model\"\n"
	if scenario == "dependency" || scenario == "large-home" {
		content += "model_catalog_json = " + strconv.Quote(modelPath) + "\n"
	}
	if scenario == "ancestor" {
		config = filepath.Join(env["HOME"], "project", ".codex", "config.toml")
		if err = os.MkdirAll(filepath.Dir(config), 0700); err != nil {
			return err
		}
	}
	env["MOKUSEI_CODEX_CATALOG_CONFIG"] = config
	if err = os.WriteFile(config, []byte(content), 0600); err != nil {
		return err
	}
	if err = os.WriteFile(modelPath, encoded(object{"model": "original-model"}), 0600); err != nil {
		return err
	}
	if scenario == "large-home" {
		// Real Codex homes contain worktrees/plugins well beyond the scanner budget.
		junk := filepath.Join(env["CODEX_HOME"], "worktrees")
		if err = os.MkdirAll(junk, 0700); err != nil {
			return err
		}
		for i := 0; i < 4100; i++ {
			if err = os.WriteFile(filepath.Join(junk, fmt.Sprintf("%d.json", i)), []byte(`{}`), 0600); err != nil {
				return err
			}
		}
	}
	var environments atomic.Int64
	h := host(root, env)
	h.Environment = func(context.Context) (map[string]string, error) {
		next := map[string]string{}
		for k, v := range env {
			next[k] = v
		}
		n := environments.Add(1)
		if scenario == "environment" {
			next["STARSHIP_SESSION_KEY"] = strconv.FormatInt(n, 10)
		}
		return next, nil
	}
	adapter := codex.New(h)
	defer adapter.Close()
	describe := func(callCtx context.Context) ([]byte, error) {
		if scenario == "partial-auto" {
			return adapter.Settings().ApplyThreadUpdate(callCtx, plugin.UpdateSettingsRequest{
				Cwd:     cwd,
				Current: encoded(object{"model": "original-model", "effort": "low", "serviceTier": "default", "permissionMode": "ask-for-approval", "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"}),
				Update:  encoded(object{"permissionMode": "approve-for-me"}),
			})
		}
		return adapter.Settings().Describe(callCtx, plugin.SettingsRequest{Settings: adapter.DefaultSettings(), Cwd: cwd, RoutingCatalog: routing})
	}
	starts := func() int { files, _ := filepath.Glob(filepath.Join(root, "start-*.json")); return len(files) }
	var raw []byte
	if scenario == "cancel" {
		callCtx, cancel := context.WithCancel(ctx)
		defer cancel()
		done := make(chan error, 1)
		go func() { _, e := describe(callCtx); done <- e }()
		timer := time.NewTimer(10 * time.Second)
		defer timer.Stop()
		for {
			if _, e := os.Stat(filepath.Join(root, "blocked")); e == nil {
				break
			}
			select {
			case e := <-done:
				return fmt.Errorf("ended before cancel barrier: %v", e)
			case <-timer.C:
				return errors.New("cancel barrier missing")
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Millisecond):
			}
		}
		cancel()
		// Release the peer only after the caller's cancellation is observable.
		err = <-done
		if !errors.Is(err, context.Canceled) {
			return fmt.Errorf("cancel lost: %v", err)
		}
		if err = os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
			return err
		}
	} else {
		raw, err = describe(ctx)
		switch scenario {
		case "churn":
			if err == nil || !strings.Contains(err.Error(), "configuration changed") || starts() != 2 {
				return fmt.Errorf("persistent churn: starts=%d error=%v", starts(), err)
			}
			if err = os.WriteFile(filepath.Join(root, "stable"), nil, 0600); err != nil {
				return err
			}
			raw, err = describe(ctx)
			if err != nil || !bytes.Contains(raw, []byte(`"fresh-model-2"`)) || starts() != 3 {
				return fmt.Errorf("stable recovery: starts=%d error=%v", starts(), err)
			}
		case "rpc-error", "partial-auto":
			if err == nil || !strings.Contains(err.Error(), "fixture catalog failure") || starts() != 1 {
				return fmt.Errorf("RPC failure retried or hidden: starts=%d error=%v", starts(), err)
			}
		default:
			want, count := "fresh-model-1", 2
			if scenario == "state" || scenario == "keychain" || scenario == "environment" {
				want, count = "original-model", 1
			}
			if err != nil || starts() != count || !bytes.Contains(raw, []byte(strconv.Quote(want))) {
				return fmt.Errorf("wanted %s with %d starts; got %d: %v", want, count, starts(), err)
			}
			if count == 2 && bytes.Contains(raw, []byte(`"original-model"`)) {
				return errors.New("superseded catalog published")
			}
		}
		if scenario != "rpc-error" && scenario != "partial-auto" {
			before := starts()
			warm, e := describe(ctx)
			extra := 0
			if scenario == "environment" {
				extra = 1
			}
			if e != nil || starts() != before+extra || (extra == 0 && !bytes.Equal(raw, warm)) {
				return fmt.Errorf("warm identity: starts=%d error=%v", starts(), e)
			}
		}
	}
	if err = adapter.Close(); err != nil {
		return err
	}
	if scenario == "cancel" && starts() != 1 {
		return errors.New("cancellation started replacement")
	}
	files, _ := filepath.Glob(filepath.Join(root, "start-*.json"))
	for _, path := range files {
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		pid := int(decoded(data)["pid"].(float64))
		if e = syscall.Kill(pid, 0); !errors.Is(e, syscall.ESRCH) {
			return fmt.Errorf("native peer %d not drained: %v", pid, e)
		}
	}
	return nil
}

type catalogSourcePeer struct {
	root, scenario, model string
	attempt               int
	mutated               bool
}

func startCatalogSourcePeer(root string) (*catalogSourcePeer, error) {
	files, err := filepath.Glob(filepath.Join(root, "start-*.json"))
	if err != nil {
		return nil, err
	}
	// A new attempt is permitted only after the previous native owner exited.
	for _, path := range files {
		data, e := os.ReadFile(path)
		if e != nil {
			return nil, e
		}
		pid := int(decoded(data)["pid"].(float64))
		if e = syscall.Kill(pid, 0); !errors.Is(e, syscall.ESRCH) {
			return nil, fmt.Errorf("replacement overlapped peer %d", pid)
		}
	}
	data, err := os.ReadFile(filepath.Join(root, "catalog-model.json"))
	if err != nil {
		return nil, err
	}
	p := &catalogSourcePeer{root: root, scenario: os.Getenv("MOKUSEI_CODEX_CATALOG_SCENARIO"), model: text(decoded(data)["model"]), attempt: len(files) + 1}
	receipt, err := os.OpenFile(filepath.Join(root, fmt.Sprintf("start-%d.json", p.attempt)), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	_, err = receipt.Write(encoded(object{"pid": os.Getpid()}))
	return p, errors.Join(err, receipt.Close())
}
func (p *peer) catalogSourceFixture(method string, id any) (bool, error) {
	s := p.catalogSource
	if s == nil {
		return false, nil
	}
	if method == "account/read" {
		return true, p.send(object{"id": id, "result": object{"account": object{"type": "apiKey"}}})
	}
	if method != "model/list" {
		return false, nil
	}
	_, stable := os.Stat(filepath.Join(s.root, "stable"))
	if !s.mutated && (s.attempt == 1 || (s.scenario == "churn" && os.IsNotExist(stable))) {
		s.mutated = true
		var path string
		content := []byte(fmt.Sprintf("model = \"fresh-model-%d\"\n", s.attempt))
		changeModel := true
		switch s.scenario {
		case "state":
			path = filepath.Join(os.Getenv("CODEX_HOME"), ".codex-global-state.json")
			content = []byte(`{"openChats":["new"]}`)
			changeModel = false
		case "keychain":
			path = filepath.Join(os.Getenv("HOME"), "Library", "Keychains", "login.keychain-db")
			changeModel = false
		case "environment":
			changeModel = false
		case "auth", "rpc-error", "partial-auto", "cancel":
			path = filepath.Join(os.Getenv("CODEX_HOME"), "auth.json")
			content = []byte(`{"fixture":"initialized"}`)
		case "config", "ancestor", "churn":
			path = os.Getenv("MOKUSEI_CODEX_CATALOG_CONFIG")
		case "dependency", "large-home":
			path = filepath.Join(s.root, "catalog-model.json")
		}
		if path != "" {
			if err := os.WriteFile(path, content, 0600); err != nil {
				return true, err
			}
		}
		if changeModel {
			if err := os.WriteFile(filepath.Join(s.root, "catalog-model.json"), encoded(object{"model": fmt.Sprintf("fresh-model-%d", s.attempt)}), 0600); err != nil {
				return true, err
			}
		}
	}
	if s.scenario == "rpc-error" || s.scenario == "partial-auto" {
		return true, p.send(object{"id": id, "error": object{"code": -32603, "message": "fixture catalog failure"}})
	}
	if s.scenario == "cancel" {
		if err := os.WriteFile(filepath.Join(s.root, "blocked"), nil, 0600); err != nil {
			return true, err
		}
		until := time.Now().Add(15 * time.Second)
		for {
			if _, err := os.Stat(filepath.Join(s.root, "release")); err == nil {
				break
			}
			if time.Now().After(until) {
				return true, errors.New("cancel peer not released")
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	return true, p.send(object{"id": id, "result": object{"nextCursor": nil, "data": []any{object{"model": s.model, "displayName": s.model, "isDefault": true, "supportsReasoning": true, "supportedReasoningEfforts": []any{object{"reasoningEffort": "low"}}, "defaultReasoningEffort": "low", "serviceTiers": []any{object{"id": "priority"}}, "defaultServiceTier": nil}}}})
}
