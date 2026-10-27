// Package directorytag derives the Overview directory label for a workspace.
//
// A workspace can be the repository root, a subdirectory, or a Git linked
// worktree. An ordinary subdirectory keeps its own name; a linked worktree
// lives outside its repository, so using its last path segment would expose an
// implementation detail such as a private task directory. Only a checkout whose
// .git file is proven to be a linked-worktree pointer folds onto the owning
// repository's name.
package directorytag

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

const managedWorktreeSuffix = "-mokusei-worktrees"

// InboxScope is the shared scope for threads without a working directory.
const InboxScope = "inbox"

var managedWorktree = regexp.MustCompile(`^\.(.+)` + managedWorktreeSuffix + `$`)

// generatedTask matches the private staging names created for managed
// worktrees. It is only consulted when the path no longer exists, so a real
// user directory with the same shape keeps its own label.
var generatedTask = regexp.MustCompile(`^task-([0-9a-f]{12}|[0-9a-f]{8}-[0-9a-f]{3}(-[0-9a-f]{32})?|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$`)

// memo caches one label per cleaned cwd. Only positive results are cached:
// worktree registration changes at runtime, so a missing path or a temporary
// workspace must be re-resolved on the next call. The map is bounded so a
// long-lived process cannot grow it without limit.
const memoLimit = 4096

var (
	memo        sync.Map // map[string]string
	memoEntries atomic.Int64

	scopeMemo        sync.Map // map[string]string
	scopeMemoEntries atomic.Int64
)

// Name returns the directory tag for cwd. It returns an empty label for
// temporary workspaces and for vanished managed-worktree paths, where a
// generated name would otherwise leak into the Overview.
func Name(cwd string) string {
	key := normalizePath(cwd)
	if value, ok := memo.Load(key); ok {
		return value.(string)
	}
	name := resolve(key)
	if name == "" {
		// Temporary workspaces and vanished staging paths are negative results;
		// keep them out of the cache so a later layout change is observed.
		return ""
	}
	if memoEntries.Add(1) > memoLimit {
		memo.Range(func(key, _ any) bool {
			memo.Delete(key)
			return true
		})
		memoEntries.Store(1)
	}
	memo.Store(key, name)
	return name
}

// Scope returns the stable workspace identity used to partition tag pools.
// Linked worktrees fold onto the owning repository root; ordinary directories
// and their subdirectories keep their own canonical path. Temporary workspaces
// and empty paths share the inbox scope. The display label from Name is not an
// identity: two directories with the same basename remain distinct.
func Scope(cwd string) string {
	if cwd == "" {
		return InboxScope
	}
	// Scope is an authority boundary, not a display label. Whitespace and
	// backslashes can be literal filename characters on the host filesystem.
	cwd = filepath.Clean(cwd)
	if workspaces.IsTemporaryWorkspacePath(cwd) {
		return InboxScope
	}
	if value, ok := scopeMemo.Load(cwd); ok {
		return value.(string)
	}
	absolute, err := filepath.Abs(cwd)
	if err != nil {
		return cwd
	}
	absolute, exists := canonicalPathStatus(absolute)
	scope := filepath.ToSlash(absolute)
	if root, ok := linkedWorktreeRoot(absolute); ok {
		scope = filepath.ToSlash(root)
	}
	// Only cache a path that resolved on disk; a missing directory may later
	// appear with different symlink or worktree metadata.
	if exists {
		if scopeMemoEntries.Add(1) > memoLimit {
			scopeMemo.Range(func(key, _ any) bool {
				scopeMemo.Delete(key)
				return true
			})
			scopeMemoEntries.Store(1)
		}
		scopeMemo.Store(cwd, scope)
	}
	return scope
}

func canonicalPath(path string) string {
	value, _ := canonicalPathStatus(path)
	return value
}

func canonicalPathStatus(path string) (string, bool) {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return filepath.Clean(resolved), true
	}
	return filepath.Clean(path), false
}

