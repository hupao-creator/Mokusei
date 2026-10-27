package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/hupao-creator/Mokusei/internal/tooling/devtool"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	args := os.Args[1:]
	start, err := os.Getwd()
	if len(args) >= 2 && args[0] == "--repo" {
		start = args[1]
		args = args[2:]
	}
	if err == nil {
		var repo string
		repo, err = devtool.Repository(start)
		if err == nil {
			err = devtool.Run(ctx, repo, args)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		code := 1
		var withCode interface{ ExitCode() int }
		if errors.As(err, &withCode) {
			code = withCode.ExitCode()
		}
		if errors.Is(err, context.Canceled) {
			code = 130
		}
		os.Exit(code)
	}
}
