package devtool

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func git(ctx context.Context, repo string, args ...string) (string, error) {
	out, err := run(ctx, repo, nil, "git", args...)
	return strings.TrimSpace(out), err
}
func WatchMain(ctx context.Context, repo string, noOpen bool) error {
	out, err := git(ctx, repo, "worktree", "list", "--porcelain")
	if err != nil {
		return err
	}
	var checkout string
	for _, record := range strings.Split(out, "\n\n") {
		lines := strings.Split(record, "\n")
		isMain := false
		var path string
		for _, line := range lines {
			if line == "branch refs/heads/main" {
				isMain = true
			}
			if strings.HasPrefix(line, "worktree ") {
				path = strings.TrimPrefix(line, "worktree ")
			}
		}
		if isMain {
			checkout = path
			break
		}
	}
	if checkout == "" {
		return fmt.Errorf("local main is not checked out in a worktree")
	}
	fmt.Println("[native-main] watching local main every second in", checkout)
	var built, observed, failed, dirtyNotice string
	attempts := 0
	var retryAt time.Time
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		sha, err := git(ctx, checkout, "rev-parse", "--verify", "refs/heads/main^{commit}")
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			fmt.Println(err)
		} else {
			if sha != observed {
				observed = sha
				failed = ""
				attempts = 0
				retryAt = time.Time{}
				dirtyNotice = ""
				fmt.Printf("[native-main] main is now %.12s\n", sha)
			}
			if sha != built && sha != failed && !time.Now().Before(retryAt) {
				head, herr := git(ctx, checkout, "rev-parse", "--verify", "HEAD^{commit}")
				dirty, derr := git(ctx, checkout, "status", "--porcelain=v1", "--untracked-files=all")
				if herr != nil || derr != nil {
					return fmt.Errorf("inspect main checkout: %v %v", herr, derr)
				}
				if head != sha || dirty != "" {
					if dirtyNotice != sha {
						dirtyNotice = sha
						fmt.Printf("[native-main] waiting for clean main worktree at %.12s\n", sha)
					}
				} else {
					attempts++
					fmt.Printf("[native-main] building %.12s (attempt %d/3)\n", sha, attempts)
					err = runDevelopmentTool(ctx, filepath.Clean(checkout), noOpen)
					if ctx.Err() != nil {
						return err
					}
					current, cerr := git(ctx, checkout, "rev-parse", "--verify", "refs/heads/main^{commit}")
					head, herr = git(ctx, checkout, "rev-parse", "--verify", "HEAD^{commit}")
					dirty, derr = git(ctx, checkout, "status", "--porcelain=v1", "--untracked-files=all")
					if cerr != nil || herr != nil || derr != nil {
						return fmt.Errorf("inspect main after build: %v %v %v", cerr, herr, derr)
					}
					if current != sha || head != sha || dirty != "" {
						fmt.Println("[native-main] main changed while building; waiting for latest clean commit")
					} else if err == nil {
						built = sha
						attempts = 0
						retryAt = time.Time{}
					} else if attempts >= 3 {
						failed = sha
						fmt.Printf("[native-main] giving up %.12s after 3 attempts: %v\n", sha, err)
					} else {
						retryAt = time.Now().Add(30 * time.Second)
						fmt.Println("[native-main] retrying in 30 seconds:", err)
					}
				}
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func runDevelopmentTool(ctx context.Context, checkout string, noOpen bool) error {
	directory := filepath.Join(checkout, ".build")
	if err := os.MkdirAll(directory, 0755); err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, "watch-devtool-*")
	if err != nil {
		return err
	}
	executable := file.Name()
	defer os.Remove(executable)
	if err = file.Close(); err != nil {
		return err
	}
	// Compile the current checkout's tool, then own it directly. A `go run`
	// intermediary can exit on SIGTERM before that tool joins its compilers.
	if err = runVisible(ctx, checkout, nil, goExecutable(), "build", "-o", executable, "./cmd/mokusei-dev"); err != nil {
		return err
	}
	args := []string{"fast"}
	if noOpen {
		args = append(args, "--no-open")
	}
	cmd := exec.CommandContext(ctx, executable, args...)
	cmd.Dir = checkout
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return runCommand(ctx, cmd, true)
}
