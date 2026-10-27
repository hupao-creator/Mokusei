package directorytag

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

type parityFixture struct {
	Version int `json:"version"`
	Cases   []struct {
		Name        string            `json:"name"`
		Directories []string          `json:"directories"`
		Files       map[string]string `json:"files"`
		Cwd         string            `json:"cwd"`
		Relative    bool              `json:"relative"`
		Want        string            `json:"want"`
	} `json:"cases"`
}

// TestSharedParityFixtures drives the same fixture corpus as the Swift test so
// the two metadata-only resolvers cannot drift.
func TestSharedParityFixtures(t *testing.T) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate parity fixture")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(source), "..", "..", "..", "testdata", "directorytag", "parity.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixtures parityFixture
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	if fixtures.Version != 1 || len(fixtures.Cases) == 0 {
		t.Fatalf("unexpected fixture corpus: version %d, %d cases", fixtures.Version, len(fixtures.Cases))
	}
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for _, fixture := range fixtures.Cases {
		t.Run(fixture.Name, func(t *testing.T) {
			root := tempRoot(t)
			for _, directory := range fixture.Directories {
				if err := os.MkdirAll(fixturePath(directory, root), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			for path, contents := range fixture.Files {
				full := fixturePath(path, root)
				if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(full, []byte(fixtureContents(contents, root)), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			cwd := fixtureContents(fixture.Cwd, root)
			if fixture.Relative {
				if cwd, err = filepath.Rel(working, cwd); err != nil {
					t.Fatal(err)
				}
			}
			if got := Name(cwd); got != fixture.Want {
				t.Fatalf("Name(%q) = %q, want %q", cwd, got, fixture.Want)
			}
		})
	}
}

func fixturePath(value, root string) string {
	path := filepath.FromSlash(strings.ReplaceAll(value, "$ROOT", root))
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	return path
}

func fixtureContents(value, root string) string {
	return strings.ReplaceAll(value, "$ROOT", root)
}

// An ordinary repository subdirectory keeps showing its own last path segment.
func TestOrdinarySubdirectoryKeepsBasename(t *testing.T) {
	main := initRepository(t, filepath.Join(tempRoot(t), "OrdinaryRepo"))
	subdirectory := filepath.Join(main, "app")
	if err := os.MkdirAll(subdirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(subdirectory); got != "app" {
		t.Fatalf("Name(%q) = %q, want app", subdirectory, got)
	}
}

// A git submodule has a plain .git pointer, not a linked-worktree commondir.
func TestRealSubmoduleKeepsOwnName(t *testing.T) {
	gitPath := requireGit(t)
	root := tempRoot(t)
	source := initRepository(t, filepath.Join(root, "submodule-source"))
	super := initRepository(t, filepath.Join(root, "super"))
	runGit(t, gitPath, super, "-c", "protocol.file.allow=always", "submodule", "add", source, "sub")
	submodule := filepath.Join(super, "sub")
	if got := Name(submodule); got != "sub" {
		t.Fatalf("Name(%q) = %q, want sub", submodule, got)
	}
	nested := filepath.Join(submodule, "src")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(nested); got != "src" {
		t.Fatalf("Name(%q) = %q, want src", nested, got)
	}
}

// A separate git directory and its linked worktree must never leak the storage
// directory name as the label.
func TestRealSeparateGitDirNeverLeaksStorageName(t *testing.T) {
	gitPath := requireGit(t)
	root := tempRoot(t)
	storage := filepath.Join(root, "sep-git-storage")
	checkout := filepath.Join(root, "SepRepo")
	if err := os.MkdirAll(checkout, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(t, gitPath, checkout, "init", "-q", "--separate-git-dir", storage)
	runGit(t, gitPath, checkout, "config", "user.email", "test@example.com")
	runGit(t, gitPath, checkout, "config", "user.name", "Mokusei Test")
	if err := os.WriteFile(filepath.Join(checkout, "README.md"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, gitPath, checkout, "add", "README.md")
	runGit(t, gitPath, checkout, "commit", "-qm", "fixture")
	if got := Name(checkout); got != "SepRepo" {
		t.Fatalf("Name(%q) = %q, want SepRepo", checkout, got)
	}
	worktree := filepath.Join(root, "sep-wt")
	runGit(t, gitPath, checkout, "worktree", "add", "--detach", worktree)
	// Git does not write core.worktree for this layout, so the linked worktree
	// is not associated with the checkout and keeps its own name. The synthetic
	// parity corpus pins the core.worktree path separately.
	if got := Name(worktree); got != "sep-wt" {
		t.Fatalf("Name(%q) = %q, want sep-wt", worktree, got)
	}
	if got := Name(worktree); strings.Contains(got, "sep-git-storage") {
		t.Fatalf("Name(%q) leaked the git storage directory: %q", worktree, got)
	}
}

func TestMokuseiTaskWorktreeUsesRepositoryTag(t *testing.T) {
	main := initRepository(t, filepath.Join(tempRoot(t), "Mokusei"))
	staging := filepath.Join(filepath.Dir(main), "."+filepath.Base(main)+"-mokusei-worktrees")
	worktree := addWorktree(t, main, filepath.Join(staging, "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"))
	if got := Name(worktree); got != "Mokusei" {
		t.Fatalf("Name(%q) = %q, want Mokusei", worktree, got)
	}
	nested := filepath.Join(worktree, "internal", "core", "runtime")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(nested); got != "Mokusei" {
		t.Fatalf("Name(%q) = %q, want Mokusei", nested, got)
	}
}

func TestPlainGitWorktreeUsesRepositoryTag(t *testing.T) {
	main := initRepository(t, filepath.Join(tempRoot(t), "PlainRepo"))
	worktree := addWorktree(t, main, filepath.Join(tempRoot(t), "plain-checkout"))
	if got := Name(worktree); got != "PlainRepo" {
		t.Fatalf("Name(%q) = %q, want PlainRepo", worktree, got)
	}
	subdirectory := filepath.Join(worktree, "src")
	if err := os.MkdirAll(subdirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(subdirectory); got != "PlainRepo" {
		t.Fatalf("Name(%q) = %q, want PlainRepo", subdirectory, got)
	}
}

func TestDifferentRepositoriesKeepDistinctTags(t *testing.T) {
	root := tempRoot(t)
	first := filepath.Join(root, "RepoA")
	second := filepath.Join(root, "RepoB")
	for _, path := range []string{first, second} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(path, ".git"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if got := Name(first); got != "RepoA" {
		t.Fatalf("Name(%q) = %q, want RepoA", first, got)
	}
	if got := Name(second); got != "RepoB" {
		t.Fatalf("Name(%q) = %q, want RepoB", second, got)
	}
}

// The resolver must not depend on a Git process being available for ordinary
// .git metadata. This fixture mimics what `git worktree add` writes.
func TestSyntheticLinkedWorktreeMetadata(t *testing.T) {
	main := filepath.Join(tempRoot(t), "SyntheticRepo")
	worktree := filepath.Join(tempRoot(t), "linked-checkout")
	gitdir := filepath.Join(main, ".git", "worktrees", "linked-checkout")
	for _, path := range []string{gitdir, worktree} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(gitdir, "commondir"), []byte("../..\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pointer := "gitdir: " + gitdir + "\n"
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte(pointer), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := Name(worktree); got != "SyntheticRepo" {
		t.Fatalf("Name(%q) = %q, want SyntheticRepo", worktree, got)
	}
}

func TestManagedConventionFallbackWithoutGitMetadata(t *testing.T) {
	root := tempRoot(t)
	staging := filepath.Join(root, ".FallbackRepo-mokusei-worktrees")
	worktree := filepath.Join(staging, "task-abcdef012345")
	if err := os.MkdirAll(worktree, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(worktree); got != "FallbackRepo" {
		t.Fatalf("Name(%q) = %q, want FallbackRepo", worktree, got)
	}
}

// Corrupt or partial worktree metadata under an ancestor repository must not
// leak the private generated task name just because the directory exists.
func TestCorruptManagedWorktreeInsideRepositoryUsesManagedTag(t *testing.T) {
	root := tempRoot(t)
	parent := filepath.Join(root, "workspace", "parent")
	worktree := filepath.Join(parent, ".Repo-mokusei-worktrees", "task-abcdef012345")
	for _, path := range []string{filepath.Join(parent, ".git"), worktree} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// A .git file without a usable commondir proves the path is not a genuine
	// linked worktree, but it is still below the ancestor repository.
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: missing\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := Name(worktree); got != "Repo" {
		t.Fatalf("Name(%q) = %q, want Repo", worktree, got)
	}
}

// Prefix-sharing repositories must not be guessed by stripping dashes. A
// worktree pointer that names foo wins over the lexically closer foo-bar.
func TestPrefixSharingSiblingRepositoriesUseWorktreeMetadata(t *testing.T) {
	root := tempRoot(t)
	foo := filepath.Join(root, "foo")
	fooBar := filepath.Join(root, "foo-bar")
	gitdir := filepath.Join(foo, ".git", "worktrees", "task-abcdef012345")
	worktree := filepath.Join(root, ".foo-bar-baz-mokusei-worktrees", "task-abcdef012345")
	for _, path := range []string{filepath.Join(fooBar, ".git"), gitdir, worktree} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: "+gitdir+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := Name(worktree); got != "foo" {
		t.Fatalf("Name(%q) = %q, want foo", worktree, got)
	}
}

// Without metadata there is no safe way to pick between foo and foo-bar, so
// the un-stripped staging slug is kept instead of attributing foo to foo-bar.
func TestPrefixSharingSiblingRepositoriesWithoutMetadataKeepSlug(t *testing.T) {
	root := tempRoot(t)
	for _, name := range []string{"foo", "foo-bar"} {
		if err := os.MkdirAll(filepath.Join(root, name, ".git"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	worktree := filepath.Join(root, ".foo-bar-baz-mokusei-worktrees", "task-abcdef012345")
	if err := os.MkdirAll(worktree, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(worktree); got != "foo-bar-baz" {
		t.Fatalf("Name(%q) = %q, want foo-bar-baz", worktree, got)
	}
}

// The memo is keyed by the cleaned path and never caches negative results.
func TestMemoUsesCleanedPathAndSkipsNegativeResults(t *testing.T) {
	root := tempRoot(t)
	directory := filepath.Join(root, "Repo")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	cleaned := normalizePath(directory)
	memo.Delete(cleaned)
	if got := Name(directory + "/"); got != "Repo" {
		t.Fatalf("Name(%q) = %q, want Repo", directory+"/", got)
	}
	if _, ok := memo.Load(cleaned); !ok {
		t.Fatalf("memo did not use the cleaned path key %q", cleaned)
	}
	missing := filepath.Join(root, "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb")
	if got := Name(missing); got != "" {
		t.Fatalf("Name(%q) = %q, want empty tag", missing, got)
	}
	if _, ok := memo.Load(normalizePath(missing)); ok {
		t.Fatal("memo cached a negative result for a missing path")
	}
	if err := os.MkdirAll(missing, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(missing); got != filepath.Base(missing) {
		t.Fatalf("Name(%q) = %q after creation, want %q", missing, got, filepath.Base(missing))
	}
}

func TestVanishedGeneratedTaskHasNoTag(t *testing.T) {
	missing := filepath.Join(tempRoot(t), "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb")
	if got := Name(missing); got != "" {
		t.Fatalf("Name(%q) = %q, want empty tag", missing, got)
	}
}

func TestExistingTaskNamedDirectoryKeepsTag(t *testing.T) {
	name := "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"
	directory := filepath.Join(tempRoot(t), name)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Name(directory); got != name {
		t.Fatalf("Name(%q) = %q, want %q", directory, got, name)
	}
}

// A permission error is not proof that the directory vanished, so a live
// generated task name must keep its label.
func TestUnreadableGeneratedTaskKeepsTag(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses filesystem permissions")
	}
	name := "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"
	parent := filepath.Join(tempRoot(t), "locked")
	directory := filepath.Join(parent, name)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, 0); err != nil {
		t.Skipf("cannot make a directory unreadable: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(parent, 0o700) })
	if got := Name(directory); got != name {
		t.Fatalf("Name(%q) = %q, want %q", directory, got, name)
	}
}

func TestTemporaryWorkspaceHasNoTag(t *testing.T) {
	path := "/tmp/mokusei-directorytag/nested"
	if got := Name(path); got != "" {
		t.Fatalf("Name(%q) = %q, want empty tag", path, got)
	}
}

// tempRoot avoids the harness TMPDIR, whose path can itself match the
// temporary-workspace patterns under test.
func tempRoot(t *testing.T) string {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "directorytag-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	return root
}

func requireGit(t *testing.T) string {
	t.Helper()
	gitPath, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	return gitPath
}

func initRepository(t *testing.T, root string) string {
	t.Helper()
	gitPath := requireGit(t)
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(t, gitPath, root, "init", "-q")
	runGit(t, gitPath, root, "config", "user.email", "test@example.com")
	runGit(t, gitPath, root, "config", "user.name", "Mokusei Test")
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, gitPath, root, "add", "README.md")
	runGit(t, gitPath, root, "commit", "-qm", "fixture")
	return root
}

func addWorktree(t *testing.T, main, path string) string {
	t.Helper()
	gitPath := requireGit(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(t, gitPath, main, "worktree", "add", "--detach", path)
	return path
}

func runGit(t *testing.T, gitPath, directory string, args ...string) {
	t.Helper()
	command := exec.Command(gitPath, append([]string{"-C", directory}, args...)...)
	command.Env = append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, output)
	}
}

func TestScopeKeepsOrdinaryDirectoryAndSubdirectory(t *testing.T) {
	root := tempRoot(t)
	repository := filepath.Join(root, "Repo")
	if err := os.MkdirAll(filepath.Join(repository, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	subdirectory := filepath.Join(repository, "app")
	if err := os.MkdirAll(subdirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if got, want := Scope(repository), canonicalTestPath(t, repository); got != want {
		t.Fatalf("Scope(%q) = %q, want %q", repository, got, want)
	}
	if got, want := Scope(subdirectory), canonicalTestPath(t, subdirectory); got != want {
		t.Fatalf("Scope(%q) = %q, want %q", subdirectory, got, want)
	}
}

func TestScopeFoldsLinkedWorktreeOntoRepositoryRoot(t *testing.T) {
	root := tempRoot(t)
	main := initRepository(t, filepath.Join(root, "Mokusei"))
	worktree := addWorktree(t, main, filepath.Join(root, ".Mokusei-mokusei-worktrees", "task-fd71335e-bfa"))
	if got, want := Scope(worktree), canonicalTestPath(t, main); got != want {
		t.Fatalf("Scope(%q) = %q, want repo root %q", worktree, got, want)
	}
	nested := filepath.Join(worktree, "internal", "core", "runtime")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}
	if got, want := Scope(nested), canonicalTestPath(t, main); got != want {
		t.Fatalf("Scope(%q) = %q, want repo root %q", nested, got, want)
	}
}

func TestScopeUsesInboxForTemporaryWorkspaces(t *testing.T) {
	if got := Scope(""); got != InboxScope {
		t.Fatalf("Scope(empty) = %q, want %q", got, InboxScope)
	}
	if got := Scope("/tmp/mokusei-directorytag/nested"); got != InboxScope {
		t.Fatalf("Scope(temporary) = %q, want %q", got, InboxScope)
	}
}

func TestScopeDistinguishesSameBasename(t *testing.T) {
	root := tempRoot(t)
	first := filepath.Join(root, "one", "Mokusei")
	second := filepath.Join(root, "two", "Mokusei")
	for _, path := range []string{first, second} {
		if err := os.MkdirAll(filepath.Join(path, ".git"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if Scope(first) == Scope(second) {
		t.Fatalf("same-basename directories shared scope %q", Scope(first))
	}
}

func canonicalTestPath(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return filepath.ToSlash(filepath.Clean(resolved))
}
