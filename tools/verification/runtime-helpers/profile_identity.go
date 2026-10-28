package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

func verifyProfileIdentity() error {
	root, err := os.MkdirTemp("", "mokusei-profile-identity-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	home := filepath.Join(root, "home")
	upperPath, lowerPath := filepath.Join(root, "MixedCase"), filepath.Join(root, "mixedcase")
	upper, err := profile.Resolve(profile.Options{DataDir: upperPath, HomeDir: home})
	if err != nil {
		return err
	}
	lower, err := profile.Resolve(profile.Options{DataDir: lowerPath, HomeDir: home})
	if err != nil {
		return err
	}
	assert(upper.DataDir != lower.DataDir && upper.WorkspaceRoot != lower.WorkspaceRoot, "missing paths were case-folded")
	if err = profile.Prepare(upper); err != nil {
		return err
	}
	upperInfo, err := os.Stat(upperPath)
	if err != nil {
		return err
	}
	lowerInfo, lowerErr := os.Stat(lowerPath)
	caseAlias := lowerErr == nil && os.SameFile(upperInfo, lowerInfo)
	if lowerErr != nil && !errors.Is(lowerErr, os.ErrNotExist) {
		return lowerErr
	}
	if !caseAlias {
		if err = profile.Prepare(lower); err != nil {
			return err
		}
	}
	currentUpper, err := profile.Refresh(upper)
	if err != nil {
		return err
	}
	currentLower, err := profile.Refresh(lower)
	if err != nil {
		return err
	}
	if caseAlias {
		assert(currentUpper == currentLower, "existing case aliases have different profile/workspace identities")
		assert(profile.GuardPort(currentUpper) == profile.GuardPort(currentLower), "case aliases selected different ownership guards")
		// Both values were resolved before creation. The old alias must fail
		// even with no owner present; otherwise its different guard can admit a writer.
		owner, acquireErr := profile.Acquire(lower)
		if owner != nil {
			_ = owner.Release()
		}
		var public *model.Error
		assert(errors.As(acquireErr, &public) && public.Code == "STALE_PROFILE", "pre-creation case alias acquired a stale ownership guard")
	} else {
		assert(currentUpper.DataDir != currentLower.DataDir && currentUpper.WorkspaceRoot != currentLower.WorkspaceRoot, "distinct case-sensitive directories lost their identities")
	}
	_, err = profile.Resolve(profile.Options{DataDir: upperPath + "\x00suffix", HomeDir: home})
	assert(err != nil, "NUL profile path was silently truncated")
	if err = verifyConcurrentProfileCreation(root, home, caseAlias); err != nil {
		return err
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	profiles := []profile.Profile{upper, lower}
	// Stop through the originally selected identities, including the alias
	// retained before directory creation. Cleanup does not depend on launch order.
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 60*time.Second)
		defer stop()
		for _, p := range profiles {
			must(daemon.Stop(cleanup, p))
		}
	}()
	var connections [2]*profile.Connection
	var failures [2]error
	var group sync.WaitGroup
	for i, p := range profiles {
		group.Go(func() { connections[i], failures[i] = daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: self}) })
	}
	group.Wait()
	if err = errors.Join(failures[:]...); err != nil {
		return err
	}
	assert(connections[0] != nil && connections[1] != nil, "profile launch did not publish discovery")
	if caseAlias {
		assert(connections[0].Epoch == connections[1].Epoch, "case alias launchers admitted different runtime epochs")
	} else {
		assert(connections[0].Epoch != connections[1].Epoch, "case-sensitive profiles shared one runtime epoch")
	}
	for i, p := range profiles {
		connection, statusErr := daemon.Status(ctx, p)
		if statusErr != nil {
			return statusErr
		}
		assert(connection != nil && connection.Epoch == connections[i].Epoch, "selected profile could not rediscover its runtime")
	}
	if len(os.Args) > 1 && os.Args[1] == "--swift-shutdown" {
		type identityCase struct {
			SelectedDirectory string `json:"selectedDirectory"`
			HomeDirectory     string `json:"homeDirectory"`
			DataDirectory     string `json:"dataDirectory"`
			WorkspaceRoot     string `json:"workspaceRoot"`
		}
		manifest := struct {
			Cases            []identityCase `json:"cases"`
			LiveDirectory    string         `json:"liveDirectory"`
			PrecreationAlias string         `json:"precreationAlias"`
			HomeDirectory    string         `json:"homeDirectory"`
		}{Cases: []identityCase{
			{upperPath, home, currentUpper.DataDir, currentUpper.WorkspaceRoot},
			{lowerPath, home, currentLower.DataDir, currentLower.WorkspaceRoot},
		}, LiveDirectory: currentUpper.DataDir, PrecreationAlias: filepath.Join(root, "swift-late-alias"), HomeDirectory: home}
		data, err := json.Marshal(manifest)
		if err != nil {
			return err
		}
		path := filepath.Join(root, "swift-profile-identities.json")
		if err = os.WriteFile(path, data, 0600); err != nil {
			return err
		}
		command := swiftfixture.Test(ctx, "--filter", "RuntimeShutdownInteropTests/testCanonicalProfileIdentity")
		command.Env = append(os.Environ(), "MOKUSEI_PROFILE_IDENTITY_MANIFEST="+path)
		var output bytes.Buffer
		command.Stdout, command.Stderr = io.MultiWriter(os.Stdout, &output), os.Stderr
		command.WaitDelay = 5 * time.Second
		if err = command.Run(); err != nil {
			return err
		}
		assert(bytes.Contains(output.Bytes(), []byte(fmt.Sprintf("PASS canonical profile fixtures: %d", len(manifest.Cases)))), "Swift profile identity replay was skipped or did not execute all fixtures")
	}
	for _, p := range profiles {
		if err = daemon.Stop(ctx, p); err != nil {
			return err
		}
		for _, path := range []string{p.DiscoveryPath, p.LockPath} {
			_, err = os.Stat(path)
			assert(errors.Is(err, os.ErrNotExist), "profile shutdown retained discovery or ownership")
		}
	}
	fmt.Printf("PASS canonical profile identity: pre-creation paths, discovery/start/stop and workspace agreement (case aliases: %t)\n", caseAlias)
	return nil
}

