package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

func verifyRequiredServiceTier(ctx context.Context, root, binary string) error {
	environment, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	environment["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	environment["MOKUSEI_CODEX_REPLAY_DEFAULT_TIER"] = "priority"
	api := codex.NewSettingsAPI(func(ctx context.Context, cwd, _ string) (*codex.AppServer, error) {
		return codex.StartAppServer(ctx, codex.LaunchOptions{Executable: binary, Cwd: cwd, Environment: environmentList(environment)})
	})
	schema, err := api.Describe(ctx, plugin.SettingsRequest{Settings: encoded(object{"threadSettings": object{}}), Cwd: filepath.Join(root, "work")})
	if err != nil {
		return err
	}
	description, err := moku.DescribeThreadCreation([]moku.TargetDescription{{HarnessID: "codex", DisplayName: "Codex", NativeSchema: schema}}, root)
	if err != nil {
		return err
	}
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft7)
	compiler.UseRegexpEngine(func(pattern string) (jsonschema.Regexp, error) {
		r, err := regexp2.Compile(pattern, regexp2.ECMAScript)
		if err != nil {
			return nil, err
		}
		r.MatchTimeout = time.Second
		return tierReplayRegexp{r}, nil
	})
	if err = compiler.AddResource("urn:moku-create", decoded(description.InputSchema)); err != nil {
		return err
	}
	compiled, err := compiler.Compile("urn:moku-create")
	if err != nil {
		return err
	}
	for _, choice := range []struct {
		name  string
		value any
		valid bool
	}{{"omitted", nil, false}, {"null", nil, false}, {"false", false, false}, {"inherit", "inherit", false}, {"unknown", "unreported-tier", false}, {"standard", "default", true}, {"fast", "priority", true}} {
		options := object{"model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}}
		if choice.name != "omitted" {
			options["serviceTier"] = choice.value
		}
		request := object{"worktree": false, "harnessId": "codex", "prompt": "A fixture task", "options": options}
		if accepted := compiled.Validate(request) == nil; accepted != choice.valid {
			return fmt.Errorf("Moku schema %s tier: accepted=%v", choice.name, accepted)
		}
		resolved, resolveErr := api.ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: encoded(object{"serviceTier": "priority"}), Requested: encoded(options), Cwd: filepath.Join(root, "work")})
		if (resolveErr == nil) != choice.valid {
			return fmt.Errorf("Codex settings %s tier: %v", choice.name, resolveErr)
		}
		if choice.valid && decoded(resolved)["serviceTier"] != choice.value {
			return fmt.Errorf("Codex settings inherited a tier instead of %s", choice.name)
		}
	}
	// Models sharing thinking capabilities must still have separate tier choices.
	models := []codex.Map{
		{"value": "standard-only", "thinking": codex.Map{"kind": "fixed"}},
		{"value": "fast-capable", "thinking": codex.Map{"kind": "fixed"}, "serviceTiers": []codex.Map{{"value": "priority"}}},
	}
	if err = compiler.AddResource("urn:model-tiers", decoded(encoded(codex.SettingsSchemaForModels(models)))); err != nil {
		return err
	}
	modelSchema, err := compiler.Compile("urn:model-tiers")
	if err != nil {
		return err
	}
	for _, id := range []string{"standard-only", "fast-capable"} {
		options := object{"model": id, "thinking": object{"mode": "fixed"}, "serviceTier": "priority"}
		if accepted := modelSchema.Validate(options) == nil; accepted != (id == "fast-capable") {
			return fmt.Errorf("model-specific tier schema admitted an incompatible choice for %s", id)
		}
	}
	fmt.Println("PASS Moku Codex creation requires an explicit model-supported tier; defaults cannot fill omissions")
	for _, tier := range []string{"default", "priority"} {
		if err = verifyNativeServiceTier(ctx, filepath.Join(root, tier), binary, tier, ""); err != nil {
			return err
		}
	}
	for _, failure := range []string{"missing", "mismatch"} {
		if err = verifyNativeServiceTier(ctx, filepath.Join(root, failure), binary, "default", failure); err != nil {
			return err
		}
	}
	return nil
}

