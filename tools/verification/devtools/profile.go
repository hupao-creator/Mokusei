package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/tooling/devtool"
)

func verifyFreshDevelopmentData(home string) {
	previousHome, hadHome := os.LookupEnv("HOME")
	must(os.Setenv("HOME", home))
	defer func() {
		if hadHome {
			must(os.Setenv("HOME", previousHome))
		} else {
			must(os.Unsetenv("HOME"))
		}
	}()
	directory := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := directory + ".previous"
	for path, value := range map[string]string{directory: "current", previous: "previous"} {
		must(os.MkdirAll(path, 0700))
		must(os.WriteFile(filepath.Join(path, "marker"), []byte(value), 0600))
	}
	p, err := profile.Resolve(profile.Options{DataDir: directory, HomeDir: home})
	must(err)
	owner, err := profile.Acquire(p)
	must(err)
	defer owner.Release()
	_, err = devtool.FreshDevelopmentData()
	var public *model.Error
	check(errors.As(err, &public) && public.Code == "PROFILE_IN_USE", "fresh rotated a live runtime profile")
	check(strings.Contains(err.Error(), strconv.Quote(p.DataDir)) && strings.Contains(err.Error(), "stop --data-dir "+strconv.Quote(p.DataDir)), "fresh rejection did not identify current profile and cooperative stop command")
	for path, value := range map[string]string{directory: "current", previous: "previous"} {
		data, err := os.ReadFile(filepath.Join(path, "marker"))
		must(err)
		check(string(data) == value, "rejected fresh changed current or previous data")
	}
	must(owner.Release())
	backup, err := profile.Resolve(profile.Options{DataDir: previous, HomeDir: home})
	must(err)
	backupOwner, err := profile.Acquire(backup)
	must(err)
	defer backupOwner.Release()
	beforeOwner, err := os.ReadFile(backup.LockPath)
	must(err)
	_, err = devtool.FreshDevelopmentData()
	check(errors.As(err, &public) && public.Code == "PROFILE_IN_USE", "fresh removed a live previous profile")
	check(strings.Contains(err.Error(), "stop --data-dir "+strconv.Quote(backup.DataDir)) && !strings.Contains(err.Error(), "stop --data-dir "+strconv.Quote(p.DataDir)), "backup rejection did not identify only the blocked backup's stop command")
	for path, value := range map[string]string{directory: "current", previous: "previous"} {
		data, err := os.ReadFile(filepath.Join(path, "marker"))
		must(err)
		check(string(data) == value, "previous-owner rejection changed current or previous data")
	}
	afterOwner, err := os.ReadFile(backup.LockPath)
	must(err)
	check(string(beforeOwner) == string(afterOwner), "fresh changed previous-profile ownership metadata")
	must(backupOwner.Release())
	entered, release := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	sentinel := errors.New("fixture maintenance failure")
	go func() {
		done <- profile.WithExclusiveAccess(p, func() error {
			close(entered)
			<-release
			return sentinel
		})
	}()
	select {
	case <-entered:
	case err := <-done:
		panic(err)
	case <-time.After(5 * time.Second):
		panic("exclusive profile maintenance did not enter")
	}
	competing, err := profile.Acquire(p)
	if competing != nil {
		must(competing.Release())
	}
	close(release)
	check(errors.As(err, &public) && public.Code == "PROFILE_IN_USE", "runtime entered during exclusive profile maintenance")
	check(errors.Is(<-done, sentinel), "maintenance callback failure was lost")
	_, err = os.Stat(p.LockPath)
	check(errors.Is(err, os.ErrNotExist), "maintenance wrote ownership metadata")
	rotated, err := devtool.FreshDevelopmentData()
	must(err)
	check(rotated == previous, "fresh returned a different backup location")
	data, err := os.ReadFile(filepath.Join(previous, "marker"))
	must(err)
	check(string(data) == "current", "released profile did not rotate current data")
	owner, err = profile.Acquire(p)
	must(err)
	defer owner.Release()
	must(owner.Release())
	must(os.RemoveAll(directory))
	rotated, err = devtool.FreshDevelopmentData()
	must(err)
	check(rotated == "", "missing development profile was not a no-op")
	data, err = os.ReadFile(filepath.Join(previous, "marker"))
	must(err)
	check(string(data) == "current", "missing current profile removed its backup")
	// The guard follows the selected profile's identity, while rotation keeps
	// its existing path semantics: move a selected symlink, not its target.
	target := filepath.Join(home, "external-data")
	must(os.MkdirAll(target, 0700))
	must(os.WriteFile(filepath.Join(target, "marker"), []byte("external"), 0600))
	must(os.Symlink(target, directory))
	aliased, err := profile.Resolve(profile.Options{DataDir: directory, HomeDir: home})
	must(err)
	owner, err = profile.Acquire(aliased)
	must(err)
	defer owner.Release()
	_, err = devtool.FreshDevelopmentData()
	check(errors.As(err, &public) && public.Code == "PROFILE_IN_USE", "fresh ignored ownership through the selected symlink")
	must(owner.Release())
	rotated, err = devtool.FreshDevelopmentData()
	must(err)
	check(rotated == previous, "fresh changed the selected backup path through a symlink")
	info, err := os.Lstat(previous)
	must(err)
	check(info.Mode()&os.ModeSymlink != 0, "fresh moved the symlink target instead of the selected path")
	data, err = os.ReadFile(filepath.Join(target, "marker"))
	must(err)
	check(string(data) == "external", "fresh changed the selected symlink target")
	must(os.Symlink(target, directory))
	rotated, err = devtool.FreshDevelopmentData()
	must(err)
	check(rotated == previous, "two aliases of one profile could not reuse the held guard")
	must(os.Remove(previous))
	must(os.MkdirAll(directory, 0700))
	must(os.WriteFile(filepath.Join(directory, "marker"), []byte("missing-backup"), 0600))
	rotated, err = devtool.FreshDevelopmentData()
	must(err)
	check(rotated == previous, "missing backup could not receive the current profile")
	data, err = os.ReadFile(filepath.Join(previous, "marker"))
	must(err)
	check(string(data) == "missing-backup", "rotation to a missing backup lost current data")
	verifyFreshBackupStartup(directory, previous, home)
}

func verifyFreshBackupStartup(directory, previous, home string) {
	for range 8 {
		must(os.RemoveAll(previous))
		must(os.MkdirAll(directory, 0700))
		must(os.WriteFile(filepath.Join(directory, "marker"), []byte("current"), 0600))
		current, err := profile.Resolve(profile.Options{DataDir: directory, HomeDir: home})
		must(err)
		backup, err := profile.Resolve(profile.Options{DataDir: previous, HomeDir: home})
		must(err)
		if profile.GuardPort(current) == profile.GuardPort(backup) {
			return // A deliberate guard collision fails closed before this race.
		}
		start := make(chan struct{})
		var owner *profile.Ownership
		var acquired, rotated error
		var group sync.WaitGroup
		group.Go(func() {
			<-start
			owner, acquired = profile.Acquire(backup)
		})
		group.Go(func() {
			<-start
			_, rotated = devtool.FreshDevelopmentData()
		})
		close(start)
		group.Wait()
		must(acquired)
		defer owner.Release()
		location := directory
		if rotated == nil {
			location = previous
		}
		data, err := os.ReadFile(filepath.Join(location, "marker"))
		must(err)
		check(string(data) == "current", "concurrent backup startup lost current data")
		// Release checks the original ownership token. Rotation must never
		// remove or replace a backup owner acquired on either side of rename.
		must(owner.Release())
	}
}