// linkedWorktreeRoot resolves the owning repository root for a linked worktree.
// A plain .git pointer, a submodule pointer and a separate-git-dir checkout are
// not folded; they keep the checkout path as their own scope.
func linkedWorktreeRoot(checkout string) (string, bool) {
	dir := filepath.Clean(checkout)
	for {
		git := filepath.Join(dir, ".git")
		if info, err := os.Stat(git); err == nil {
			if info.IsDir() {
				return "", false
			}
			if info.Mode().IsRegular() {
				gitdir, ok := readGitDir(git)
				if !ok {
					return "", false
				}
				data, err := os.ReadFile(filepath.Join(gitdir, "commondir"))
				if err != nil {
					return "", false
				}
				common := strings.TrimSpace(string(data))
				if common == "" {
					return "", false
				}
				if !filepath.IsAbs(common) {
					common = filepath.Join(gitdir, common)
				}
				common = filepath.Clean(common)
				info, err := os.Stat(common)
				if err != nil || !info.IsDir() || common == gitdir || !gitDirectory(common) {
					return "", false
				}
				if filepath.Base(common) == ".git" {
					return canonicalPath(filepath.Dir(common)), true
				}
				if root := coreWorktree(common); root != "" {
					return canonicalPath(root), true
				}
				return "", false
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

func normalizePath(cwd string) string {
	cwd = strings.TrimRight(strings.TrimFunc(cwd, whitespace), `/\`)
	cwd = strings.ReplaceAll(cwd, `\`, "/")
	if cwd == "" {
		return ""
	}
	return path.Clean(cwd)
}

func resolve(cwd string) string {
	cwd = normalizePath(cwd)
	if cwd == "" {
		return ""
	}
	if workspaces.IsTemporaryWorkspacePath(cwd) {
		return ""
	}
	name, folded, found := worktreeTag(cwd)
	if folded {
		return name
	}
	base := lastSegment(cwd)
	// A plain .git pointer (submodule, separate-git-dir main checkout) is not a
	// linked worktree and keeps the checkout's own basename. A generated task
	// name is different: corrupt or partial worktree metadata under an ancestor
	// repository must still fold through the managed staging convention instead
	// of leaking the private task directory.
	if !found || generatedTask.MatchString(strings.ToLower(base)) {
		if name, ok := managedName(cwd); ok {
			return name
		}
	}
	if base == "" {
		return ""
	}
	if generatedTask.MatchString(strings.ToLower(base)) {
		// Only a genuinely absent path suppresses the label. Permission errors
		// and other failures must keep a live directory's tag.
		if _, err := os.Stat(filepath.FromSlash(cwd)); errors.Is(err, fs.ErrNotExist) {
			return ""
		}
	}
	return base
}

// worktreeTag reports a folded repository label, whether it folded, and whether
// any .git metadata was found. Ordinary repositories and plain .git pointers
// report found without folding so the caller keeps the cwd basename.
func worktreeTag(path string) (string, bool, bool) {
	dir := filepath.Clean(filepath.FromSlash(path))
	if !filepath.IsAbs(dir) {
		absolute, err := filepath.Abs(dir)
		if err != nil {
			return "", false, false
		}
		dir = absolute
	}
	for {
		git := filepath.Join(dir, ".git")
		if info, err := os.Stat(git); err == nil {
			if info.IsDir() {
				return "", false, true
			}
			if info.Mode().IsRegular() {
				name, folded := linkedWorktreeTag(git, dir)
				return name, folded, true
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false, false
		}
		dir = parent
	}
}

// linkedWorktreeTag resolves a .git file. A genuine linked worktree records a
// commondir that resolves to a real Git directory; submodule pointers and
// separate-git-dir main checkouts do not. Anything else is a plain pointer and
// keeps the checkout's own basename.
func linkedWorktreeTag(dotGit, checkout string) (string, bool) {
	gitdir, ok := readGitDir(dotGit)
	if !ok {
		return "", false
	}
	data, err := os.ReadFile(filepath.Join(gitdir, "commondir"))
	if err != nil {
		return "", false
	}
	common := strings.TrimSpace(string(data))
	if common == "" {
		return "", false
	}
	if !filepath.IsAbs(common) {
		common = filepath.Join(gitdir, common)
	}
	common = filepath.Clean(common)
	info, err := os.Stat(common)
	if err != nil || !info.IsDir() || common == gitdir || !gitDirectory(common) {
		return "", false
	}
	if filepath.Base(common) == ".git" {
		return filepath.Base(filepath.Dir(common)), true
	}
	// Separate-git-dir and bare repositories must never surface the storage
	// directory name. Prefer the configured checkout, then the managed
	// convention, then the checkout's own name.
	if root := coreWorktree(common); root != "" {
		return filepath.Base(root), true
	}
	if name, ok := managedName(filepath.ToSlash(checkout)); ok {
		return name, true
	}
	return filepath.Base(checkout), true
}

func readGitDir(dotGit string) (string, bool) {
	data, err := os.ReadFile(dotGit)
	if err != nil {
		return "", false
	}
	line := strings.TrimSpace(string(data))
	const prefix = "gitdir:"
	if len(line) < len(prefix) || !strings.EqualFold(line[:len(prefix)], prefix) {
		return "", false
	}
	target := strings.TrimSpace(line[len(prefix):])
	if target == "" {
		return "", false
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(dotGit), target)
	}
	return filepath.Clean(target), true
}

// gitDirectory requires positive proof that common is a Git directory rather
// than an unrelated ancestor that merely contains a worktrees folder.
func gitDirectory(path string) bool {
	if filepath.Base(path) == ".git" {
		return true
	}
	if _, err := os.Stat(filepath.Join(path, "HEAD")); err != nil {
		return false
	}
	_, err := os.Stat(filepath.Join(path, "config"))
	return err == nil
}

// coreWorktree reads core.worktree from a Git directory's config. Git sets it
// for some separate-git-dir checkouts, letting the tag use the real checkout
// instead of the storage directory.
func coreWorktree(common string) string {
	data, err := os.ReadFile(filepath.Join(common, "config"))
	if err != nil {
		return ""
	}
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if index := strings.IndexAny(section, " \t\""); index >= 0 {
				section = section[:index]
			}
			continue
		}
		if section != "core" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || !strings.EqualFold(strings.TrimSpace(key), "worktree") {
			continue
		}
		value = strings.Trim(strings.TrimSpace(value), `"`)
		if value == "" {
			return ""
		}
		if !filepath.IsAbs(value) {
			value = filepath.Join(common, value)
		}
		return filepath.Clean(value)
	}
	return ""
}

// managedName resolves the Mokusei staging convention. A nested repository
// staging root includes the relative slug (".Mokusei-internal-runtime-…"),
// so prefer a sibling repository that actually exists to avoid a second chip
// for one repository. Prefix-sharing repositories make stripping at every
// dash ambiguous; shared prefixes are only accepted when the worktree's own
// metadata corroborates the owner. Otherwise the un-stripped slug is kept.
func managedName(worktree string) (string, bool) {
	parts := strings.Split(worktree, "/")
	for index, part := range parts {
		match := managedWorktree.FindStringSubmatch(part)
		if match == nil {
			continue
		}
		name := strings.TrimLeft(match[1], ".")
		if name == "" {
			continue
		}
		parent := filepath.Dir(filepath.FromSlash(strings.Join(parts[:index+1], "/")))
		return siblingRepository(parent, name, worktree), true
	}
	return "", false
}

func siblingRepository(parent, name, worktree string) string {
	if looksLikeRepository(filepath.Join(parent, name)) {
		return name
	}
	candidates := []string{}
	for candidate := stripSlugSegment(name); candidate != ""; candidate = stripSlugSegment(candidate) {
		if looksLikeRepository(filepath.Join(parent, candidate)) {
			candidates = append(candidates, candidate)
		}
	}
	switch len(candidates) {
	case 0:
		return name
	case 1:
		// Unambiguous prefix: the only sibling repository that could own this
		// staging root. This preserves the nested-staging fallback.
		return candidates[0]
	default:
		// Several repositories share the prefix (foo and foo-bar). Only trust
		// the worktree's own git metadata; guessing would attribute a checkout
		// of foo to foo-bar.
		if owner := corroboratedOwner(parent, worktree, candidates); owner != "" {
			return owner
		}
		return name
	}
}

// corroboratedOwner reads the worktree's gitdir pointer and accepts a candidate
// whose .git directory owns it. A missing or corrupt pointer yields no owner.
func corroboratedOwner(parent, worktree string, candidates []string) string {
	gitdir, ok := readGitDir(filepath.Join(filepath.FromSlash(worktree), ".git"))
	if !ok {
		return ""
	}
	for _, candidate := range candidates {
		git := filepath.Join(parent, candidate, ".git")
		if gitdir == git || strings.HasPrefix(gitdir, git+string(filepath.Separator)) {
			return candidate
		}
	}
	return ""
}

func stripSlugSegment(name string) string {
	index := strings.LastIndex(name, "-")
	if index <= 0 {
		return ""
	}
	return name[:index]
}

func looksLikeRepository(path string) bool {
	if _, err := os.Stat(filepath.Join(path, ".git")); err == nil {
		return true
	}
	if _, err := os.Stat(filepath.Join(path, "HEAD")); err != nil {
		return false
	}
	_, err := os.Stat(filepath.Join(path, "config"))
	return err == nil
}

func lastSegment(path string) string {
	parts := strings.FieldsFunc(path, func(r rune) bool { return r == '/' })
	if len(parts) == 0 {
		return ""
	}
	return parts[len(parts)-1]
}

// whitespace mirrors the Overview's ECMAScript whitespace trimming.
func whitespace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', '\u00a0', '\u1680', '\u2028', '\u2029', '\u202f', '\u205f', '\u3000', '\ufeff':
		return true
	}
	return r >= '\u2000' && r <= '\u200a'
}
