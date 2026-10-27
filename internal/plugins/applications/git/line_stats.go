package git

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Statistics never load patches or run text conversion. The separate budget
// prevents large new directories from delaying status/diff observation indefinitely.
const maxStatsFiles = 256

func (c *client) lineStats(ctx context.Context, p plugin.ApplicationProcessCapability, snapshot Snapshot, files []ChangedFile) (int, int, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	current := map[string]bool{}
	tracked := map[string]bool{}
	for _, file := range files {
		if file.Scope != "untracked" {
			tracked[file.Path] = true
		}
		if !file.Submodule && (snapshot.Head == nil || file.Scope == "untracked") {
			current[file.Path] = true
		}
	}
	if len(current) > maxStatsFiles {
		return 0, 0, readFailure("too-large")
	}
	// An index-deleted path recreated as untracked is not a simple addition to
	// the HEAD diff. Do not present a double-counted delete/add pair as net work.
	if snapshot.Head != nil {
		for path := range current {
			if tracked[path] {
				return 0, 0, readFailure("inaccessible")
			}
		}
	}
	added, deleted := 0, 0
	flags := []string{"--numstat", "-z", "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative", "--ignore-submodules=all", "--find-renames"}
	if snapshot.Head != nil && snapshot.Changed > 0 {
		result, err := c.run(ctx, p, snapshot.Root, maxStatus, append(append([]string{"diff", *snapshot.Head}, flags...), "--")...)
		if err != nil {
			return 0, 0, err
		}
		if result.ExitCode != 0 {
			return 0, 0, readFailure("inaccessible")
		}
		added, deleted, err = parseNumstat(result.Stdout)
		if err != nil {
			return 0, 0, err
		}
	}
	if len(current) == 0 {
		return added, deleted, nil
	}
	root, err := os.OpenRoot(snapshot.Root)
	if err != nil {
		return 0, 0, err
	}
	defer root.Close()
	for path := range current {
		if err := ctx.Err(); err != nil {
			return 0, 0, err
		}
		info, err := root.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return 0, 0, err
		}
		if !info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 {
			return 0, 0, readFailure("inaccessible")
		}
		// Git handles binary attributes, symlink contents and missing final
		// newlines consistently with the native reader, without following links.
		args := append(append([]string{"diff", "--no-index"}, flags...), "--", "/dev/null", path)
		result, err := c.run(ctx, p, snapshot.Root, maxStatus, args...)
		if err != nil {
			return 0, 0, err
		}
		if result.ExitCode != 0 && result.ExitCode != 1 {
			return 0, 0, readFailure("inaccessible")
		}
		a, d, err := parseNumstat(result.Stdout)
		if err != nil {
			return 0, 0, err
		}
		added, err = addLines(added, a)
		if err != nil {
			return 0, 0, err
		}
		deleted, err = addLines(deleted, d)
		if err != nil {
			return 0, 0, err
		}
	}
	return added, deleted, nil
}

func addLines(total, value int) (int, error) {
	const maxSafeInteger = 9_007_199_254_740_991
	if total > maxSafeInteger-value {
		return 0, readFailure("too-large")
	}
	return total + value, nil
}

// NUL framing is essential: filenames may contain tabs and newlines. Renames
// (and --no-index paths) have an empty pathname followed by two NUL fields.
func parseNumstat(output string) (int, int, error) {
	if output == "" {
		return 0, 0, nil
	}
	if !strings.HasSuffix(output, "\x00") {
		return 0, 0, readFailure("inaccessible")
	}
	rows := strings.Split(strings.TrimSuffix(output, "\x00"), "\x00")
	added, deleted := 0, 0
	for i := 0; i < len(rows); i++ {
		fields := strings.SplitN(rows[i], "\t", 3)
		if len(fields) != 3 {
			return 0, 0, readFailure("inaccessible")
		}
		if fields[2] == "" {
			if i+2 >= len(rows) || !validPath(rows[i+1]) || !validPath(rows[i+2]) {
				return 0, 0, readFailure("inaccessible")
			}
			i += 2
		} else if !validPath(fields[2]) {
			return 0, 0, readFailure("inaccessible")
		}
		if fields[0] == "-" && fields[1] == "-" {
			continue
		}
		a, errA := strconv.Atoi(fields[0])
		d, errD := strconv.Atoi(fields[1])
		if errA != nil || errD != nil || a < 0 || d < 0 {
			return 0, 0, readFailure("inaccessible")
		}
		var err error
		added, err = addLines(added, a)
		if err != nil {
			return 0, 0, err
		}
		deleted, err = addLines(deleted, d)
		if err != nil {
			return 0, 0, err
		}
	}
	return added, deleted, nil
}
