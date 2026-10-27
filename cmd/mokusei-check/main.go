package main

import (
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/tooling/architecture"
	"os"
	"os/exec"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	if len(os.Args) != 2 {
		return fmt.Errorf("Usage: mokusei-check <architecture|install-hooks>")
	}
	switch os.Args[1] {
	case "architecture":
		if err := architecture.Check("."); err != nil {
			return err
		}
		fmt.Println("Architecture, static registration and no-Node source checks passed")
		return nil
	case "install-hooks":
		command := exec.Command("git", "config", "--local", "core.hooksPath", ".githooks")
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		if err := command.Run(); err != nil {
			return err
		}
		return os.Chmod(".githooks/pre-commit", 0755)
	default:
		return fmt.Errorf("unknown check command: %s", os.Args[1])
	}
}
