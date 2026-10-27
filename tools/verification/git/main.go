// Git integration replay. Every repository write is confined to MkdirTemp.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/platform/applicationprocess"
	"github.com/hupao-creator/Mokusei/internal/platform/environment"
	gitapp "github.com/hupao-creator/Mokusei/internal/plugins/applications/git"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func encode(v any) json.RawMessage { raw, err := json.Marshal(v); must(err); return raw }
func git(root string, args ...string) string {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		panic(fmt.Sprintf("fixture git %v: %s: %v", args, out, err))
	}
	return string(out)
}
func write(root, path, text string) {
	must(os.WriteFile(filepath.Join(root, path), []byte(text), 0600))
}

type capture struct {
	plugin.Application
	domain *plugin.DomainClient
}
type registry struct {
	plugin.Registry
	domain *plugin.DomainClient
}

func (c capture) Register(r plugin.Registry) error {
	return c.Application.Register(registry{r, c.domain})
}
func (r registry) BackgroundAgent(d plugin.BackgroundAgentDefinition) error {
	create := d.Create
	d.Create = func(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
		*r.domain = ctx.Domain
		return create(ctx)
	}
	return r.Registry.BackgroundAgent(d)
}

type faultProcess struct {
	base plugin.ApplicationProcessCapability
	mode *atomic.Value
}

