package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/applicationprocess"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/environment"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type fixture struct{}

func (fixture) Initialize(context.Context) (transport.Host, error) {
	return fixture{}, nil
}
func (fixture) Close(context.Context) error {
	if os.Getenv("MOKUSEI_HELPER_FAIL_CLOSE") == "1" {
		if gate := os.Getenv("MOKUSEI_HELPER_CLOSE_GATE"); gate != "" {
			if err := os.WriteFile(gate+".started", nil, 0600); err != nil {
				return err
			}
			deadline := time.Now().Add(120 * time.Second)
			for {
				if _, err := os.Stat(gate + ".release"); err == nil {
					break
				}
				if time.Now().After(deadline) {
					return errors.New("close gate timed out")
				}
				time.Sleep(5 * time.Millisecond)
			}
		}
		return errors.New("fixture durable flush failure")
	}
	return nil
}
func (fixture) HasChannel(s string) bool { return s == "state:load" }
func (fixture) Invoke(context.Context, string, []json.RawMessage) (any, error) {
	return map[string]any{"fixture": true}, nil
}
func (fixture) SubscribeMutations(func(json.RawMessage)) func() { return func() {} }
func (fixture) ReadThreadContent(context.Context, string, transport.ContentScope, *int64) (*transport.ContentSnapshot, error) {
	return nil, nil
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func assert(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}
func main() {
	if len(os.Args) > 2 && os.Args[1] == "process-fixture" {
		switch os.Args[2] {
		case "nonzero":
			fmt.Fprint(os.Stdout, "result")
			fmt.Fprint(os.Stderr, "diagnostic")
			os.Exit(9)
		case "overflow":
			fmt.Fprint(os.Stdout, strings.Repeat("a", 700))
			fmt.Fprint(os.Stderr, strings.Repeat("b", 700))
		case "environment":
			fmt.Fprint(os.Stdout, os.Getenv("PROCESS_KEEP"), "/", os.Getenv("PROCESS_DELETE"))
		case "descendant":
			self, e := os.Executable()
			must(e)
			child := exec.Command(self, "process-fixture", "wait", os.Args[3])
			child.Stdout = os.Stdout
			child.Stderr = os.Stderr
			must(child.Start())
			deadline := time.Now().Add(5 * time.Second)
			for {
				if _, e := os.Stat(os.Args[3]); e == nil {
					break
				}
				assert(time.Now().Before(deadline), "child did not start")
				time.Sleep(5 * time.Millisecond)
			}
		case "wait":
			signal.Ignore(syscall.SIGTERM)
			must(os.WriteFile(os.Args[3], []byte(fmt.Sprint(os.Getpid())), 0600))
			for {
				time.Sleep(time.Hour)
			}
		default:
			panic("unknown process fixture")
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "-ilc" {
		f, e := os.OpenFile(os.Getenv("MOKUSEI_HELPER_COUNT"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		must(e)
		_, e = f.WriteString("load\n")
		must(e)
		must(f.Close())
		time.Sleep(80 * time.Millisecond)
		fmt.Printf("PATH=/usr/bin:/bin\x00MOKUSEI_FIXTURE_VALUE=loaded\x00")
		return
	}
	if len(os.Args) > 3 && os.Args[1] == "start" {
		p, err := profile.Resolve(profile.Options{DataDir: os.Args[3]})
		must(err)
		self, err := os.Executable()
		must(err)
		_, err = daemon.Ensure(context.Background(), p, daemon.LaunchOptions{Executable: self})
		must(err)
		return
	}
	if len(os.Args) > 3 && os.Args[1] == "serve" {
		must(daemon.AwaitLaunch())
		if gate := os.Getenv("MOKUSEI_HELPER_LAUNCH_GATE"); gate != "" {
			must(os.WriteFile(gate+".started", nil, 0600))
			deadline := time.Now().Add(10 * time.Second)
			for {
				if _, e := os.Stat(gate + ".release"); e == nil {
					break
				}
				assert(time.Now().Before(deadline), "launch gate timed out")
				time.Sleep(5 * time.Millisecond)
			}
		}
		p, e := profile.Resolve(profile.Options{DataDir: os.Args[3]})
		must(e)
		must(daemon.Serve(context.Background(), daemon.ServeOptions{Profile: p, Bootstrap: fixture{}, Output: os.Stdout,
			Log: func(err error) { fmt.Fprintln(os.Stderr, err) },
		}))
		return
	}
	must(verifyDescendantDrain())
	must(verifyZombieGroupDrain())
	ctx := context.Background()
	temp, e := os.MkdirTemp("", "mokusei-go-helper-")
	must(e)
	defer os.RemoveAll(temp)
	repo := attachments.New(filepath.Join(temp, "attachments"))
	for _, item := range []struct{ source, stored string }{
		{".env", "env"}, {".gitignore", "gitignore"}, {".config.json", "config.json"},
	} {
		path := filepath.Join(temp, item.source)
		must(os.WriteFile(path, []byte("safe dotfile fixture\n"), 0600))
		files, err := repo.Stage(ctx, []attachments.Import{{Source: "path", Path: path, DisplayName: item.source}})
		must(err)
		assert(len(files) == 1 && files[0].Name == item.stored && filepath.Base(files[0].Path) == item.stored,
			"dotfile import duplicated its extension")
		must(repo.Discard(ctx, []string{files[0].ID}))
	}
	data := []byte{0x89, 'P', 'N', 'G', 13, 10, 26, 10, 1, 2, 3, 4}
	envelope, _ := json.Marshal(map[string]string{"$mokuseiArrayBuffer": base64.StdEncoding.EncodeToString(data)})
	staged, e := repo.Stage(ctx, []attachments.Import{{Source: "bytes", DisplayName: "../proof.png", Bytes: envelope}})
	must(e)
	assert(len(staged) == 1, "stage length")
	a := staged[0]
	input := model.AgentInput{Parts: []model.AgentInputPart{{Kind: "image", File: &model.InputFile{ID: a.ID}}}}
	canonical, e := repo.RetainInput(ctx, "thread-one", input)
	must(e)
	resolvedPath, e := filepath.EvalSymlinks(a.Path)
	must(e)
	assert(canonical.Parts[0].File.Path == resolvedPath, "canonical reference")
	preview, e := repo.Preview(ctx, "thread-one", a.ID)
	must(e)
	assert(strings.HasSuffix(preview, base64.StdEncoding.EncodeToString(data)), "preview bytes")
	assert(repo.Discard(ctx, []string{strings.ToUpper(a.ID)}) != nil, "alternate case accepted")
	must(repo.Discard(ctx, []string{a.ID}))
	_, e = os.Stat(a.Path)
	must(e)
	must(repo.InheritOwners(ctx, "thread-one", "fork-one"))
	must(repo.ReleaseOwner(ctx, "thread-one"))
	must(repo.CollectOrphans(ctx, 0))
	_, e = os.Stat(a.Path)
	must(e)
	assert(repo.Discard(ctx, []string{"../"}) != nil, "path traversal accepted")
	replacement := bytes.Clone(data)
	replacement[len(replacement)-1] ^= 1
	must(os.WriteFile(a.Path, replacement, 0600))
	_, e = repo.Preview(ctx, "fork-one", a.ID)
	assert(e != nil, "tampered preview accepted")
	must(repo.ReleaseOwner(ctx, "fork-one"))
	must(repo.Discard(ctx, []string{a.ID}))
	_, e = os.Stat(a.Path)
	assert(os.IsNotExist(e), "unowned attachment retained")
	staged, e = repo.Stage(ctx, []attachments.Import{{Source: "bytes", DisplayName: "again", Bytes: envelope}})
	must(e)
	must(os.Remove(filepath.Join(temp, "attachments", ".owners.json")))
	assert(repo.CollectOrphans(ctx, 0) != nil, "missing owner authority allowed collection")
	_, e = os.Stat(staged[0].Path)
	must(e)
	executable, e := os.Executable()
	must(e)
	must(os.Setenv("SHELL", executable))
	count := filepath.Join(temp, "shell-count")
	must(os.Setenv("MOKUSEI_HELPER_COUNT", count))
	resolver := environment.New(nil)
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v, e := resolver.Environment(ctx)
			if e != nil {
				errs <- e
				return
			}
			if v["MOKUSEI_FIXTURE_VALUE"] != "loaded" {
				errs <- fmt.Errorf("bad shell snapshot")
			}
			v["MOKUSEI_FIXTURE_VALUE"] = "caller mutation"
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		must(e)
	}
	loads, e := os.ReadFile(count)
	must(e)
	assert(string(loads) == "load\n", "duplicate cold shell loads")
	v, e := resolver.Environment(ctx)
	must(e)
	assert(v["MOKUSEI_FIXTURE_VALUE"] == "loaded", "shared environment mutation")
	_, e = resolver.ResolveExecutable(ctx, "true", "/tmp", "")
	must(e)
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	_, e = resolver.ResolveExecutable(cancelled, "true", "/tmp", "")
	assert(e != nil, "cancelled cache returned success")
	must(resolver.Refresh(ctx))
	loads, e = os.ReadFile(count)
	must(e)
	assert(string(loads) == "load\nload\n", "refresh did not reacquire")
	must(resolver.Close())
	_, e = resolver.Environment(ctx)
	assert(e != nil, "closed resolver reused")
	processEnvironment := environment.New(map[string]string{"PATH": "/usr/bin:/bin", "PROCESS_DELETE": "remove", "GORACE": "halt_on_error=1 atexit_sleep_ms=0"})
	processes := applicationprocess.New(ctx, processEnvironment)
	process := processes.ForCwd(temp)
	run := func(mode string, timeout, limit int64) (plugin.ApplicationProcessResult, error) {
		return process.Run(ctx, plugin.ApplicationProcessInput{Command: executable, Args: []string{"process-fixture", mode, filepath.Join(temp, "child.pid")}, TimeoutMS: timeout, MaxOutputBytes: limit})
	}
	result, e := run("nonzero", 5000, 4096)
	must(e)
	assert(result.ExitCode == 9 && result.Stdout == "result" && result.Stderr == "diagnostic", "nonzero exit lost")
	code := func(e error, want string) {
		var public *plugin.ApplicationProcessError
		assert(errors.As(e, &public) && public.Code == want, "process error contract "+want+": "+fmt.Sprint(e))
	}
	_, e = run("overflow", 5000, 1024)
	code(e, "output-limit")
	_, e = process.Run(ctx, plugin.ApplicationProcessInput{Command: "missing-mokusei-process-fixture"})
	code(e, "not-found")
	kept := "kept"
	result, e = process.Run(ctx, plugin.ApplicationProcessInput{Command: executable, Args: []string{"process-fixture", "environment"}, Env: map[string]*string{"PROCESS_KEEP": &kept, "PROCESS_DELETE": nil}})
	must(e)
	assert(result.Stdout == "kept/", "process environment overrides")
	_, e = run("descendant", 5000, 4096)
	must(e)
	_, e = run("wait", 100, 4096)
	code(e, "timeout")
	_, e = process.Run(cancelled, plugin.ApplicationProcessInput{Command: executable})
	code(e, "cancelled")
	must(processes.Close(ctx))
	must(processEnvironment.Close())
	_, e = run("nonzero", 5000, 4096)
	code(e, "cancelled")
	p, e := profile.Resolve(profile.Options{DataDir: filepath.Join(temp, "daemon")})
	must(e)
	connection, e := daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: executable})
	must(e)
	again, e := daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: executable})
	must(e)
	assert(again.Epoch == connection.Epoch, "duplicate daemon")
	must(daemon.Stop(ctx, p))
	_, e = os.Stat(p.LockPath)
	assert(os.IsNotExist(e), "ownership not released")
	_, e = os.Stat(p.DiscoveryPath)
	assert(os.IsNotExist(e), "discovery retained")
	connection, e = daemon.Status(ctx, p)
	must(e)
	assert(connection == nil, "stopped daemon still running")
	gate := filepath.Join(temp, "launch-gate")
	launchCtx, cancelLaunch := context.WithCancel(ctx)
	type launched struct {
		connection *profile.Connection
		err        error
	}
	launchDone := make(chan launched, 1)
	go func() {
		c, e := daemon.Ensure(launchCtx, p, daemon.LaunchOptions{Executable: executable, Environment: append(os.Environ(), "MOKUSEI_HELPER_LAUNCH_GATE="+gate)})
		launchDone <- launched{c, e}
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, e := os.Stat(gate + ".started"); e == nil {
			break
		}
		assert(time.Now().Before(deadline), "launch not observed")
		time.Sleep(5 * time.Millisecond)
	}
	cancelLaunch()
	select {
	case <-launchDone:
		panic("cancelled launcher returned before child ownership settled")
	case <-time.After(100 * time.Millisecond):
	}
	must(os.WriteFile(gate+".release", nil, 0600))
	select {
	case result := <-launchDone:
		assert(errors.Is(result.err, context.Canceled) && result.connection != nil, "cancelled launch did not settle ownership")
	case <-time.After(10 * time.Second):
		panic("cancelled launch did not settle")
	}
	must(daemon.Stop(ctx, p))
	var launchedAgain [2]*profile.Connection
	errs2 := make(chan error, 2)
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, e := daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: executable})
			launchedAgain[i] = c
			errs2 <- e
		}()
	}
	wg.Wait()
	close(errs2)
	for e := range errs2 {
		must(e)
	}
	assert(launchedAgain[0].Epoch == launchedAgain[1].Epoch, "concurrent launcher divergence")
	must(daemon.Stop(ctx, p))
	verifyStaleDiscovery(ctx, temp, executable)
	must(verifyProfileIdentity())
	verifyFailedShutdown(ctx, temp, executable)
	fmt.Println("PASS: process nonzero/combined output limit/env override/not-found/cancel/timeout/descendant cleanup; daemon cancelled-start ownership barrier, concurrent launch and failed-shutdown diagnostics/reopen")
	fmt.Println(`{"attachments":"PASS: staged bytes, canonical retention, preview, immutable ownership, fork, traversal/case rejection, tamper detection, safe orphan collection","environment":"PASS: 16-way single acquisition, detached snapshots, refresh, canceled cache, shutdown","daemon":"PASS: detached start/reuse/status/stop response and profile release","race":"enabled"}`)
}