type tierReplayRegexp struct{ *regexp2.Regexp }

func (r tierReplayRegexp) MatchString(value string) bool {
	matched, err := r.Regexp.MatchString(value)
	return err == nil && matched
}

func verifyNativeServiceTier(ctx context.Context, root, binary, tier, reply string) error {
	environment, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	capture := filepath.Join(root, "tier-wire.jsonl")
	environment["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	environment["MOKUSEI_CODEX_REPLAY_DEFAULT_TIER"] = "priority"
	environment["MOKUSEI_CODEX_REPLAY_TIER_CAPTURE"] = capture
	environment["MOKUSEI_CODEX_REPLAY_TIER_REPLY"] = reply
	adapter := codex.New(host(root, environment))
	defer adapter.Close()
	settings := object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": tier, "approvalPolicy": "never", "sandbox": "read-only"}
	thread := model.SessionRecord{ID: "tier-" + tier + reply, Cwd: filepath.Join(root, "work"), Settings: encoded(settings)}
	store := &memoryStore{}
	open := func() (plugin.Handle, error) {
		return adapter.Open(ctx, plugin.OpenContext{ThreadID: thread.ID, RequireExplicitSettings: true, ReadThread: func() model.SessionRecord { return thread }, SessionState: store})
	}
	handle, err := open()
	if err != nil {
		return err
	}
	defer handle.Close()
	send := func(handle plugin.Handle, id string) error {
		return handle.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Read the source fixture"}}}})
	}
	err = send(handle, "first")
	if reply != "" {
		if err == nil || !strings.Contains(err.Error(), "服务层级") {
			return fmt.Errorf("native %s tier confirmation did not reject: %v", reply, err)
		}
	} else {
		if err != nil {
			return err
		}
		if _, err = awaitExecution(ctx, adapter, store, handle, false); err != nil {
			return err
		}
		if err = send(handle, "followup"); err != nil {
			return err
		}
		if _, err = awaitExecution(ctx, adapter, store, handle, false); err != nil {
			return err
		}
		thread.SessionState = store.Read()
		if _, err = adapter.Fork(ctx, plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: thread}, Request: encoded(object{})}); err != nil {
			return err
		}
		if err = handle.Close(); err != nil {
			return err
		}
		handle, err = open()
		if err != nil {
			return err
		}
		defer handle.Close()
		if err = send(handle, "resumed"); err != nil {
			return err
		}
		if _, err = awaitExecution(ctx, adapter, store, handle, false); err != nil {
			return err
		}
		for _, raw := range list(decoded(store.Read())["turns"]) {
			effective, present := record(raw)["runtimeServiceTier"]
			if !present || (tier == "default" && effective != nil) || (tier != "default" && effective != tier) {
				return fmt.Errorf("persisted %s tier mismatch: %v", tier, effective)
			}
		}
	}
	file, err := os.Open(capture)
	if err != nil {
		return err
	}
	defer file.Close()
	counts := map[string]int{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		frame := decoded(scanner.Bytes())
		method := text(frame["method"])
		if method != "thread/start" && method != "thread/resume" && method != "thread/fork" && method != "turn/start" {
			continue
		}
		counts[method]++
		if frame["present"] != true || frame["serviceTier"] != tier {
			return fmt.Errorf("%s omitted or changed %s tier: %s", method, tier, encoded(frame))
		}
	}
	if err = scanner.Err(); err != nil {
		return err
	}
	if reply != "" {
		if counts["turn/start"] != 0 || counts["thread/start"] != 1 {
			return fmt.Errorf("native tier rejection allowed inference: %v", counts)
		}
	} else if counts["thread/start"] != 1 || counts["thread/resume"] != 1 || counts["thread/fork"] != 1 || counts["turn/start"] != 3 {
		return fmt.Errorf("incomplete tier lifecycle replay: %v", counts)
	}
	fmt.Printf("PASS native explicit %s tier / reply=%q / priority defaults / lifecycle wire audit\n", tier, reply)
	return nil
}