func (p faultProcess) Run(ctx context.Context, input plugin.ApplicationProcessInput) (plugin.ApplicationProcessResult, error) {
	if mode := p.mode.Load().(string); mode != "" {
		if mode == "stats-timeout" {
			for _, arg := range input.Args {
				if arg == "--numstat" {
					// Exercise the real capability's parent-deadline cancellation
					// result after exhausting the monitor's shared stats budget.
					<-ctx.Done()
					return p.base.Run(ctx, input)
				}
			}
			return p.base.Run(ctx, input)
		}
		return plugin.ApplicationProcessResult{}, &plugin.ApplicationProcessError{Code: mode, Message: "injected " + mode}
	}
	return p.base.Run(ctx, input)
}
func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 240*time.Second)
	defer cancel()
	temp, err := os.MkdirTemp("", "native-git-fixture-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	// Canonicalize /var on macOS before checking worktree identity.
	temp, err = filepath.EvalSymlinks(temp)
	if err != nil {
		return err
	}
	root := filepath.Join(temp, "repository with spaces")
	must(os.MkdirAll(root, 0700))
	git(root, "init", "-b", "main")
	git(root, "config", "user.name", "Fixture")
	git(root, "config", "user.email", "fixture@example.invalid")
	ignore, err := os.ReadFile(".gitignore")
	if err != nil {
		return err
	}
	write(root, ".gitignore", string(ignore))
	must(os.MkdirAll(filepath.Join(root, ".scratch"), 0700))
	write(root, ".scratch/tracked.txt", "tracked scratch\n")
	git(root, "add", "--force", ".scratch/tracked.txt")
	write(root, "code.swift", "let value = 1\n\nlet context = true\n")
	write(root, "delete.txt", "removed\n")
	write(root, "old name.txt", "rename\n")
	must(os.MkdirAll(filepath.Join(root, "space b"), 0700))
	write(root, "space b/mode.txt", "mode only\n")
	git(root, "add", "--all")
	git(root, "commit", "-m", "fixture baseline")
	baseline := strings.TrimSpace(git(root, "rev-parse", "HEAD"))
	write(root, "code.swift", "let value = 2\n\nlet context = true\n")
	git(root, "add", "--", "code.swift")
	write(root, "code.swift", "let value = 3\n\nlet context = true\n")
	// Terminal formatting preferences must not change the native wire format.
	git(root, "config", "diff.suppressBlankEmpty", "true")
	must(os.Chmod(filepath.Join(root, "space b/mode.txt"), 0700))
	escaped := "tab\tquote\"line\n中文.txt"
	write(root, escaped, "new without newline")
	write(root, ":(glob)*.txt", "literal\n")
	write(root, "binary.bin", "\x00\x01\xff")
	write(temp, "outside.txt", "outside content must not be followed\n")
	must(os.Symlink(filepath.Join(temp, "outside.txt"), filepath.Join(root, "outside-link")))
	alias := filepath.Join(temp, "directory-alias")
	must(os.Symlink(filepath.Join(root, "space b"), alias))
	must(os.Remove(filepath.Join(root, "delete.txt")))
	git(root, "mv", "old name.txt", "renamed file.txt")
	linked := filepath.Join(temp, "linked\nworktree")
	git(root, "worktree", "add", "-b", "linked", linked)
	write(linked, "linked.txt", "linked\n")
	write(linked, ".scratch/tracked.txt", "edited tracked scratch\n")
	must(os.MkdirAll(filepath.Join(linked, ".scratch/note/go-cache"), 0700))
	for i := 0; i < 3172; i++ {
		write(linked, fmt.Sprintf(".scratch/note/go-cache/%04d-d", i), "generated cache\n")
	}
	resolver := environment.New(environment.Current())
	defer resolver.Close()
	processes := applicationprocess.New(ctx, resolver)
	defer processes.Close(context.Background())
	var mode atomic.Value
	mode.Store("")
	st, err := store.Open(filepath.Join(temp, "state.sqlite"))
	if err != nil {
		return err
	}
	defer st.Close()
	runtime, err := core.New(ctx, core.Config{Store: st, Harnesses: map[string]plugin.Harness{}, DataDir: temp, DefaultCwd: temp, Log: func(event string, err error) { fmt.Fprintln(os.Stderr, event, err) }, ProcessFactory: func(cwd string) plugin.ApplicationProcessCapability {
		return faultProcess{processes.ForCwd(cwd), &mode}
	}})
	if err != nil {
		return err
	}
	defer runtime.Close(context.Background())
	_, err = st.Update(ctx, func(tx *store.Tx) error {
		return tx.Put("thread:git-source", model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "git-source", Cwd: root, Settings: encode(map[string]any{}), SessionState: encode(nil)}, Archived: func() *bool { v := true; return &v }()})
	})
	if err != nil {
		return err
	}
	_, err = st.Update(ctx, func(tx *store.Tx) error {
		return tx.Put("thread:git-alias", model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "git-alias", Cwd: alias, Settings: encode(map[string]any{}), SessionState: encode(nil)}})
	})
	if err != nil {
		return err
	}
	var domain plugin.DomainClient
	host, err := applicationhost.New(ctx, applicationhost.Config{Store: st, Applications: []plugin.Application{capture{gitapp.New(), &domain}}, PluginEnabled: map[string]bool{"extension:git": false}, RuntimeCapabilities: runtime.RuntimeCapabilities, BackgroundCapabilities: runtime.BackgroundCapabilities, SnapshotCapabilities: runtime.SnapshotCapabilities})
	if err != nil {
		return err
	}
	runtime.SetApplications(host)
	if err = host.Start(ctx, plugin.RuntimeStartContext{Reason: "verification"}); err != nil {
		return err
	}
	defer host.Stop(context.Background())
	catalog := func() []gitapp.Activity {
		raw, e := domain.Query(ctx, "git.list", encode(gitapp.PageInput{Limit: 1000}))
		must(e)
		var page gitapp.Page[gitapp.Activity]
		must(json.Unmarshal(raw, &page))
		return page.Items
	}
	rows, e := host.Catalog(ctx)
	must(e)
	if len(rows) != 0 {
		return errors.New("built-in Git contributed standalone threads")
	}
	fmt.Println("PASS built-in service ignores plugin toggle and contributes no threads")
	await := func(description string, check func() bool) error {
		deadline := time.Now().Add(18 * time.Second)
		for time.Now().Before(deadline) {
			if check() {
				fmt.Println("PASS", description)
				return nil
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(50 * time.Millisecond):
			}
		}
		return errors.New("timed out: " + description)
	}
	if err = await("monitor shares canonical worktree for symlink/subdirectory and excludes unreferenced linked worktree", func() bool { return len(catalog()) == 1 && len(catalog()[0].Directories) == 2 }); err != nil {
		return err
	}
	var entry gitapp.Activity
	for _, e := range catalog() {
		var v gitapp.View
		must(json.Unmarshal(encode(e.View), &v))
		if v.Snapshot.Root == root {
			entry = e
		}
	}
	if entry.ID == "" {
		return errors.New("root activity missing")
	}
	id := entry.ID
	if entry.Snapshot.Changed != 8 || entry.Snapshot.Additions == nil || entry.Snapshot.Deletions == nil || *entry.Snapshot.Additions != 4 || *entry.Snapshot.Deletions != 2 {
		return fmt.Errorf("unexpected initial net stats: %s", encode(entry.Snapshot))
	}
	fmt.Println("PASS exact HEAD-relative file/+line/-line totals with overlapping staged/unstaged edits, rename, binary, symlink and unusual paths")
	for _, kind := range []string{"partial", "error-with-counts", "unknown-error"} {
		invalid := entry.Snapshot
		switch kind {
		case "partial":
			invalid.Additions = nil
		case "error-with-counts":
			failure := "timeout"
			invalid.LineStatsError = &failure
		case "unknown-error":
			failure := "pending"
			invalid.Additions, invalid.Deletions, invalid.LineStatsError = nil, nil, &failure
		}
		attempted := entry.Sync.AttemptedAt + 1
		batch := gitapp.SyncInput{AttemptedAt: attempted, Observations: []gitapp.Observation{{Root: root, Directories: []string{root}, AttemptedAt: attempted, Snapshot: &invalid}}}
		if _, err := domain.Execute(ctx, "git.sync", encode(batch), plugin.DomainCommandOptions{RequestID: "invalid-" + kind}); err == nil {
			return fmt.Errorf("invalid line statistics accepted: %s", kind)
		}
	}
	fmt.Println("PASS statistics contract rejects partial totals, numeric failures and unknown error codes")
	query := func(id string, input any) (json.RawMessage, error) {
		result, e := runtime.Invoke(ctx, "application:query", []json.RawMessage{encode(plugin.OperationRequest{PluginID: "git", OperationID: id, Input: encode(input)})})
		if e != nil {
			return nil, e
		}
		raw, ok := result.(json.RawMessage)
		if !ok {
			return json.Marshal(result)
		}
		return raw, nil
	}
	filesRaw, err := query("git.files", gitapp.FilesInput{ActivityID: id})
	if err != nil {
		return err
	}
	var files gitapp.FilesResult
	must(json.Unmarshal(filesRaw, &files))
	indexBefore, err := os.ReadFile(filepath.Join(root, ".git", "index"))
	if err != nil {
		return err
	}
	checks := map[string]bool{}
	patches := []json.RawMessage{}
	for _, f := range files.Files {
		raw, e := query("git.diff", gitapp.Selection{ActivityID: id, Path: f.Path, Scope: f.Scope})
		if e != nil {
			return fmt.Errorf("diff %q/%s: %w", f.Path, f.Scope, e)
		}
		var d gitapp.DiffContent
		must(json.Unmarshal(raw, &d))
		patches = append(patches, raw)
		switch {
		case f.Path == "code.swift" && f.Scope == "staged":
			checks["staged"] = strings.Contains(d.Patch, "+let value = 2") && !strings.Contains(d.Patch, "+let value = 3")
		case f.Path == "code.swift" && f.Scope == "unstaged":
			checks["unstaged"] = strings.Contains(d.Patch, "-let value = 2") && strings.Contains(d.Patch, "+let value = 3")
			checks["stable blank context format"] = strings.Contains(d.Patch, "\n \n let context = true")
		case f.Path == escaped:
			checks["escaped filename/no newline"] = strings.Contains(d.Patch, "\\ No newline at end of file")
		case f.Path == ":(glob)*.txt":
			checks["literal pathspec"] = strings.Contains(d.Patch, "+literal")
		case f.Path == "binary.bin":
			checks["binary"] = d.Notice != nil && *d.Notice == "binary"
		case f.Path == "delete.txt":
			checks["deleted"] = strings.Contains(d.Patch, "deleted file mode")
		case f.Path == "renamed file.txt":
			checks["renamed"] = strings.Contains(d.Patch, "rename from") && f.OldPath != nil
		case f.Path == "space b/mode.txt":
			checks["mode-only ambiguous path"] = strings.Contains(d.Patch, "old mode 100644\nnew mode 100755")
		case f.Path == "outside-link":
			checks["symlink target is not followed"] = strings.Contains(d.Patch, "new file mode 120000") && !strings.Contains(d.Patch, "outside content must not be followed")
		}
	}
	for _, name := range []string{"staged", "unstaged", "stable blank context format", "escaped filename/no newline", "literal pathspec", "binary", "deleted", "renamed", "mode-only ambiguous path", "symlink target is not followed"} {
		if !checks[name] {
			return fmt.Errorf("missing diff case: %s", name)
		}
		fmt.Println("PASS", name)
	}
	page, err := query("git.list", gitapp.PageInput{Limit: 1000})
	if err != nil {
		return err
	}
	evidence := map[string]any{"view": entry.View, "repositories": page, "files": filesRaw, "diffs": patches}
	statsFailures := []gitapp.View{}
	indexAfter, err := os.ReadFile(filepath.Join(root, ".git", "index"))
	if err != nil {
		return err
	}
	if sha256.Sum256(indexBefore) != sha256.Sum256(indexAfter) {
		return errors.New("read-only queries rewrote index")
	}
	if _, err = query("git.diff", gitapp.Selection{ActivityID: id, Path: "../outside", Scope: "unstaged"}); err == nil {
		return errors.New("arbitrary path accepted")
	}
	if _, err = host.Command(ctx, plugin.OperationRequest{PluginID: "git", OperationID: "git.sync", Input: encode(gitapp.SyncInput{Observations: []gitapp.Observation{}}), RequestID: "untrusted"}); err == nil {
		return errors.New("user sync accepted")
	}
	badCtx, abort := context.WithCancel(ctx)
	abort()
	if _, err = host.Query(badCtx, plugin.OperationRequest{PluginID: "git", OperationID: "git.files", Input: encode(gitapp.FilesInput{ActivityID: id})}); err == nil {
		return errors.New("cancelled query accepted")
	}
	fmt.Println("PASS read-only index, path authorization, audience and cancellation")
	write(root, "large.txt", strings.Repeat("large line\n", 220000))
	raw, err := query("git.diff", gitapp.Selection{ActivityID: id, Path: "large.txt", Scope: "untracked"})
	if err != nil {
		return err
	}
	var large gitapp.DiffContent
	must(json.Unmarshal(raw, &large))
	if large.Notice == nil || *large.Notice != "too-large" {
		return errors.New("large diff not bounded")
	}
	fmt.Println("PASS oversized patch")
	// Real unmerged index entries, produced only in the disposable fixture.
	git(root, "reset", "--hard", baseline)
	git(root, "clean", "-fd")
	git(root, "checkout", "-b", "conflict-other", baseline)
	write(root, "code.swift", "let value = 100\n")
	git(root, "add", "--all")
	git(root, "commit", "-m", "other")
	git(root, "checkout", "main")
	write(root, "code.swift", "let value = 200\n")
	git(root, "add", "--all")
	git(root, "commit", "-m", "ours")
	merge := exec.Command("git", "-C", root, "merge", "conflict-other")
	if e := merge.Run(); e == nil {
		return errors.New("fixture should conflict")
	}
	raw, err = query("git.files", gitapp.FilesInput{ActivityID: id})
	if err != nil {
		return err
	}
	var conflicted gitapp.FilesResult
	must(json.Unmarshal(raw, &conflicted))
	foundConflict := false
	for _, f := range conflicted.Files {
		if f.Path == "code.swift" && f.Scope == "conflicts" {
			foundConflict = true
		}
	}
	if !foundConflict {
		return errors.New("unmerged file not projected")
	}
	raw, err = query("git.diff", gitapp.Selection{ActivityID: id, Path: "code.swift", Scope: "conflicts"})
	if err != nil {
		return err
	}
	var conflict gitapp.DiffContent
	must(json.Unmarshal(raw, &conflict))
	if conflict.Notice == nil || *conflict.Notice != "conflict" {
		return errors.New("missing conflict notice")
	}
	fmt.Println("PASS real merge conflict")
	git(root, "reset", "--hard", baseline)
	write(root, "pending.txt", "pending\n")

	mode.Store("timeout")
	if err = await("transient timeout retains last active status and identity", func() bool {
		for _, a := range catalog() {
			if a.ID == id {
				return a.Sync.Error != nil && *a.Sync.Error == "timeout" && a.Snapshot.Changed > 0
			}
		}
		return false
	}); err != nil {
		return err
	}
	mode.Store("")
	git(root, "reset", "--hard", baseline)
	git(root, "clean", "-fd")
	if err = await("clean worktree keeps shared observation without independent lifecycle", func() bool {
		for _, a := range catalog() {
			if a.ID == id {
				return a.Sync.Error == nil && a.Snapshot.Changed == 0 && a.Snapshot.Additions != nil && *a.Snapshot.Additions == 0 && a.Snapshot.Deletions != nil && *a.Snapshot.Deletions == 0
			}
		}
		return false
	}); err != nil {
		return err
	}
	write(root, "restored.txt", "activity returns\n")
	if err = await("new activity updates same worktree identity", func() bool {
		for _, a := range catalog() {
			if a.ID == id {
				return a.Snapshot.Changed > 0
			}
		}
		return false
	}); err != nil {
		return err
	}
	git(root, "config", "remote.fixture.url", root)
	git(root, "config", "remote.fixture.fetch", "+refs/heads/*:refs/remotes/fixture/*")
	git(root, "update-ref", "refs/remotes/fixture/main", baseline)
	git(root, "branch", "--set-upstream-to=fixture/main", "main")
	git(root, "add", "--all")
	git(root, "commit", "-m", "ahead")
	if err = await("clean local ahead is reported without network", func() bool {
		for _, a := range catalog() {
			if a.ID == id {
				return a.Snapshot.Changed == 0 && a.Snapshot.Ahead != nil && *a.Snapshot.Ahead == 1
			}
		}
		return false
	}); err != nil {
		return err
	}
	git(root, "update-ref", "refs/remotes/fixture/main", strings.TrimSpace(git(root, "rev-parse", "HEAD")))
	if err = await("synchronized worktree clears divergence", func() bool {
		for _, a := range catalog() {
			if a.ID == id {
				return a.Snapshot.Ahead != nil && *a.Snapshot.Ahead == 0
			}
		}
		return false
	}); err != nil {
		return err
	}

	aheadCommit := strings.TrimSpace(git(root, "rev-parse", "HEAD"))
	git(root, "reset", "--hard", baseline)
	if err = await("clean local behind is reported without network", func() bool {
		for _, a := range catalog() {
			if a.ID == id {
				return a.Snapshot.Changed == 0 && a.Snapshot.Behind != nil && *a.Snapshot.Behind == 1
			}
		}
		return false
	}); err != nil {
		return err
	}
	git(root, "reset", "--hard", aheadCommit)
	git(root, "update-ref", "-d", "refs/remotes/fixture/main")
	if err = await("unknown upstream is recorded without inventing activity", func() bool {
		for _, a := range catalog() {
			if a.ID == id {
				return a.Snapshot.Changed == 0 && a.Snapshot.Upstream != nil && a.Snapshot.Ahead == nil
			}
		}
		return false
	}); err != nil {
		return err
	}
	var current gitapp.Activity
	for _, a := range catalog() {
		if a.ID == id {
			current = a
		}
	}
	stale := gitapp.SyncInput{AttemptedAt: current.Sync.AttemptedAt - 1, Observations: []gitapp.Observation{{Root: root, Directories: []string{}, AttemptedAt: current.Sync.AttemptedAt - 1}}}
	if _, err = domain.Execute(ctx, "git.sync", encode(stale), plugin.DomainCommandOptions{RequestID: "stale"}); err != nil {
		return err
	}
	for _, a := range catalog() {
		if a.ID == id && !a.Available {
			return errors.New("stale observation replaced current")
		}
	}
	fmt.Println("PASS stale observation fence")
	putThread := func(id, cwd string) {
		_, e := st.Update(ctx, func(tx *store.Tx) error {
			return tx.Put("thread:"+id, model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, Cwd: cwd, Settings: encode(map[string]any{}), SessionState: encode(nil)}})
		})
		must(e)
	}
	_, err = st.Update(ctx, func(tx *store.Tx) error {
		return tx.Put("thread:linked", model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "linked", Cwd: root,
			Worktree: &model.Worktree{Cwd: linked}, Settings: encode(map[string]any{}), SessionState: encode(nil)}})
	})
	if err != nil {
		return err
	}
	if err = await("managed worktree uses execution cwd rather than shared project cwd", func() bool {
		for _, a := range catalog() {
			if a.Snapshot.Root == linked {
				return a.ID != id && a.Snapshot.Changed == 2 && a.Snapshot.Additions != nil && *a.Snapshot.Additions == 2 && a.Snapshot.Deletions != nil && *a.Snapshot.Deletions == 1 && a.Snapshot.LineStatsError == nil && a.Snapshot.Branch != nil && *a.Snapshot.Branch == "linked" && len(a.Directories) == 1 && a.Directories[0] == linked
			}
		}
		return false
	}); err != nil {
		return err
	}
	fmt.Println("PASS linked .git file and 3172 ignored cache files do not inflate totals; tracked ignored paths still count")

	must(os.Rename(linked, linked+"-missing"))
	if err = await("confirmed missing worktree removes extension association", func() bool { return len(catalog()) == 1 }); err != nil {
		return err
	}
	must(os.Rename(linked+"-missing", linked))
	if err = await("restored referenced directory is observed again", func() bool { return len(catalog()) == 2 }); err != nil {
		return err
	}
	putThread("linked", root)
	_, err = st.Update(ctx, func(tx *store.Tx) error { return tx.Delete("thread:git-alias") })
	if err != nil {
		return err
	}
	if err = await("directory changes and deletion remove obsolete worktree and alias observation", func() bool {
		return len(catalog()) == 1 && len(catalog()[0].Directories) == 1 && catalog()[0].Directories[0] == root
	}); err != nil {
		return err
	}
	later := filepath.Join(temp, "later-repository")
	must(os.MkdirAll(later, 0700))
	putThread("later", later)
	git(later, "init", "-b", "newborn")
	write(later, "new.txt", "newborn\n")
	if err = await("current non-Git thread directory detects later git init", func() bool {
		for _, a := range catalog() {
			if a.Snapshot.Root == later {
				return a.Snapshot.Head == nil && a.Snapshot.Changed > 0 && a.Snapshot.Additions != nil && *a.Snapshot.Additions == 1 && a.Snapshot.Deletions != nil && *a.Snapshot.Deletions == 0
			}
		}
		return false
	}); err != nil {
		return err
	}
	_, err = st.Update(ctx, func(tx *store.Tx) error { return tx.Delete("thread:later") })
	if err != nil {
		return err
	}
	if err = await("deleted thread leaves no persistent scan seed", func() bool { return len(catalog()) == 1 }); err != nil {
		return err
	}
	module := filepath.Join(temp, "module-source")
	must(os.MkdirAll(module, 0700))
	git(module, "init", "-b", "main")
	git(module, "config", "user.name", "Fixture")
	git(module, "config", "user.email", "fixture@example.invalid")
	write(module, "module.txt", "module\n")
	git(module, "add", "--all")
	git(module, "commit", "-m", "module")
	git(root, "-c", "protocol.file.allow=always", "submodule", "add", module, "nested-module")
	git(root, "config", "diff.ignoreSubmodules", "all")
	write(filepath.Join(root, "nested-module"), "module.txt", "dirty module\n")
	raw, err = query("git.files", gitapp.FilesInput{ActivityID: id})
	if err != nil {
		return err
	}
	var moduleFiles gitapp.FilesResult
	must(json.Unmarshal(raw, &moduleFiles))
	foundModule := false
	for _, f := range moduleFiles.Files {
		if f.Path == "nested-module" && f.Submodule {
			foundModule = true
			raw, e := query("git.diff", gitapp.Selection{ActivityID: id, Path: f.Path, Scope: f.Scope})
			if e != nil {
				return e
			}
			var d gitapp.DiffContent
			must(json.Unmarshal(raw, &d))
			if f.Scope == "staged" && !strings.Contains(d.Patch, "Subproject commit") {
				return errors.New("user diff.ignoreSubmodules hid staged submodule patch")
			}
		}
	}
	if !foundModule {
		return errors.New("submodule changes not projected")
	}
	fmt.Println("PASS real submodule staged and dirty changes")
	// Validate against fresh canonical Git identity, not just the stored path.
	must(os.Rename(filepath.Join(root, ".git"), filepath.Join(root, ".git-hidden")))
	git(temp, "init", "-b", "parent")
	if _, e := query("git.files", gitapp.FilesInput{ActivityID: id}); e == nil {
		return errors.New("old root read parent repository")
	}
	must(os.RemoveAll(filepath.Join(temp, ".git")))
	must(os.Rename(filepath.Join(root, ".git-hidden"), filepath.Join(root, ".git")))
	fmt.Println("PASS canonical root replacement cannot read parent repository")

	statsRoot := filepath.Join(temp, "stats-boundaries")
	must(os.MkdirAll(statsRoot, 0700))
	git(statsRoot, "init", "-b", "main")
	git(statsRoot, "config", "user.name", "Fixture")
	git(statsRoot, "config", "user.email", "fixture@example.invalid")
	write(statsRoot, "same.txt", "same\n")
	git(statsRoot, "add", "--all")
	git(statsRoot, "commit", "-m", "baseline")
	write(statsRoot, "forced-binary.txt", "binary attribute\n")
	write(statsRoot, ".gitattributes", "forced-binary.txt -diff\nforced-text.bin diff\n")
	write(statsRoot, "forced-text.bin", "a\x00b\n")
	putThread("stats-boundaries", statsRoot)
	if err = await("numstat respects forced binary/text attributes", func() bool {
		for _, a := range catalog() {
			if a.Snapshot.Root == statsRoot {
				return a.Snapshot.Additions != nil && *a.Snapshot.Additions == 3 && a.Snapshot.Deletions != nil && *a.Snapshot.Deletions == 0
			}
		}
		return false
	}); err != nil {
		return err
	}
	git(statsRoot, "rm", "--cached", "same.txt")
	if err = await("recreated untracked path counts as one file without fabricated net totals", func() bool {
		for _, a := range catalog() {
			if a.Snapshot.Root == statsRoot {
				return a.Snapshot.Changed == 4 && a.Snapshot.Additions == nil && a.Snapshot.Deletions == nil && a.Snapshot.LineStatsError != nil && *a.Snapshot.LineStatsError == "inaccessible"
			}
		}
		return false
	}); err != nil {
		return err
	}
	for _, a := range catalog() {
		if a.Snapshot.Root == statsRoot {
			statsFailures = append(statsFailures, a.View)
		}
	}
	git(statsRoot, "add", "same.txt")
	mode.Store("stats-timeout")
	if err = await("line-stat deadline preserves fresh file counts and reports timeout, not pending or zero", func() bool {
		for _, a := range catalog() {
			if a.Snapshot.Root == statsRoot {
				return a.Sync.Error == nil && a.Snapshot.Changed == 3 && a.Snapshot.Additions == nil && a.Snapshot.Deletions == nil && a.Snapshot.LineStatsError != nil && *a.Snapshot.LineStatsError == "timeout"
			}
		}
		return false
	}); err != nil {
		return err
	}
	for _, a := range catalog() {
		if a.Snapshot.Root == statsRoot {
			statsFailures = append(statsFailures, a.View)
		}
	}
	mode.Store("")
	if err = await("line statistics recover on the same file set without retaining failure or partial totals", func() bool {
		for _, a := range catalog() {
			if a.Snapshot.Root == statsRoot {
				return a.Snapshot.Changed == 3 && a.Snapshot.LineStatsError == nil && a.Snapshot.Additions != nil && *a.Snapshot.Additions == 3 && a.Snapshot.Deletions != nil && *a.Snapshot.Deletions == 0
			}
		}
		return false
	}); err != nil {
		return err
	}
	must(os.MkdirAll(filepath.Join(statsRoot, "many"), 0700))
	for i := 0; i < 257; i++ {
		write(statsRoot, fmt.Sprintf("many/%03d.txt", i), "line\n")
	}
	if err = await("line-stat budget keeps fresh file counts with unavailable line totals", func() bool {
		for _, a := range catalog() {
			if a.Snapshot.Root == statsRoot {
				return a.Snapshot.Changed == 260 && a.Snapshot.Additions == nil && a.Snapshot.Deletions == nil && a.Snapshot.LineStatsError != nil && *a.Snapshot.LineStatsError == "too-large"
			}
		}
		return false
	}); err != nil {
		return err
	}
	for _, a := range catalog() {
		if a.Snapshot.Root == statsRoot {
			statsFailures = append(statsFailures, a.View)
		}
	}
	evidence["lineStatsFailures"] = statsFailures
	// Seed the persisted fence ahead of the wall clock before stopping the
	// participant. Restart must inherit it without accepting genuinely late work.
	beforeRestart := catalog()
	futureAttempt := time.Now().Add(time.Hour).UnixMilli()
	beforeRestartChanged := -1
	for _, activity := range beforeRestart {
		futureAttempt = max(futureAttempt, activity.Sync.AttemptedAt+1)
		if activity.ID == id {
			beforeRestartChanged = activity.Snapshot.Changed
		}
	}
	if beforeRestartChanged < 0 {
		return errors.New("root activity missing before participant restart")
	}
	future := gitapp.SyncInput{AttemptedAt: futureAttempt, Observations: []gitapp.Observation{}}
	for _, activity := range beforeRestart {
		snapshot := activity.Snapshot
		future.Observations = append(future.Observations, gitapp.Observation{Root: snapshot.Root, Directories: activity.Directories, AttemptedAt: futureAttempt, Snapshot: &snapshot})
	}
	if _, err = domain.Execute(ctx, "git.sync", encode(future), plugin.DomainCommandOptions{RequestID: "future-before-restart"}); err != nil {
		return err
	}
	if err = host.Stop(ctx); err != nil {
		return err
	}
	write(root, "after-clock-rollback.txt", "fresh work after clock rollback\n")
	_, err = st.Update(ctx, func(tx *store.Tx) error { return tx.Delete("thread:stats-boundaries") })
	if err != nil {
		return err
	}
	if err = host.Start(ctx, plugin.RuntimeStartContext{Reason: "restart"}); err != nil {
		return err
	}
	if err = await("participant restart advances future persisted fence, refreshes changes and removes deleted task while preserving identity", func() bool {
		activities := catalog()
		return len(activities) == 1 && activities[0].ID == id && activities[0].Available && activities[0].Sync.Error == nil && activities[0].Sync.ObservedAt > futureAttempt && activities[0].Snapshot.Changed == beforeRestartChanged+1
	}); err != nil {
		return err
	}
	late := gitapp.SyncInput{AttemptedAt: futureAttempt, Observations: []gitapp.Observation{}}
	if _, err = domain.Execute(ctx, "git.sync", encode(late), plugin.DomainCommandOptions{RequestID: "late-after-restart"}); err != nil {
		return err
	}
	afterLate := catalog()
	if len(afterLate) != 1 || afterLate[0].ID != id || afterLate[0].Sync.ObservedAt <= futureAttempt || afterLate[0].Snapshot.Changed != beforeRestartChanged+1 {
		return errors.New("late empty reconciliation erased fresh state after participant restart")
	}
	fmt.Println("PASS late reconciliation cannot erase fresh observations after clock rollback recovery")
	if err = host.Stop(ctx); err != nil {
		return err
	}
	if err = runtime.Close(ctx); err != nil {
		return err
	}
	if err = st.Close(); err != nil {
		return err
	}
	reopened, e := store.Open(filepath.Join(temp, "state.sqlite"))
	if e != nil {
		return e
	}
	defer reopened.Close()
	restoredHost, e := applicationhost.New(ctx, applicationhost.Config{Store: reopened, Applications: []plugin.Application{gitapp.New()}})
	if e != nil {
		return e
	}
	restoredRaw, e := restoredHost.Query(ctx, plugin.OperationRequest{PluginID: "git", OperationID: "git.list", Input: encode(gitapp.PageInput{Limit: 1000})})
	if e != nil {
		return e
	}
	var restored gitapp.Page[gitapp.Activity]
	must(json.Unmarshal(encode(restoredRaw), &restored))
	retained := false
	for _, entry := range restored.Items {
		if entry.ID == id {
			retained = true
		}
	}
	if !retained {
		return errors.New("SQLite reopen lost activity identity")
	}
	if path := os.Getenv("MOKUSEI_GIT_CONTRACT_EVIDENCE"); path != "" {
		must(os.WriteFile(path, encode(evidence), 0600))
		fmt.Println("PASS runtime query contract evidence exported for native decoding")
	}
	fmt.Println("PASS real SQLite close/reopen retains activity identity")
	fmt.Println("Git integration replay passed; all fixture repositories removed")
	return nil
}
