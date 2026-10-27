package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

func replayLazyRecovery(ctx context.Context, root string, paths workspaces.Paths, owners []workspaces.PersistedOwner, original []byte, bin string) {
	threads := make([]model.ThreadRecord, len(owners))
	for i, owner := range owners {
		worktree := owner.Worktree
		threads[i] = model.ThreadRecord{SessionRecord: model.SessionRecord{ID: owner.OwnerThreadID, Cwd: owner.BaseCwd, Worktree: &worktree}}
	}
	request := func(i int) workspaces.AuthorizationRequest {
		owner := owners[i]
		return workspaces.AuthorizationRequest{OwnerThreadID: owner.OwnerThreadID, BaseCwd: owner.BaseCwd, Worktree: owner.Worktree}
	}
	fresh := func() *workspaces.Manager {
		must(os.WriteFile(paths.RegistryPath, original, 0600))
		return workspaces.New(paths)
	}
	gate := filepath.Join(root, "lazy-first-use")
	must(os.Mkdir(gate, 0700))
	oldPath := os.Getenv("PATH")
	must(os.Setenv("PATH", bin+string(os.PathListSeparator)+oldPath))
	must(os.Setenv("MOKUSEI_RECOVERY_GIT_GATE", gate))
	defer func() { must(os.Setenv("PATH", oldPath)); must(os.Unsetenv("MOKUSEI_RECOVERY_GIT_GATE")) }()
	m := fresh()
	check(len(m.RehydratePersistedOwners(ctx, threads)) == 0, "lazy startup rejected valid metadata")
	entries, err := os.ReadDir(gate)
	must(err)
	check(len(entries) == 0, "lazy startup invoked Git")
	before, err := os.ReadFile(paths.RegistryPath)
	must(err)
	firstCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := m.AuthorizeWrite(firstCtx, request(0)); done <- err }()
	deadline := time.Now().Add(8 * time.Second)
	for len(entries) == 0 {
		check(time.Now().Before(deadline) && ctx.Err() == nil, "first lazy use did not invoke Git")
		time.Sleep(5 * time.Millisecond)
		entries, err = os.ReadDir(gate)
		must(err)
	}
	check(len(entries) == 1, "first use inspected unrelated owners")
	select {
	case <-done:
		panic("unverified candidate produced a grant")
	default:
	}
	cancel()
	select {
	case err := <-done:
		check(errors.Is(err, context.Canceled), "lazy first use lost cancellation")
	case <-ctx.Done():
		panic("lazy first use failed to join")
	}
	pid, err := strconv.Atoi(entries[0].Name())
	must(err)
	check(errors.Is(syscall.Kill(-pid, 0), syscall.ESRCH), "lazy cancellation left a Git process group")
	after, err := os.ReadFile(paths.RegistryPath)
	must(err)
	check(bytes.Equal(before, after), "cancelled first use mutated registry")
	must(os.Setenv("PATH", oldPath))
	_, err = m.AuthorizeWrite(ctx, request(0))
	must(err) // cancellation did not consume the candidate or its first grant

	// A missing idle worktree does not block startup or an unrelated owner.
	m = fresh()
	missing := owners[1].Worktree.Cwd + "-temporarily-moved"
	must(os.Rename(owners[1].Worktree.Cwd, missing))
	check(len(m.RehydratePersistedOwners(ctx, threads)) == 0, "lazy startup traversed a missing worktree")
	_, err = m.AuthorizeWrite(ctx, request(1))
	check(err != nil, "missing worktree produced authority")
	_, err = m.AuthorizeWrite(ctx, request(2))
	must(err)
	must(m.Unregister(ctx, owners[1].OwnerThreadID, &owners[1].Worktree))
	must(os.Rename(missing, owners[1].Worktree.Cwd))
	_, err = m.AuthorizeWrite(ctx, request(1))
	check(err != nil, "unregistered lazy candidate revived")
	must(m.ClearOwned(ctx))
	_, err = m.AuthorizeWrite(ctx, request(3))
	check(err != nil, "cleared lazy candidate revived")

	for _, sameOwner := range []bool{true, false} {
		m = fresh()
		duplicate := threads[0]
		if !sameOwner {
			duplicate.ID = "lazy-duplicate-root"
		}
		failures := m.RehydratePersistedOwners(ctx, append(append([]model.ThreadRecord(nil), threads...), duplicate))
		check(len(failures) == 2, "lazy duplicate owner/root accepted")
		_, err = m.AuthorizeWrite(ctx, request(0))
		check(err != nil, "conflicting lazy candidate produced authority")
		_, err = m.AuthorizeWrite(ctx, request(2))
		must(err)
	}
	var registry map[string]any
	must(json.Unmarshal(original, &registry))
	proofs := registry["entries"].([]any)
	registry["entries"] = append(proofs, proofs[0])
	raw, err := json.Marshal(registry)
	must(err)
	must(os.WriteFile(paths.RegistryPath, raw, 0600))
	m = workspaces.New(paths)
	check(len(m.RehydratePersistedOwners(ctx, threads)) > 0, "duplicate persisted proof overwritten silently")

	// Restart may adopt a new HEAD after a prior grant; subsequent writes in
	// this lifetime must still match the admitted HEAD. Initial grants cannot.
	git := func(cwd string, args ...string) string {
		command := exec.CommandContext(ctx, "/usr/bin/git", args...)
		command.Dir = cwd
		out, err := command.CombinedOutput()
		if err != nil {
			panic(fmt.Sprintf("lazy Git fixture: %s: %v", out, err))
		}
		return strings.TrimSpace(string(out))
	}
	commit := func(i int) string {
		cwd := owners[i].Worktree.Cwd
		git(cwd, "-c", "user.name=Mokusei Fixture", "-c", "user.email=fixture@invalid", "commit", "--allow-empty", "-m", "lazy recovery fixture")
		return git(cwd, "rev-parse", "HEAD")
	}
	m = fresh()
	check(len(m.RehydratePersistedOwners(ctx, threads)) == 0, "lazy grant fixture failed")
	oldGrant, err := m.AuthorizeWrite(ctx, request(0))
	must(err)
	newHead := commit(0)
	m = workspaces.New(paths)
	check(len(m.RehydratePersistedOwners(ctx, threads)) == 0, "lazy restart fixture failed")
	stale := request(0)
	stale.ExpectedHeadOID = oldGrant.HeadOID
	_, err = m.AuthorizeWrite(ctx, stale)
	check(err != nil, "explicit stale HEAD bypassed by lazy recovery")
	grant, err := m.AuthorizeWrite(ctx, request(0))
	must(err)
	check(grant.HeadOID == newHead, "lazy recovery did not restore restart HEAD semantics")
	commit(0)
	_, err = m.AuthorizeWrite(ctx, request(0))
	check(err != nil, "lazy recovery became a permanent HEAD bypass")
	commit(8)
	_, err = m.AuthorizeWrite(ctx, request(8))
	check(err != nil, "lazy recovery bypassed initial-grant HEAD fence")
	fmt.Println("PASS zero-Git startup; first-use-only validation; lazy cancellation/retry, missing owner isolation, unregister/clear, duplicate proofs, restart/explicit/initial HEAD fences and repeated write revalidation")
}
