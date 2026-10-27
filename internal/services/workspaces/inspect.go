package workspaces

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"golang.org/x/text/unicode/norm"
)

type repository struct{ Root, CommonDirectory, StagingRoot string }
type snapshot struct {
	Root                    string            `json:"root"`
	ExecutionCwd            string            `json:"executionCwd"`
	BaseRoot                string            `json:"baseRoot"`
	StagingRoot             string            `json:"stagingRoot"`
	CommonDirectory         string            `json:"commonDirectory"`
	GitDirectory            string            `json:"gitDirectory"`
	ObjectDirectory         string            `json:"objectDirectory"`
	PackedRefsLock          string            `json:"packedRefsLock"`
	Identity                directoryIdentity `json:"identity"`
	ExecutionCwdIdentity    directoryIdentity `json:"executionCwdIdentity"`
	BaseRootIdentity        directoryIdentity `json:"baseRootIdentity"`
	StagingRootIdentity     directoryIdentity `json:"stagingRootIdentity"`
	CommonDirectoryIdentity directoryIdentity `json:"commonDirectoryIdentity"`
	GitDirectoryIdentity    directoryIdentity `json:"gitDirectoryIdentity"`
	ObjectDirectoryIdentity directoryIdentity `json:"objectDirectoryIdentity"`
	RepositoryIdentity      string            `json:"repositoryIdentity"`
	HeadOID                 string            `json:"headOid"`
}

var invalidSlug = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

const directoryNameMaxRunes = 48

// directoryName reduces a caller-supplied label to one safe path component. It
// normalizes compatibility forms (so full-width text and ligatures become their
// canonical letters), keeps Unicode letters and digits, replaces every other
// character (including path separators, NUL, control characters and symbols)
// with "-", trims leading/trailing "." and "-" so a label can never select a
// hidden or "."/".." entry, caps the result at 48 runes and normalizes the
// final label to NFC. Returning "" means nothing usable remains; callers fall
// back to the generated name rather than silently discarding a name.
func directoryName(s string) string {
	var b strings.Builder
	for _, r := range norm.NFKC.String(s) {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r) || r == '.' || r == '_' || r == '-':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	out := trimDirectoryName(b.String())
	if runes := []rune(out); len(runes) > directoryNameMaxRunes {
		out = trimDirectoryName(string(runes[:directoryNameMaxRunes]))
	}
	return norm.NFC.String(out)
}

func trimDirectoryName(s string) string {
	return strings.Trim(s, ".-")
}

