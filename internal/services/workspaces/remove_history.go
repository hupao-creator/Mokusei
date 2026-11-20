package workspaces

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/hupao-creator/Chief/internal/core/plugin"
)

// Only the files ref backend has this private on-disk layout. Inventory it
// directly: revision walkers omit expired/unreachable reflog edges, pseudorefs
// and namespaces such as refs/bisect. Unknown recovery formats stay in place.
func verifyRecoveryHistory(ctx context.Context, s snapshot) error {
	format, err := runGit(ctx, s.Root, "rev-parse", "--show-ref-format")
	if err != nil {
		return err
	}
	if s.ObjectDirectory != filepath.Join(s.CommonDirectory, "objects") || within(s.Root, s.CommonDirectory) {
		return errors.New("cannot verify independent shared object storage; retained")
	}
	if format != "files" {
		return fmt.Errorf("cannot verify private history in %s ref storage", format)
	}
	for _, path := range []string{filepath.Join(s.CommonDirectory, "info", "grafts"), filepath.Join(s.ObjectDirectory, "info", "alternates"), filepath.Join(s.ObjectDirectory, "info", "http-alternates")} {
		if present, err := exists(path); err != nil {
			return err
		} else if present {
			return fmt.Errorf("cannot verify independent shared history with %s; retained", path)
		}
	}
	private, err := privateRecoveryCommits(ctx, s)
	if err != nil {
		return err
	}
	var revisions strings.Builder
	oids := make([]string, 0, len(private))
	for oid := range private {
		oids = append(oids, oid)
	}
	sort.Strings(oids)
	for _, oid := range oids {
		fmt.Fprintln(&revisions, oid)
	}
	if err := verifyObjectTypes(ctx, s.BaseRoot, revisions.String(), "commit"); err != nil {
		return err
	}

	if err := excludeSharedCommits(ctx, s, &revisions); err != nil {
		return err
	}
	lost, err := runGitInput(ctx, s.BaseRoot, revisions.String(), "--no-lazy-fetch", "--no-replace-objects", "rev-list", "--max-count=1", "--stdin")
	if err != nil {
		return err
	}
	if lost != "" {
		return plugin.CallerError(fmt.Errorf("worktree commit %s is not retained by a direct shared branch or tag", lost))
	}
	return nil
}

func privateRecoveryCommits(ctx context.Context, s snapshot) (map[string]bool, error) {
	private := map[string]bool{s.HeadOID: true}
	remaining := 1 << 20
	add := func(oid string) error {
		if len(oid) != len(s.HeadOID) || !oidPattern.MatchString(oid) {
			return errors.New("invalid worktree recovery OID; retained")
		}
		if strings.Trim(oid, "0") != "" {
			private[oid] = true
		}
		return nil
	}
	err := filepath.WalkDir(s.GitDirectory, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		name, err := filepath.Rel(s.GitDirectory, path)
		if err != nil {
			return err
		}
		if d.IsDir() && (name == "." || name == "logs" || name == "refs" || name == "logs/refs" || strings.HasPrefix(name, "logs/refs/") || strings.HasPrefix(name, "refs/")) {
			return nil
		}
		if !d.Type().IsRegular() || strings.HasSuffix(name, ".lock") {
			return fmt.Errorf("unknown or locked Git state %q; retained", name)
		}
		switch name {
		case "locked":
			return plugin.CallerError(errors.New("worktree is locked"))
		case "index", "commondir", "gitdir", "COMMIT_EDITMSG":
			return nil
		}
		log := name == "logs/HEAD" || strings.HasPrefix(name, "logs/refs/")
		if !log && name != "HEAD" && name != "ORIG_HEAD" && !strings.HasPrefix(name, "refs/") {
			return fmt.Errorf("unverified private Git state %q; retained", name)
		}
		body, err := readRegular(path, remaining)
		if err != nil {
			return err
		}
		remaining -= len(body)
		if !log {
			if strings.Trim(strings.TrimSuffix(string(body), "\n"), "0") == "" {
				return errors.New("invalid zero private ref; retained")
			}
			return add(strings.TrimSuffix(string(body), "\n"))
		}
		if len(body) == 0 {
			return nil
		}
		for line := range strings.SplitSeq(strings.TrimSuffix(string(body), "\n"), "\n") {
			old, rest, ok := strings.Cut(line, " ")
			next, _, okNext := strings.Cut(rest, " ")
			if !ok || !okNext {
				return errors.New("cannot verify private reflog; retained")
			}
			if err := add(old); err != nil {
				return err
			}
			if err := add(next); err != nil {
				return err
			}
		}
		return nil
	})
	return private, err
}

func excludeSharedCommits(ctx context.Context, s snapshot, revisions *strings.Builder) error {
	// Enumerate from the surviving checkout. Exclude all symbolic refs: a
	// shared-looking name may resolve through a different worktree's private
	// refs. Check loose and packed storage also survives the removal.
	refs, err := runGit(ctx, s.BaseRoot, "--no-lazy-fetch", "--no-replace-objects", "for-each-ref", "--format=%(refname)%00%(symref)%00%(objecttype)%00%(objectname)%00%(*objecttype)%00%(*objectname)", "refs/heads/", "refs/tags/", "refs/remotes/")
	if err != nil {
		return err
	}
	for line := range strings.SplitSeq(refs, "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\x00")
		if len(fields) != 6 {
			return errors.New("cannot verify surviving Git references")
		}
		if fields[1] != "" {
			continue
		}
		kind, oid := fields[2], fields[3]
		if kind == "tag" {
			kind, oid = fields[4], fields[5]
		}
		if kind != "commit" || !oidPattern.MatchString(oid) {
			continue
		}
		ref := filepath.Join(s.CommonDirectory, fields[0])
		info, err := os.Lstat(ref)
		if errors.Is(err, os.ErrNotExist) {
			ref = filepath.Join(s.CommonDirectory, "packed-refs")
			info, err = os.Lstat(ref)
		}
		if err != nil {
			return err
		}
		real, err := canonical(ref)
		if err != nil {
			return err
		}
		if real != ref || !info.Mode().IsRegular() || within(s.Root, real) || within(s.GitDirectory, real) {
			continue
		}
		fmt.Fprintf(revisions, "^%s\n", oid)
	}
	return nil
}

// Read the surviving object database without fetching or replacing missing
// objects. A tree or index can still name a blob absent from that database.
func verifyObjectTypes(ctx context.Context, cwd, oids, kind string) error {
	if oids == "" {
		return nil
	}
	types, err := runGitInput(ctx, cwd, oids, "--no-lazy-fetch", "--no-replace-objects", "cat-file", "--batch-check=%(objecttype)")
	if err != nil {
		return err
	}
	for actual := range strings.SplitSeq(types, "\n") {
		if actual != kind {
			return fmt.Errorf("cannot verify %s in the shared Git object store; retained", kind)
		}
	}
	return nil
}
