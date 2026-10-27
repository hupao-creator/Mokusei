// This replay uses actual SQLite files, an abruptly killed writer and a local
// committed Git repository. It never opens user repositories or model accounts.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func main() {
	if filepath.Base(os.Args[0]) == "git" && os.Getenv("MOKUSEI_RECOVERY_GIT_GATE") != "" {
		recoveryGitFixture()
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "crash-writer" {
		db, err := store.Open(os.Args[2])
		must(err)
		_, err = db.Update(context.Background(), func(tx *store.Tx) error { return tx.Put("committed", true) })
		must(err)
		must(db.Close())
		native, err := sqlite.Open(os.Args[2], false)
		must(err)
		must(native.Exec("BEGIN IMMEDIATE"))
		must(native.Exec("INSERT INTO records(key,body) VALUES (?,?)", "uncommitted", []byte(`true`)))
		fmt.Println("uncommitted-write-ready")
		for {
			time.Sleep(time.Hour)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	root, err := os.MkdirTemp("", "mokusei-storage-workspaces-")
	must(err)
	defer os.RemoveAll(root)
	root, err = filepath.EvalSymlinks(root)
	must(err)
	path := filepath.Join(root, "state.sqlite")
	db, err := store.Open(path)
	must(err)
	_, err = store.Open(path)
	check(errors.Is(err, store.ErrLocked), "second writer admitted")
	before := db.Snapshot()
	var escaped *store.Tx
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		escaped = tx
		must(tx.Put("rolled-back", true))
		return errors.New("fixture rollback")
	})
	check(err != nil && !db.Snapshot().Has("rolled-back") && db.Snapshot().Revision() == before.Revision(), "failed transaction published")
	check(escaped.Put("late", true) != nil, "expired transaction accepted writes")
	var wg sync.WaitGroup
	failures := make(chan error, 32)
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := db.Update(ctx, func(tx *store.Tx) error {
				var count int
				if _, err := tx.Get("counter", &count); err != nil {
					return err
				}
				return tx.Put("counter", count+1)
			})
			failures <- err
		}()
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		must(err)
	}
	var count int
	_, err = db.Snapshot().Get("counter", &count)
	must(err)
	check(count == 32 && !before.Has("counter"), "ordered writer or immutable old snapshot")
	value, _ := db.Snapshot().Raw("counter")
	value[0] = '9'
	_, err = db.Snapshot().Get("counter", &count)
	must(err)
	check(count == 32, "snapshot bytes aliased")
	native, err := sqlite.Open(path, false)
	must(err)
	must(native.Exec("CREATE TRIGGER fixture_abort BEFORE INSERT ON records WHEN NEW.key='fault' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
	revision := db.Snapshot().Revision()
	_, err = db.Update(ctx, func(tx *store.Tx) error { must(tx.Put("earlier-key", true)); return tx.Put("fault", true) })
	check(err != nil && !db.Snapshot().Has("earlier-key") && !db.Snapshot().Has("fault") && db.Snapshot().Revision() == revision, "SQLite write failure partially published")
	must(native.Exec("DROP TRIGGER fixture_abort"))
	must(native.Close())
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("after-fault", true) })
	must(err)
	must(db.Close())
	db, err = store.Open(path)
	must(err)
	_, err = db.Snapshot().Get("counter", &count)
	must(err)
	check(count == 32 && db.Snapshot().Has("after-fault"), "durable reopen")
	must(db.Close())
	self, err := os.Executable()
	must(err)
	crashPath := filepath.Join(root, "crash.sqlite")
	child := exec.CommandContext(ctx, self, "crash-writer", crashPath)
	pipe, err := child.StdoutPipe()
	must(err)
	child.Stderr = os.Stderr
	must(child.Start())
	scanner := bufio.NewScanner(pipe)
	check(scanner.Scan() && scanner.Text() == "uncommitted-write-ready", "crash barrier missing")
	must(child.Process.Kill())
	check(child.Wait() != nil, "fixture writer was not killed")
	db, err = store.Open(crashPath)
	must(err)
	check(db.Snapshot().Has("committed") && !db.Snapshot().Has("uncommitted"), "WAL recovery lost committed or kept uncommitted write")
	must(db.Close())
	replayLifecycleValidation(ctx, root)
	gitRoot := filepath.Join(root, "project")
	must(os.Mkdir(gitRoot, 0700))
	git := func(cwd string, args ...string) string {
		command := exec.CommandContext(ctx, "/usr/bin/git", args...)
		command.Dir = cwd
		output, err := command.CombinedOutput()
		if err != nil {
			panic(fmt.Sprintf("git fixture: %s: %v", output, err))
		}
		return string(output)
	}
	git(gitRoot, "init", "-b", "main")
	must(os.WriteFile(filepath.Join(gitRoot, "source.txt"), []byte("retained source\n"), 0600))
	git(gitRoot, "add", "source.txt")
	git(gitRoot, "-c", "user.name=Mokusei Fixture", "-c", "user.email=fixture@invalid", "commit", "-m", "fixture")
	paths := workspaces.Paths{DefaultCwd: gitRoot, MokuCwd: filepath.Join(root, "moku"), TemporaryRoot: filepath.Join(root, "temporary"), RegistryPath: filepath.Join(root, "owners.json")}
	must(os.Mkdir(paths.TemporaryRoot, 0700))
	manager := workspaces.New(paths)
	must(os.Mkdir(paths.MokuCwd, 0700))
	mokuThread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "moku", Cwd: paths.MokuCwd}, Moku: true}
	must(manager.ValidateThread(ctx, mokuThread))
	_, err = manager.AdmitThread(ctx, mokuThread)
	must(err)
	observed, err := manager.Observe(ctx, mokuThread, nil)
	must(err)
	manager.ReleaseObservation(observed)
	ordinary := mokuThread
	ordinary.Moku = false
	check(manager.ValidateThread(ctx, ordinary) != nil, "ordinary thread admitted to Moku workspace")
	forgedMoku := mokuThread
	forgedMoku.Cwd = gitRoot
	check(manager.ValidateThread(ctx, forgedMoku) != nil, "Moku admitted outside its dedicated workspace")
	forgedMoku = mokuThread
	forgedMoku.Worktree = &model.Worktree{}
	check(manager.ValidateThread(ctx, forgedMoku) != nil, "Moku admitted with a managed worktree")
	fmt.Println("PASS dedicated Moku workspace validation/admission/observation; ordinary, foreign-path and managed-worktree rejection")
	check(len(manager.RehydrateOwners(ctx, nil)) == 0, "initial ownership load")
	enabled := true
	prepared, err := manager.PrepareForStart(ctx, gitRoot, "thread-owner", &model.WorktreeOptions{Enabled: &enabled, Name: "replay"}, nil)
	must(err)
	check(prepared.Created && prepared.Worktree.Cwd != gitRoot, "managed checkout not created")
	request := workspaces.AuthorizationRequest{OwnerThreadID: "thread-owner", BaseCwd: gitRoot, Worktree: prepared.Worktree}
	validation, err := manager.Admit(ctx, request)
	must(err)
	grant, err := manager.AuthorizeWrite(ctx, request)
	must(err)
	check(grant.Cwd == prepared.Worktree.Cwd && grant.HeadOID == validation.HeadOID && len(grant.WritableRoots) > 0, "worktree write grant")
	forged := request
	forged.OwnerThreadID = "another-thread"
	_, err = manager.AuthorizeWrite(ctx, forged)
	check(err != nil, "foreign owner authorized")
	forged = request
	forged.ExpectedHeadOID = "0000000000000000000000000000000000000000"
	_, err = manager.AuthorizeWrite(ctx, forged)
	check(err != nil, "stale HEAD authorized")
	restoredManager := workspaces.New(paths)
	check(len(restoredManager.RehydrateOwners(ctx, []workspaces.PersistedOwner{{OwnerThreadID: "thread-owner", BaseCwd: gitRoot, Worktree: prepared.Worktree}})) == 0, "managed owner recovery")
	_, err = restoredManager.AuthorizeWrite(ctx, request)
	must(err)
	check(restoredManager.Discard(ctx, prepared) != nil, "registered checkout deletion must report retained residual")
	_, err = os.Stat(prepared.Worktree.Cwd)
	must(err)
	_, err = restoredManager.AuthorizeWrite(ctx, request)
	must(err)
	must(restoredManager.Unregister(ctx, "thread-owner", &prepared.Worktree))
	_, err = restoredManager.AuthorizeWrite(ctx, request)
	check(err != nil, "unregistered worktree retained write authority")
	source, err := os.ReadFile(filepath.Join(gitRoot, "source.txt"))
	must(err)
	check(string(source) == "retained source\n", "base checkout changed")
	temporary, err := manager.CreateTemporary(ctx)
	must(err)
	must(os.WriteFile(filepath.Join(temporary, "user-file"), []byte("retain"), 0600))
	check(manager.DiscardTemporary(ctx, temporary) != nil, "temporary rollback deleted nonempty directory")
	must(os.Remove(filepath.Join(temporary, "user-file")))
	must(manager.DiscardTemporary(ctx, temporary))
	replayParallelRecovery(ctx, root, gitRoot)
	raw, _ := json.Marshal(map[string]any{"storage": "PASS ordered writer, immutable snapshots, writer lock, rollback, actual SQLite abort, reopen and killed-writer WAL recovery", "workspaces": "PASS actual local Git checkout, owner/HEAD fences, write grant, registry recovery, registered checkout retention, authority revocation and nonempty temporary protection"})
	fmt.Println(string(raw))
}