// slug keeps the historical repository/thread identity behavior: ASCII-only
// replacement that trims dashes (not dots), so staging roots for dotted
// submodule paths do not move between releases.
func slug(s string) string {
	s = strings.Trim(invalidSlug.ReplaceAllString(norm.NFKD.String(s), "-"), "-")
	if len(s) > 48 {
		s = s[:48]
	}
	if s == "" {
		return "task"
	}
	return s
}
func repositoryContext(ctx context.Context, cwd string) (repository, error) {
	var r repository
	root, err := runGit(ctx, cwd, "rev-parse", "--show-toplevel")
	if err != nil {
		return r, err
	}
	r.Root, err = canonical(root)
	if err != nil {
		return r, err
	}
	common, err := runGit(ctx, r.Root, "rev-parse", "--git-common-dir")
	if err != nil {
		return r, err
	}
	r.CommonDirectory, err = canonical(resolve(r.Root, common))
	if err != nil {
		return r, err
	}
	entries, err := runGit(ctx, r.Root, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		return r, err
	}
	main := ""
	for _, part := range strings.Split(entries, "\x00") {
		if strings.HasPrefix(part, "worktree ") {
			main, err = canonical(strings.TrimPrefix(part, "worktree "))
			break
		}
	}
	if err != nil {
		return r, err
	}
	if main == "" {
		return r, errors.New("Git main checkout cannot be resolved")
	}
	top, e := runGit(ctx, main, "rev-parse", "--show-toplevel")
	if e == nil {
		top, e = canonical(top)
	}
	if e != nil || top != main {
		main = r.Root
	}
	current := r.Root
	super := ""
	for depth := 0; depth < 32; depth++ {
		p, e := runGit(ctx, current, "rev-parse", "--show-superproject-working-tree")
		if e != nil || p == "" {
			break
		}
		p, e = canonical(p)
		if e != nil || p == current {
			break
		}
		super = p
		current = p
	}
	if super != "" {
		rel, _ := filepath.Rel(super, r.Root)
		r.StagingRoot = filepath.Join(filepath.Dir(super), "."+filepath.Base(super)+"-"+slug(rel)+"-mokusei-worktrees")
	} else {
		r.StagingRoot = filepath.Join(filepath.Dir(main), "."+filepath.Base(main)+"-mokusei-worktrees")
	}
	return r, ctx.Err()
}
func registered(ctx context.Context, base, root string) (bool, error) {
	out, err := runGit(ctx, base, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		return false, err
	}
	for _, e := range strings.Split(out, "\x00") {
		if strings.HasPrefix(e, "worktree ") && filepath.Clean(strings.TrimPrefix(e, "worktree ")) == filepath.Clean(root) {
			return true, nil
		}
	}
	return false, nil
}
func assertRegistered(ctx context.Context, base, root string) error {
	yes, err := registered(ctx, base, root)
	if err != nil {
		return err
	}
	if !yes {
		return fmt.Errorf("Git metadata does not bind worktree: %s", root)
	}
	return nil
}
func detachedHEAD(ctx context.Context, root, expected string) (string, error) {
	name, err := runGit(ctx, root, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return "", err
	}
	if name != "HEAD" {
		return "", fmt.Errorf("managed worktree is no longer detached: %s", name)
	}
	oid, err := runGit(ctx, root, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		return "", err
	}
	if expected != "" && expected != oid {
		return "", fmt.Errorf("worktree HEAD changed (expected %s, actual %s)", expected, oid)
	}
	return oid, nil
}
func headDirectoryPath(ctx context.Context, root, subdir string) error {
	path := ""
	for _, part := range strings.Split(filepath.ToSlash(subdir), "/") {
		if part == "" || part == "." {
			continue
		}
		if path != "" {
			path += "/"
		}
		path += part
		kind, err := runGit(ctx, root, "cat-file", "-t", "HEAD:"+path)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return nil
		}
		if kind != "tree" {
			return errors.New("selected path contains a non-directory entry in HEAD")
		}
	}
	return nil
}
func inspect(ctx context.Context, baseCwd string, worktree model.Worktree, expectedHead string, expected *snapshot) (snapshot, error) {
	var s snapshot
	if err := ctx.Err(); err != nil {
		return s, err
	}
	cwd, err := canonical(worktree.Cwd)
	if err != nil {
		return s, err
	}
	base, err := repositoryContext(ctx, baseCwd)
	if err != nil {
		return s, err
	}
	existing, err := repositoryContext(ctx, cwd)
	if err != nil {
		return s, err
	}
	if base.CommonDirectory != existing.CommonDirectory || base.Root == existing.Root {
		return s, errors.New("managed worktree differs from base repository or points to base checkout")
	}
	if err = privateDirectory(base.StagingRoot); err != nil {
		return s, err
	}
	staging, err := canonical(base.StagingRoot)
	if err != nil {
		return s, err
	}
	if filepath.Dir(existing.Root) != staging || !within(existing.Root, cwd) {
		return s, errors.New("worktree is outside private staging root")
	}
	s.Root = existing.Root
	s.ExecutionCwd = cwd
	s.BaseRoot = base.Root
	s.StagingRoot = staging
	s.CommonDirectory = existing.CommonDirectory
	if s.Identity, err = directoryID(s.Root); err != nil {
		return s, err
	}
	if s.HeadOID, err = detachedHEAD(ctx, s.Root, expectedHead); err != nil {
		return s, err
	}
	if err = assertRegistered(ctx, base.Root, s.Root); err != nil {
		return s, err
	}
	value, err := runGit(ctx, s.Root, "rev-parse", "--git-dir")
	if err != nil {
		return s, err
	}
	s.GitDirectory, err = canonical(resolve(s.Root, value))
	if err != nil {
		return s, err
	}
	metadata, err := canonical(filepath.Join(s.CommonDirectory, "worktrees"))
	if err != nil {
		return s, err
	}
	if filepath.Dir(s.GitDirectory) != metadata {
		return s, errors.New("worktree gitdir is outside common worktrees metadata")
	}
	dotgit := filepath.Join(s.Root, ".git")
	pointer, err := readRegular(dotgit, 64*1024)
	if err != nil {
		return s, err
	}
	p := strings.TrimSpace(string(pointer))
	if len(p) < 7 || !strings.EqualFold(p[:7], "gitdir:") {
		return s, errors.New("invalid linked worktree .git pointer")
	}
	target, err := canonical(resolve(s.Root, strings.TrimSpace(p[7:])))
	if err != nil {
		return s, err
	}
	if target != s.GitDirectory {
		return s, errors.New("linked worktree pointer does not match gitdir")
	}
	backlink, err := readRegular(filepath.Join(s.GitDirectory, "gitdir"), 64*1024)
	if err != nil {
		return s, err
	}
	if resolve(s.GitDirectory, strings.TrimSpace(string(backlink))) != dotgit {
		return s, errors.New("linked worktree metadata backlink does not match checkout")
	}
	s.ObjectDirectory, err = canonical(filepath.Join(s.CommonDirectory, "objects"))
	if err != nil {
		return s, err
	}
	s.PackedRefsLock = filepath.Join(s.CommonDirectory, "packed-refs.lock")
	present, err := exists(s.PackedRefsLock)
	if err != nil {
		return s, err
	}
	if present {
		return s, errors.New("packed-refs.lock exists; managed write grant refused")
	}
	for _, item := range []struct {
		path     string
		identity *directoryIdentity
	}{{s.ExecutionCwd, &s.ExecutionCwdIdentity}, {s.BaseRoot, &s.BaseRootIdentity}, {s.StagingRoot, &s.StagingRootIdentity}, {s.CommonDirectory, &s.CommonDirectoryIdentity}, {s.GitDirectory, &s.GitDirectoryIdentity}, {s.ObjectDirectory, &s.ObjectDirectoryIdentity}} {
		*item.identity, err = directoryID(item.path)
		if err != nil {
			return s, err
		}
	}
	pairs := [][2]any{{s.BaseRoot, s.BaseRootIdentity}, {s.StagingRoot, s.StagingRootIdentity}, {s.CommonDirectory, s.CommonDirectoryIdentity}, {s.GitDirectory, s.GitDirectoryIdentity}, {s.ObjectDirectory, s.ObjectDirectoryIdentity}}
	encoded, _ := json.Marshal(pairs)
	s.RepositoryIdentity = string(encoded)
	if expected != nil && !sameSnapshot(s, *expected) {
		return s, errors.New("managed worktree identity changed during authorization")
	}
	return s, ctx.Err()
}
func sameSnapshot(a, b snapshot) bool { a.HeadOID = ""; b.HeadOID = ""; return a == b }

