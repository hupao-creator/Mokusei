//go:build !darwin

package profile

import "path/filepath"

func existingPath(path string) (string, error) { return filepath.EvalSymlinks(path) }
