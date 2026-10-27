package devtool

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"time"
)

type buildLeaseKey struct{}

func needsBuildLease(args []string) bool {
	if len(args) == 0 {
		return false
	}
	switch args[0] {
	case "runtime", "build", "bundle", "dev", "fast", "install":
		return true
	}
	return false
}
func withBuildLease(ctx context.Context, repo string, operation func(context.Context) error) error {
	directory := filepath.Join(repo, ".build")
	if err := os.MkdirAll(directory, 0755); err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(directory, "tooling.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return err
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	return operation(context.WithValue(ctx, buildLeaseKey{}, repo))
}

func buildInputs(repo string, native bool) (map[string]string, error) {
	result := map[string]string{}
	add := func(path string) error {
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(repo, path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		result[filepath.ToSlash(relative)] = hex.EncodeToString(sum[:])
		return nil
	}
	for _, name := range []string{"go.mod", "go.sum", "VERSION"} {
		if err := add(filepath.Join(repo, name)); err != nil {
			return nil, err
		}
	}
	directories := []string{"cmd", "internal"}
	if native {
		directories = append(directories, "app/macos/Sources")
		for _, name := range []string{"app/macos/Package.swift", "app/macos/Package.resolved"} {
			if err := add(filepath.Join(repo, name)); err != nil {
				return nil, err
			}
		}
	}
	for _, directory := range directories {
		err := filepath.WalkDir(filepath.Join(repo, directory), func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || entry.Name() == ".DS_Store" {
				return nil
			}
			return add(path)
		})
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}
func unchangedBuildInputs(repo string, native bool, before map[string]string) error {
	after, err := buildInputs(repo, native)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(before, after) {
		return fmt.Errorf("build inputs changed during compilation; rerun after source edits settle")
	}
	return nil
}
