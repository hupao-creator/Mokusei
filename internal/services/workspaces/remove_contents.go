package workspaces

import (
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/hupao-creator/Chief/internal/core/plugin"
)

type treeEntry struct{ mode, oid string }

var dirtyCheckout = plugin.CallerError(errors.New("worktree contains uncommitted, untracked or ignored files"))

// Compare three independent representations: the committed tree, index entries
// and the actual directory entries and bytes. Git status can report clean based
// solely on cached stat data, file-type emulation or a lossy clean filter.
func verifyCheckout(ctx context.Context, s snapshot, created map[string]directoryIdentity, checkoutPresent bool) error {
	tree, err := runGit(ctx, s.BaseRoot, "--no-lazy-fetch", "--no-replace-objects", "ls-tree", "-rtz", s.HeadOID)
	if err != nil {
		return err
	}
	entries := make(map[string]treeEntry)
	filesInTree := 0
	var blobs strings.Builder
	for record := range strings.SplitSeq(tree, "\x00") {
		if record == "" {
			continue
		}
		meta, name, ok := strings.Cut(record, "\t")
		fields := strings.Fields(meta)
		if !ok || len(fields) != 3 || !filepath.IsLocal(name) || !oidPattern.MatchString(fields[2]) {
			return errors.New("cannot verify committed tree entry")
		}
		switch fields[0] {
		case "040000":
		case "100644", "100755", "120000":
			filesInTree++
			fmt.Fprintln(&blobs, fields[2])
		default:
			return fmt.Errorf("unsupported Git entry mode %s at %q; retained", fields[0], name)
		}
		entries[name] = treeEntry{fields[0], fields[2]}
	}
	if err := verifyObjectTypes(ctx, s.BaseRoot, blobs.String(), "blob"); err != nil {
		return err
	}
	if err := verifyIndex(ctx, s, entries, filesInTree, checkoutPresent); err != nil || !checkoutPresent {
		return err
	}
	err = filepath.WalkDir(s.Root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if path == s.Root || path == filepath.Join(s.Root, ".git") {
			return nil
		}
		name, err := filepath.Rel(s.Root, path)
		if err != nil {
			return err
		}
		entry, ok := entries[name]
		if !ok {
			// Keep walking each proven directory. Every descendant must also
			// match a committed entry or an original Chief-created directory.
			if id, owned := created[name]; owned && d.IsDir() && strings.Trim(id.Birthtime, "0.") != "" {
				return assertIdentity(path, id)
			}
			return dirtyCheckout
		}
		delete(entries, name)
		info, err := d.Info()
		if err != nil {
			return err
		}
		id, err := identityOf(info)
		if err != nil {
			return err
		}
		if id.Dev != s.Identity.Dev {
			return fmt.Errorf("external filesystem at %q; retained", name)
		}
		return verifyTreeEntry(ctx, path, info, entry)
	})
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return dirtyCheckout
	}
	return nil
}

