//go:build !darwin

package devtool

import (
	"context"
	"errors"
)

func nativeClientProcesses(context.Context) ([]nativeClientProcess, error) {
	return nil, errors.New("native client inspection requires macOS")
}
