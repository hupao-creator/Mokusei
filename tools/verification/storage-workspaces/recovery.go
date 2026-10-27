package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

// A PATH shim gates real Git process admission without changing production
// APIs. Once released it execs the actual Git in the same owned process group.
func recoveryGitFixture() {
	gate := os.Getenv("MOKUSEI_RECOVERY_GIT_GATE")
	release := filepath.Join(gate, "release")
	if _, err := os.Stat(release); errors.Is(err, os.ErrNotExist) {
		must(os.WriteFile(filepath.Join(gate, strconv.Itoa(os.Getpid())), nil, 0600))
		for {
			if _, err := os.Stat(release); err == nil {
				break
			} else if !errors.Is(err, os.ErrNotExist) {
				panic(err)
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	must(syscall.Exec("/usr/bin/git", append([]string{"git"}, os.Args[1:]...), os.Environ()))
}

func replayParallelRecovery(ctx context.Context, root, gitRoot string) {
	paths := workspaces.Paths{DefaultCwd: gitRoot, RegistryPath: filepath.Join(root, "parallel-owners.json")}
	manager := workspaces.New(paths)
	check(len(manager.RehydrateOwners(ctx, nil)) == 0, "parallel fixture ownership load")
	enabled := true
	var owners []workspaces.PersistedOwner
	for i := range 9 {
		id := fmt.Sprintf("parallel-owner-%d", i)
		prepared, err := manager.PrepareForStart(ctx, gitRoot, id, &model.WorktreeOptions{Enabled: &enabled, Name: id}, nil)
		must(err)
		owners = append(owners, workspaces.PersistedOwner{OwnerThreadID: id, BaseCwd: gitRoot, Worktree: prepared.Worktree})
	}
	original, err := os.ReadFile(paths.RegistryPath)
	must(err)
	fresh := func() *workspaces.Manager {
		must(os.WriteFile(paths.RegistryPath, original, 0600))
		return workspaces.New(paths)
	}
	admit := func(m *workspaces.Manager, owner workspaces.PersistedOwner) error {
		_, err := m.Admit(ctx, workspaces.AuthorizationRequest{OwnerThreadID: owner.OwnerThreadID, BaseCwd: owner.BaseCwd, Worktree: owner.Worktree})
		return err
	}
	bin := filepath.Join(root, "recovery-bin")
	must(os.Mkdir(bin, 0700))
	self, err := os.Executable()
	must(err)
	must(os.Symlink(self, filepath.Join(bin, "git")))
	oldPath := os.Getenv("PATH")
	oldGate, hadGate := os.LookupEnv("MOKUSEI_RECOVERY_GIT_GATE")
	defer func() {
		must(os.Setenv("PATH", oldPath))
		if hadGate {
			must(os.Setenv("MOKUSEI_RECOVERY_GIT_GATE", oldGate))
		} else {
			must(os.Unsetenv("MOKUSEI_RECOVERY_GIT_GATE"))
		}
	}()
	must(os.Setenv("PATH", bin+string(os.PathListSeparator)+oldPath))
	gate := func(name string) string {
		dir := filepath.Join(root, name)
		must(os.Mkdir(dir, 0700))
		must(os.Setenv("MOKUSEI_RECOVERY_GIT_GATE", dir))
		return dir
	}
	pids := func(dir string) []int {
		entries, err := os.ReadDir(dir)
		must(err)
		var ids []int
		for _, entry := range entries {
			if id, err := strconv.Atoi(entry.Name()); err == nil {
				ids = append(ids, id)
			}
		}
		return ids
	}
	waitFour := func(dir string) {
		deadline := time.Now().Add(8 * time.Second)
		for len(pids(dir)) < 4 {
			check(time.Now().Before(deadline) && ctx.Err() == nil, "recovery did not admit four concurrent Git inspections")
			time.Sleep(5 * time.Millisecond)
		}
		// All admitted calls remain gated; a fifth would violate the bound.
		time.Sleep(100 * time.Millisecond)
		check(len(pids(dir)) == 4, "recovery exceeded four concurrent inspections")
	}
	joined := func(done <-chan []workspaces.RecoveryFailure) []workspaces.RecoveryFailure {
		select {
		case failures := <-done:
			return failures
		case <-ctx.Done():
			panic("recovery workers failed to join")
		}
	}
	m := fresh()
	dir := gate("recovery-overlap")
	done := make(chan []workspaces.RecoveryFailure, 1)
	go func() { done <- m.RehydrateOwners(ctx, owners) }()
	waitFour(dir)
	authority := make(chan error, 1)
	go func() { authority <- admit(m, owners[0]) }()
	select {
	case <-done:
		panic("recovery returned before inspection completion")
	case <-authority:
		panic("authority observed partially recovered ownership")
	case <-time.After(100 * time.Millisecond):
	}
	must(os.WriteFile(filepath.Join(dir, "release"), nil, 0600))
	check(len(joined(done)) == 0, "valid parallel recovery failed")
	select {
	case err := <-authority:
		must(err)
	case <-ctx.Done():
		panic("authority remained blocked after recovery")
	}
	// Remove the shim from regular checks; it is only needed at the barriers.
	must(os.Setenv("PATH", oldPath))
	for _, owner := range owners {
		must(admit(m, owner))
	}

	m = fresh()
	invalid := append([]workspaces.PersistedOwner(nil), owners...)
	invalid[1].Worktree.Cwd = filepath.Join(root, "missing-one")
	invalid[7].Worktree.Cwd = filepath.Join(root, "missing-seven")
	failures := m.RehydrateOwners(ctx, invalid)
	check(len(failures) == 2 && failures[0].OwnerThreadID == owners[1].OwnerThreadID && failures[1].OwnerThreadID == owners[7].OwnerThreadID, "per-owner failures lost deterministic order")
	must(admit(m, owners[8]))
	check(admit(m, owners[1]) != nil, "invalid owner retained authority")

	for _, sameOwner := range []bool{true, false} {
		m = fresh()
		duplicate := owners[0]
		if !sameOwner {
			duplicate.OwnerThreadID = "duplicate-root"
		}
		failures = m.RehydrateOwners(ctx, append(append([]workspaces.PersistedOwner(nil), owners...), duplicate))
		check(len(failures) == 2 && failures[0].OwnerThreadID == owners[0].OwnerThreadID && failures[1].OwnerThreadID == duplicate.OwnerThreadID, "duplicate owner/root was accepted or errors reordered")
		check(admit(m, owners[0]) != nil, "duplicate root retained authority")
		must(admit(m, owners[8]))
	}

	m = fresh()
	dir = gate("recovery-cancel")
	must(os.Setenv("PATH", bin+string(os.PathListSeparator)+oldPath))
	cancelCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { done <- m.RehydrateOwners(cancelCtx, owners) }()
	waitFour(dir)
	cancel()
	failures = joined(done)
	check(len(failures) == len(owners)+1, "cancelled owners or final cancellation missing")
	for _, failure := range failures {
		check(errors.Is(failure.Err, context.Canceled), "recovery lost cancellation cause")
	}
	for _, pid := range pids(dir) {
		check(errors.Is(syscall.Kill(-pid, 0), syscall.ESRCH), "recovery returned with a live Git process group")
	}
	after, err := os.ReadFile(paths.RegistryPath)
	must(err)
	check(bytes.Equal(original, after), "cancelled recovery persisted partial results")
	must(os.Setenv("PATH", oldPath))
	check(admit(m, owners[0]) != nil, "cancelled recovery published authority")
	fmt.Println("PASS bounded four-way Git recovery, all owners joined, partial failure order, duplicate rejection, cancellation registry/authority fences and process-group cleanup")
	replayLazyRecovery(ctx, root, paths, owners, original, bin)
}