func verifyIndex(ctx context.Context, s snapshot, entries map[string]treeEntry, filesInTree int, checkoutPresent bool) error {
	// ls-files reads only the private index. An explicit existing cwd lets it
	// inspect staged work even after Git has unlinked the physical checkout.
	cwd := s.Root
	if !checkoutPresent {
		cwd = s.BaseRoot
		if present, err := exists(filepath.Join(s.GitDirectory, "index")); err != nil || !present {
			return err
		}
	}
	options := []string{"--git-dir=" + s.GitDirectory, "--work-tree=" + cwd, "--no-optional-locks", "-c", "core.fsmonitor=false"}
	files, err := runGit(ctx, cwd, append(options, "ls-files", "--stage", "-v", "-z")...)
	if err != nil {
		return err
	}
	var paths strings.Builder
	count := 0
	for record := range strings.SplitSeq(files, "\x00") {
		if record == "" {
			continue
		}
		meta, name, ok := strings.Cut(record, "\t")
		fields := strings.Fields(meta)
		if !ok || len(fields) != 4 || fields[0] != "H" {
			return plugin.CallerError(errors.New("worktree index hides changes or has unmerged entries"))
		}
		entry, ok := entries[name]
		if !ok || entry.mode == "040000" || entry.mode != fields[1] || entry.oid != fields[2] || fields[3] != "0" {
			return dirtyCheckout
		}
		paths.WriteString(name)
		paths.WriteByte(0)
		count++
	}
	if count != filesInTree {
		return dirtyCheckout
	}
	undo, err := runGit(ctx, cwd, append(options, "ls-files", "--resolve-undo", "-z")...)
	if err != nil {
		return err
	}
	if undo != "" {
		return errors.New("worktree index contains conflict recovery entries; retained")
	}
	if !checkoutPresent {
		return nil
	}
	// Only accept a literal checkout. A configured clean conversion may map
	// distinct working copies to the same blob or execute an external driver.
	attrs, err := runGitInput(ctx, s.Root, paths.String(), "check-attr", "-z", "--stdin", "--all")
	if err != nil {
		return err
	}
	if attrs != "" {
		fields := strings.Split(strings.TrimSuffix(attrs, "\x00"), "\x00")
		if len(fields)%3 != 0 {
			return errors.New("cannot verify checkout attributes")
		}
		for i := 0; i < len(fields); i += 3 {
			if fields[i+1] == "text" && fields[i+2] == "auto" {
				continue
			}
			switch fields[i+1] {
			case "filter", "working-tree-encoding", "ident", "text", "eol", "crlf":
				if fields[i+2] != "unset" {
					return fmt.Errorf("checkout conversion %s at %q cannot be verified; retained", fields[i+1], fields[i])
				}
			}
		}
	}
	crlf, err := runGit(ctx, s.Root, "config", "--default=false", "--get", "core.autocrlf")
	if err != nil {
		return err
	}
	if !strings.EqualFold(crlf, "false") {
		return errors.New("core.autocrlf conversion cannot be verified; retained")
	}

	return nil
}

func verifyTreeEntry(ctx context.Context, path string, info fs.FileInfo, entry treeEntry) error {
	if entry.mode == "040000" {
		if info.IsDir() {
			return nil
		}
		return dirtyCheckout
	}
	var digest hash.Hash
	switch len(entry.oid) {
	case 40:
		digest = sha1.New()
	case 64:
		digest = sha256.New()
	default:
		return errors.New("unknown Git object format")
	}
	switch {
	case info.Mode()&os.ModeSymlink != 0 && entry.mode == "120000":
		target, err := os.Readlink(path)
		if err != nil {
			return err
		}
		fmt.Fprintf(digest, "blob %d\x00%s", len(target), target)
	case info.Mode().IsRegular() && (entry.mode == "100644" || entry.mode == "100755"):
		if (info.Mode().Perm()&0100 != 0) != (entry.mode == "100755") {
			return dirtyCheckout
		}
		f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != nil {
			return err
		}
		defer f.Close()
		actual, err := f.Stat()
		if err != nil {
			return err
		}
		if !os.SameFile(info, actual) || actual.Mode() != info.Mode() || actual.Size() != info.Size() {
			return dirtyCheckout
		}
		fmt.Fprintf(digest, "blob %d\x00", info.Size())
		for left := info.Size(); left > 0; {
			if err := ctx.Err(); err != nil {
				return err
			}
			n, err := io.CopyN(digest, f, min(left, 4<<20))
			if err != nil {
				return err
			}
			left -= n
		}
	default:
		return dirtyCheckout
	}
	current, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !os.SameFile(info, current) || current.Mode() != info.Mode() || current.Size() != info.Size() || !current.ModTime().Equal(info.ModTime()) || hex.EncodeToString(digest.Sum(nil)) != entry.oid {
		return dirtyCheckout
	}
	return nil
}
