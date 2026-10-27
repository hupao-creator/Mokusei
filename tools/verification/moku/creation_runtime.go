package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

func runWorktreeCreationReplay() error {
	root, err := os.MkdirTemp("", "mokusei-moku-worktree-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	root, err = filepath.EvalSymlinks(root)
	mokuReplayMust(err)
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
	h.workspaces = workspaces.New(workspaces.Paths{DefaultCwd: root, MokuCwd: filepath.Join(root, "moku"), TemporaryRoot: filepath.Join(root, "workspaces"), RegistryPath: filepath.Join(root, "worktrees.json")})
	s := startReplaySystem(root, h)
	defer s.close()
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("coordinate isolated work")))
	h.mu.Lock()
	handle := h.handles[len(h.handles)-1]
	h.mu.Unlock()
	var createTool plugin.ToolBinding
	for _, binding := range handle.open.Injection.Tools.Bindings {
		if binding.Name == "create_thread" {
			createTool = binding
		}
	}
	// True still delegates to the real Git workspace authority; execute using
	// the returned worktreeCwd and prove source-directory isolation.
	repository := filepath.Join(root, "project")
	mokuReplayMust(os.MkdirAll(repository, 0700))
	git := func(args ...string) {
		command := exec.CommandContext(mokuReplayContext(), "git", args...)
		command.Dir = repository
		output, err := command.CombinedOutput()
		if err != nil {
			panic(fmt.Sprintf("fixture git %v: %v: %s", args, err, output))
		}
	}
	git("init", "--quiet")
	mokuReplayMust(os.WriteFile(filepath.Join(repository, "fixture.txt"), []byte("committed"), 0600))
	git("add", "fixture.txt")
	git("-c", "user.name=Replay", "-c", "user.email=replay@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
	worktreeJSON, err := createTool.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{"worktree": true, "worktreeName": "isolated fix", "cwd": repository, "prompt": "isolated delegated task", "harnessId": "mock", "options": map[string]string{"model": "first-model"}})})
	mokuReplayMust(err)
	var isolated struct {
		ThreadID             string `json:"threadId"`
		WorktreeName         string `json:"worktreeName"`
		WorktreeNameAdjusted bool   `json:"worktreeNameAdjusted"`
		Notice               string `json:"notice"`
		Workspace            struct {
			Cwd         string `json:"cwd"`
			WorktreeCwd string `json:"worktreeCwd"`
		} `json:"workspace"`
	}
	mokuReplayMust(json.Unmarshal(worktreeJSON, &isolated))
	isolatedRecord, err := s.r.Thread(isolated.ThreadID)
	mokuReplayMust(err)
	mokuReplayCheck(isolatedRecord.Worktree != nil && isolated.Workspace.WorktreeCwd == isolatedRecord.Worktree.Cwd && isolated.Workspace.WorktreeCwd != isolated.Workspace.Cwd, "true lost committed worktree execution path")
	mokuReplayCheck(filepath.Base(isolated.Workspace.WorktreeCwd) == "isolated-fix", "custom worktreeName did not produce a readable staging directory: "+isolated.Workspace.WorktreeCwd)
	mokuReplayCheck(isolated.WorktreeName == "isolated-fix" && isolated.WorktreeNameAdjusted && strings.Contains(isolated.Notice, "sanitized"), "create_thread did not report the sanitized effective worktreeName")
	data, err := os.ReadFile(filepath.Join(isolated.Workspace.WorktreeCwd, "fixture.txt"))
	mokuReplayMust(err)
	mokuReplayCheck(string(data) == "committed", "returned worktreeCwd lacks committed checkout")
	mokuReplayMust(os.WriteFile(filepath.Join(isolated.Workspace.WorktreeCwd, "isolated.txt"), []byte("only in worktree"), 0600))
	_, err = os.Stat(filepath.Join(repository, "isolated.txt"))
	mokuReplayCheck(errors.Is(err, os.ErrNotExist), "worktree execution wrote into base repository")

	// Unicode labels must survive instead of being silently discarded, and the
	// second use of the same label must report its collision suffix.
	var unicode struct {
		ThreadID             string `json:"threadId"`
		WorktreeName         string `json:"worktreeName"`
		WorktreeNameAdjusted bool   `json:"worktreeNameAdjusted"`
		Notice               string `json:"notice"`
		Workspace            struct {
			WorktreeCwd string `json:"worktreeCwd"`
		} `json:"workspace"`
	}
	unicodeJSON, err := createTool.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{"worktree": true, "worktreeName": "修复登录", "cwd": repository, "prompt": "unicode delegated task", "harnessId": "mock", "options": map[string]string{"model": "first-model"}})})
	mokuReplayMust(err)
	mokuReplayMust(json.Unmarshal(unicodeJSON, &unicode))
	mokuReplayCheck(unicode.WorktreeName == "修复登录" && !unicode.WorktreeNameAdjusted && unicode.Notice == "", "Unicode worktreeName was not returned unchanged: "+string(unicodeJSON))
	mokuReplayCheck(filepath.Base(unicode.Workspace.WorktreeCwd) == "修复登录", "Unicode worktreeName did not reach the filesystem: "+unicode.Workspace.WorktreeCwd)
	unicodeJSON, err = createTool.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{"worktree": true, "worktreeName": "修复登录", "cwd": repository, "prompt": "unicode collision task", "harnessId": "mock", "options": map[string]string{"model": "first-model"}})})
	mokuReplayMust(err)
	mokuReplayMust(json.Unmarshal(unicodeJSON, &unicode))
	mokuReplayCheck(unicode.WorktreeName == "修复登录-2" && unicode.WorktreeNameAdjusted && unicode.Notice != "", "collision did not report an adjusted effective name: "+string(unicodeJSON))
	_, err = createTool.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{"worktree": true, "cwd": root, "prompt": "invalid non-Git workspace", "harnessId": "mock", "options": map[string]string{"model": "first-model"}})})
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "Git"), "true accepted non-Git workspace")
	directJSON, err := createTool.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{"worktree": false, "cwd": repository, "prompt": "direct workspace task", "harnessId": "mock", "options": map[string]string{"model": "first-model"}})})
	mokuReplayMust(err)
	var direct struct {
		ThreadID string `json:"threadId"`
	}
	mokuReplayMust(json.Unmarshal(directJSON, &direct))
	directRecord, err := s.r.Thread(direct.ThreadID)
	mokuReplayMust(err)
	mokuReplayCheck(directRecord.Worktree == nil && directRecord.Cwd == repository, "explicit false enabled a worktree")
	fmt.Println("PASS real create_thread worktree:true returns isolated execution cwd, honors ASCII and Unicode worktreeName, reports collision-adjusted effective names, and preserves Git validation")
	return nil
}
