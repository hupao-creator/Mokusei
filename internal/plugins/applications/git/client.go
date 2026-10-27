package git

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type readFailure string

func (e readFailure) Error() string { return "Local Git read failed: " + string(e) }
func readCode(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var failure readFailure
	if errors.As(err, &failure) {
		return string(failure)
	}
	var process *plugin.ApplicationProcessError
	if errors.As(err, &process) {
		switch process.Code {
		case "not-found":
			return "unavailable"
		case "timeout":
			return "timeout"
		case "output-limit":
			return "too-large"
		}
	}
	return "inaccessible"
}

// One shared gate bounds both monitor and interactive reads. Waiting is cancellable.
type client struct{ gate chan struct{} }

func (c *client) acquire(ctx context.Context) (func(), error) {
	select {
	case c.gate <- struct{}{}:
		return func() { <-c.gate }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func (c *client) run(ctx context.Context, process plugin.ApplicationProcessCapability, cwd string, limit int64, args ...string) (plugin.ApplicationProcessResult, error) {
	release, err := c.acquire(ctx)
	if err != nil {
		return plugin.ApplicationProcessResult{}, err
	}
	defer release()
	env := map[string]*string{}
	for _, key := range []string{"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS"} {
		env[key] = nil
	}
	for key, value := range map[string]string{"LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat"} {
		env[key] = ptr(value)
	}
	// Patch syntax is a wire format for the native reader, independent of a
	// user's terminal presentation preferences (including empty context lines).
	fixed := []string{"--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.quotePath=true", "-c", "diff.suppressBlankEmpty=false"}
	result, err := process.Run(ctx, plugin.ApplicationProcessInput{Command: "git", Args: append(fixed, args...), Cwd: cwd, TimeoutMS: 10000, MaxOutputBytes: limit, Env: env})
	if err != nil {
		// The process capability reports parent deadlines as cancellation. Keep
		// the caller's deadline so the shared statistics budget remains a timeout.
		if ctx.Err() != nil {
			return result, ctx.Err()
		}
		return result, err
	}
	if !utf8.ValidString(result.Stdout) {
		return result, readFailure("inaccessible")
	}
	return result, nil
}
func (c *client) locate(ctx context.Context, p plugin.ApplicationProcessCapability, cwd string) (string, error) {
	info, err := os.Stat(cwd)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", nil
	}
	result, err := c.run(ctx, p, cwd, maxStatus, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	if result.ExitCode != 0 {
		if strings.Contains(result.Stderr, "not a git repository") || strings.Contains(result.Stderr, "must be run in a work tree") {
			return "", nil
		}
		return "", readFailure("inaccessible")
	}
	// Strip only Git's delimiter; a path itself may end in a newline.
	root, err := filepath.EvalSymlinks(strings.TrimSuffix(result.Stdout, "\n"))
	if err != nil {
		return "", err
	}
	if !validRoot(root) {
		return "", readFailure("inaccessible")
	}
	return root, nil
}
func (c *client) status(ctx context.Context, p plugin.ApplicationProcessCapability, root string) (Snapshot, []ChangedFile, error) {
	result, err := c.run(ctx, p, root, maxStatus, "status", "--porcelain=v2", "-z", "--branch", "--ahead-behind", "--untracked-files=all", "--ignore-submodules=none")
	if err != nil {
		return Snapshot{}, nil, err
	}
	if result.ExitCode != 0 {
		return Snapshot{}, nil, readFailure("inaccessible")
	}
	return parseStatus(root, result.Stdout)
}
func parseStatus(root, output string) (Snapshot, []ChangedFile, error) {
	s := Snapshot{Root: root}
	files := []ChangedFile{}
	changedPaths := map[string]bool{}
	head, branch := false, false
	fail := func() (Snapshot, []ChangedFile, error) { return Snapshot{}, nil, readFailure("inaccessible") }
	if !strings.HasSuffix(output, "\x00") {
		return fail()
	}
	rows := strings.Split(strings.TrimSuffix(output, "\x00"), "\x00")
	for i := 0; i < len(rows); i++ {
		row := rows[i]
		switch {
		case strings.HasPrefix(row, "# branch.oid "):
			v := strings.TrimPrefix(row, "# branch.oid ")
			if v != "(initial)" {
				if len(v) != 40 && len(v) != 64 {
					return fail()
				}
				for _, r := range v {
					if !strings.ContainsRune("0123456789abcdef", r) {
						return fail()
					}
				}
				s.Head = ptr(v)
			}
			head = true
		case strings.HasPrefix(row, "# branch.head "):
			v := strings.TrimPrefix(row, "# branch.head ")
			if v == "" {
				return fail()
			}
			if v != "(detached)" {
				s.Branch = ptr(v)
			}
			branch = true
		case strings.HasPrefix(row, "# branch.upstream "):
			s.Upstream = ptr(strings.TrimPrefix(row, "# branch.upstream "))
		case strings.HasPrefix(row, "# branch.ab "):
			fields := strings.Fields(row)
			if len(fields) != 4 || !strings.HasPrefix(fields[2], "+") || !strings.HasPrefix(fields[3], "-") {
				return fail()
			}
			a, e := strconv.Atoi(fields[2][1:])
			if e != nil || a < 0 {
				return fail()
			}
			b, e := strconv.Atoi(fields[3][1:])
			if e != nil || b < 0 {
				return fail()
			}
			s.Ahead = ptr(a)
			s.Behind = ptr(b)
		case strings.HasPrefix(row, "# "), strings.HasPrefix(row, "! "):
			continue
		case strings.HasPrefix(row, "? "):
			path := row[2:]
			if !validPath(path) {
				return fail()
			}
			files = append(files, ChangedFile{Path: path, Status: "A", Scope: "untracked"})
			changedPaths[path] = true
			s.Untracked++
		default:
			if len(row) < 5 || row[1] != ' ' || !strings.ContainsRune("12u", rune(row[0])) {
				return fail()
			}
			count := 9
			if row[0] == '2' {
				count = 10
			}
			if row[0] == 'u' {
				count = 11
			}
			fields := strings.SplitN(row, " ", count)
			if len(fields) != count || len(fields[1]) != 2 || len(fields[2]) != 4 || !validPath(fields[count-1]) {
				return fail()
			}
			xy := fields[1]
			for _, r := range xy {
				if !strings.ContainsRune(".MADRCUT", r) {
					return fail()
				}
			}
			f := ChangedFile{Path: fields[count-1], Submodule: fields[2][0] == 'S'}
			if row[0] == '2' {
				i++
				if i >= len(rows) || !validPath(rows[i]) {
					return fail()
				}
				f.OldPath = ptr(rows[i])
			}
			changedPaths[f.Path] = true
			if row[0] == 'u' {
				f.Scope = "conflicts"
				f.Status = xy
				files = append(files, f)
				s.Conflicts++
				continue
			}
			if xy[0] != '.' {
				staged := f
				staged.Scope = "staged"
				staged.Status = xy[:1]
				files = append(files, staged)
				s.Staged++
			}
			if xy[1] != '.' {
				f.Scope = "unstaged"
				f.Status = xy[1:]
				f.OldPath = nil
				files = append(files, f)
				s.Unstaged++
			}
		}
	}
	s.Changed = len(changedPaths)
	if !head || !branch {
		return fail()
	}
	if err := validateSnapshot(s); err != nil {
		return fail()
	}
	return s, files, nil
}
func (c *client) validateRoot(ctx context.Context, p plugin.ApplicationProcessCapability, root string) error {
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil || canonical != root {
		return errors.New("Git worktree is no longer available")
	}
	located, err := c.locate(ctx, p, root)
	if err != nil {
		return err
	}
	if located != root {
		return errors.New("Git worktree is no longer available")
	}
	return nil
}
func (c *client) diff(ctx context.Context, p plugin.ApplicationProcessCapability, root string, input Selection) (DiffContent, error) {
	_, files, err := c.status(ctx, p, root)
	if err != nil {
		return DiffContent{}, err
	}
	var file *ChangedFile
	for i := range files {
		if files[i].Path == input.Path && files[i].Scope == input.Scope {
			file = &files[i]
			break
		}
	}
	if file == nil {
		return DiffContent{}, errors.New("This file changed; refresh the file list")
	}
	notice := func(s string) (DiffContent, error) { return DiffContent{Notice: ptr(s)}, nil }
	if file.Scope == "conflicts" {
		return notice("conflict")
	}
	args := []string{"diff"}
	if file.Scope == "untracked" {
		args = append(args, "--no-index")
	} else if file.Scope == "staged" {
		args = append(args, "--cached")
	}
	args = append(args, "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/", "--unified=3")
	if file.Scope != "untracked" {
		args = append(args, "--submodule=short", "--ignore-submodules=none", "--find-renames")
	}
	args = append(args, "--")
	if file.Scope == "untracked" {
		args = append(args, "/dev/null")
	} else if file.OldPath != nil {
		args = append(args, *file.OldPath)
	}
	args = append(args, file.Path)
	result, err := c.run(ctx, p, root, maxPatch, args...)
	if err != nil {
		if readCode(err) == "too-large" {
			return notice("too-large")
		}
		return DiffContent{}, err
	}
	if result.ExitCode != 0 && !(file.Scope == "untracked" && result.ExitCode == 1) {
		return DiffContent{}, fmt.Errorf("Cannot read this Git diff (exit %d)", result.ExitCode)
	}
	for _, line := range strings.Split(result.Stdout, "\n") {
		if strings.HasPrefix(line, "Binary files ") && strings.HasSuffix(line, " differ") || line == "GIT binary patch" {
			return notice("binary")
		}
	}
	if result.Stdout == "" {
		if file.Submodule {
			return notice("submodule")
		}
		return notice("empty")
	}
	return DiffContent{Patch: result.Stdout}, nil
}