// Registered checkout deletion cannot be made atomic against concurrent writers.
// Preserve it and report the residual. Only an identity-matched, unregistered,
// empty staging directory may be removed (non-recursively).
func cleanupAttempt(ctx context.Context, base, root string, id directoryIdentity) error {
	var failures []error
	present, err := exists(root)
	if err != nil {
		failures = append(failures, err)
	}
	safe := !present
	if present {
		if err = assertIdentity(root, id); err != nil {
			failures = append(failures, err)
		} else {
			safe = true
		}
	}
	isRegistered, err := registered(ctx, base, root)
	if err != nil {
		failures = append(failures, err)
		safe = false
	}
	if isRegistered {
		if present && safe {
			status, e := runGit(ctx, root, "status", "--porcelain", "--untracked-files=all", "--ignored=matching")
			if e != nil {
				failures = append(failures, e)
			} else if status != "" {
				failures = append(failures, fmt.Errorf("worktree has changed/untracked/ignored content; retained: %s", root))
			}
		}
		failures = append(failures, fmt.Errorf("registered worktree cannot be deleted atomically; checkout and metadata retained: %s", root))
	} else if present && safe {
		if err = assertIdentity(root, id); err == nil {
			err = removeEmptyDirectory(root)
		}
		if err != nil {
			failures = append(failures, err)
		}
	}
	remaining, e := exists(root)
	if e != nil {
		failures = append(failures, e)
	} else if remaining {
		failures = append(failures, fmt.Errorf("worktree path remains after cleanup: %s", root))
	}
	return errors.Join(failures...)
}