func verifyConcurrentProfileCreation(root, home string, caseAlias bool) error {
	for iteration := range 4 {
		err := func() error {
			var selected [2]profile.Profile
			for i, name := range []string{"ConcurrentCase", "concurrentcase"} {
				p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(root, fmt.Sprintf("%s-%d", name, iteration)), HomeDir: home})
				if err != nil {
					return err
				}
				selected[i] = p
			}
			if profile.GuardPort(selected[0]) == profile.GuardPort(selected[1]) {
				// Port collisions already fail closed and do not exercise the
				// creation race between two initially different ownership guards.
				return nil
			}
			var owners [2]*profile.Ownership
			var failures [2]error
			var group sync.WaitGroup
			start := make(chan struct{})
			for i, p := range selected {
				group.Go(func() {
					<-start
					owners[i], failures[i] = profile.Acquire(p)
				})
			}
			close(start)
			group.Wait()
			acquired := 0
			for _, owner := range owners {
				if owner != nil {
					acquired++
					defer func() { must(owner.Release()) }()
				}
			}
			if caseAlias {
				assert(acquired == 1, "concurrent creation of case aliases admitted zero or multiple writers")
				for _, err := range failures {
					if err == nil {
						continue
					}
					var public *model.Error
					assert(errors.As(err, &public) && (public.Code == "STALE_PROFILE" || public.Code == "PROFILE_IN_USE"), "case alias ownership failed for an unexpected reason: "+fmt.Sprint(err))
				}
			} else {
				assert(acquired == 2, "distinct case-sensitive profiles could not acquire independent leases")
			}
			return nil
		}()
		if err != nil {
			return err
		}
	}
	return nil
}
