// Package maintenance contains explicit, offline-friendly developer maintenance
// commands. It does not access user credentials or run downloaded source code.
package maintenance

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func Repository(start string) (string, error) {
	current, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		data, err := os.ReadFile(filepath.Join(current, "go.mod"))
		if err == nil && strings.Contains(string(data), "module github.com/hupao-creator/Mokusei") {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", errors.New("Mokusei repository not found; pass --repo PATH")
		}
		current = parent
	}
}

func maintenanceRead(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("maintenance input exceeds %d bytes: %s", limit, path)
	}
	return data, nil
}

// Reject links in output paths, including ancestors, before publishing files.
// Atomic writes never open an existing destination for truncation.
func maintenanceOutputPath(path string) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	for current := abs; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err == nil && info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing output through symbolic link: %s", current)
		}
		if filepath.Dir(current) == current {
			break
		}
	}
	return nil
}
func maintenanceAtomicWrite(path string, data []byte) error {
	if err := maintenanceOutputPath(path); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".mokusei-maintain-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err = file.Chmod(0644); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	err = errors.Join(err, file.Close())
	if err != nil {
		return err
	}
	if err = maintenanceOutputPath(path); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}
