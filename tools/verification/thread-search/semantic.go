package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
	"github.com/hupao-creator/Mokusei/internal/services/embedding"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

// Explicit fixture vectors control model completion and space replacement. Real
// semantic quality is checked separately through the same Runtime with LiteRT.
type replayEmbedding struct {
	space     string
	reversed  bool
	gate      chan struct{}
	entered   chan struct{}
	once      sync.Once
	mu        sync.Mutex
	documents int
}

func (p *replayEmbedding) Descriptor() embedding.Descriptor {
	return embedding.Descriptor{Space: p.space, Name: "Replay", Dimensions: 2, DocumentBytes: 256}
}
func (p *replayEmbedding) Status() embedding.Status {
	return embedding.Status{Phase: "ready", Ready: true}
}
func (p *replayEmbedding) Retry()       {}
func (p *replayEmbedding) Close() error { return nil }
func (p *replayEmbedding) count() int   { p.mu.Lock(); defer p.mu.Unlock(); return p.documents }
func (p *replayEmbedding) Embed(ctx context.Context, kind embedding.Kind, texts []string) ([][]float32, error) {
	if kind == embedding.Document {
		p.mu.Lock()
		p.documents += len(texts)
		p.mu.Unlock()
		if p.gate != nil {
			p.once.Do(func() { close(p.entered) })
			select {
			case <-p.gate:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
	}
	vectors := make([][]float32, len(texts))
	for i, text := range texts {
		if strings.Contains(text, "NEVER_UPLOAD") {
			return nil, errors.New("private source field reached embedding")
		}
		positive := (kind == embedding.Query && text == "find-related") || (kind == embedding.Document && text == "A retained public passage.")
		if positive != p.reversed {
			vectors[i] = []float32{1, 0}
		} else {
			vectors[i] = []float32{0, 1}
		}
	}
	return vectors, nil
}
func hybridRuntime(ctx context.Context, directory string, db *store.Store, provider embedding.Provider) *core.Runtime {
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}},
		DataDir: directory, DefaultCwd: directory, Embedding: provider})
	must(err)
	return r
}
func awaitHybrid(r *core.Runtime, text, expected string, scope []model.ThreadRef) threadsearch.QueryResult {
	var result threadsearch.QueryResult
	wait("hybrid result "+expected, func() bool {
		result = query(r, text, scope...)
		return result.Mode == "hybrid" && len(result.Hits) > 0 && result.Hits[0].Ref.ThreadID == expected
	})
	return result
}
func verifyHybridLifecycle(ctx context.Context, directory string) {
	must(os.MkdirAll(directory, 0700))
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	must(err)
	defer db.Close()
	seed(db, thread("alpha", "Topic A", "A retained public passage."), thread("noise", "Other topic", "Unrelated public text."))
	p := &replayEmbedding{space: "fixture-space-a"}
	r := hybridRuntime(ctx, directory, db, p)
	defer func() { must(r.Close(ctx)) }()
	first := query(r, "find-related", refs("alpha", "noise")...)
	assert(first.Mode == "keyword", "cold query returns keyword results before embedding completion")
	result := awaitHybrid(r, "find-related", "alpha", refs("alpha", "noise"))
	assert(len(result.Hits) == 1, "semantic recall returns one thread and excludes the orthogonal fixture")
	count := p.count()
	changed := thread("alpha", "Topic A", "A retained public passage.")
	changed.UpdatedAt = 2
	seed(db, changed)
	assert(len(query(r, "find-related", refs("alpha")...).Hits) == 0, "changed owner immediately revokes old vector hits")
	awaitHybrid(r, "find-related", "alpha", refs("alpha"))
	assert(p.count() == count, "unchanged passages reuse persisted vectors after owner-only changes")
	seed(db, thread("title", "find-related", "Unrelated public text."))
	awaitHybrid(r, "find-related", "title", refs("alpha", "title"))
	must(r.SetArchived(ctx, "alpha", true))
	assert(len(query(r, "find-related", refs("alpha")...).Hits) == 0, "archive revokes vector results and cached hits")
	must(r.SetArchived(ctx, "alpha", false))
	awaitHybrid(r, "find-related", "alpha", refs("alpha"))
	must(r.Close(ctx))
	p2 := &replayEmbedding{space: "fixture-space-b", reversed: true, gate: make(chan struct{}), entered: make(chan struct{})}
	r = hybridRuntime(ctx, directory, db, p2)
	select {
	case <-p2.entered:
	case <-time.After(12 * time.Second):
		panic("replacement provider did not start")
	}
	wait("replacement query embedding", func() bool { return query(r, "find-related", refs("alpha")...).Mode == "hybrid" })
	assert(len(query(r, "find-related", refs("alpha")...).Hits) == 0, "same dimensions cannot reuse an incompatible model space")
	// The in-flight build holds the old owner snapshot while archive commits.
	must(r.SetArchived(ctx, "alpha", true))
	close(p2.gate)
	time.Sleep(100 * time.Millisecond)
	assert(len(query(r, "find-related", refs("alpha")...).Hits) == 0, "late old-owner embeddings cannot resurrect an archived thread")
	must(r.SetArchived(ctx, "alpha", false))
	awaitHybrid(r, "find-related", "alpha", refs("alpha"))
	must(r.ClearHistory(ctx))
	assert(len(query(r, "find-related", refs("alpha")...).Hits) == 0, "history reset revokes vectors and query cache")
	index, err := sqlite.Open(filepath.Join(directory, "search-index.sqlite"), true)
	must(err)
	rows, err := index.Query("SELECT COUNT(*) AS n FROM vectors")
	must(err)
	assert(rows[0]["n"].(int64) == 0, "history clear physically removes vectors from the derived database")
	must(index.Close())
	fmt.Println("PASS hybrid Runtime/SQLite: cold keyword response, semantic thread deduplication, vector reuse, exact-title priority, archive, model-space replacement, late completion and history clear")
	broken := filepath.Join(directory, "unavailable-index")
	must(os.MkdirAll(filepath.Join(broken, "search-index.sqlite"), 0700))
	brokenDB, e := store.Open(filepath.Join(broken, "state.sqlite"))
	must(e)
	defer brokenDB.Close()
	seed(brokenDB, thread("alpha", "Topic A", "A retained public passage."))
	brokenRuntime := hybridRuntime(ctx, broken, brokenDB, &replayEmbedding{space: "fixture-space-a"})
	defer brokenRuntime.Close(ctx)
	start(brokenRuntime)
	wait("index failure is observable", func() bool { return status(brokenRuntime).Semantic.Reason == "semantic-index-failed" })
	assert(len(query(brokenRuntime, "retained", refs("alpha")...).Hits) == 1, "an unavailable vector database preserves keyword search and Runtime startup")
	must(os.Remove(filepath.Join(broken, "search-index.sqlite")))
	invoke(brokenRuntime, "search:retry")
	awaitHybrid(brokenRuntime, "find-related", "alpha", refs("alpha"))
	fmt.Println("PASS vector database failure: keyword fallback, visible failure and explicit retry recovery")
}

func waitNative(label string, duration time.Duration, check func() bool) error {
	deadline := time.Now().Add(duration)
	for !check() {
		if time.Now().After(deadline) {
			return fmt.Errorf("native replay timeout: %s", label)
		}
		time.Sleep(100 * time.Millisecond)
	}
	return nil
}
func verifyNativeHybrid(ctx context.Context, helper, models string) error {
	if helper == "" || models == "" {
		return errors.New("native replay requires embedding-helper and model-directory")
	}
	helper, err := filepath.Abs(helper)
	if err != nil {
		return err
	}
	models, err = filepath.Abs(models)
	if err != nil {
		return err
	}
	directory, err := os.MkdirTemp("", "mokusei-native-embedding-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	if err != nil {
		return err
	}
	defer db.Close()
	seed(db,
		thread("git", "版本控制", "保存未提交的代码修改，创建临时存档后切换 Git 分支，之后恢复工作区。"),
		thread("retrieval", "Search storage", "The application stores conversation embeddings locally and removes stale search results when a thread is deleted."),
		thread("food", "早餐", "把面粉、鸡蛋和牛奶搅拌均匀，在平底锅中制作早餐。"),
		thread("identifier", "exact-ID-42", "A discussion about project labels."))
	p := embedding.NewNative(ctx, embedding.NativeOptions{Executable: helper, ModelDirectory: models, IdleTimeout: 2 * time.Second})
	r := hybridRuntime(ctx, directory, db, p)
	defer func() { must(r.Close(ctx)) }()
	lastPhase := ""
	if err = waitNative("verified model preparation", 12*time.Minute, func() bool {
		state := p.Status()
		if state.Phase != lastPhase {
			fmt.Printf("native embedding preparation: %s (%s)\n", state.Phase, state.Reason)
			lastPhase = state.Phase
		}
		return state.Ready
	}); err != nil {
		return err
	}
	scope := refs("git", "retrieval", "food", "identifier")
	for _, sample := range []struct{ query, want string }{
		{"切换分支之前怎样保留手头的改动", "git"},
		{"How does deleting a conversation affect semantic retrieval?", "retrieval"},
		{"煎饼的制作方法", "food"},
		{"删除对话后是否还会出现旧的语义搜索结果", "retrieval"},
		{"exact-ID-42", "identifier"},
	} {
		var result threadsearch.QueryResult
		if err = waitNative("real semantic ranking: "+sample.want, 45*time.Second, func() bool {
			result = query(r, sample.query, scope...)
			return result.Mode == "hybrid" && len(result.Hits) > 0 && result.Hits[0].Ref.ThreadID == sample.want
		}); err != nil {
			return fmt.Errorf("%w; last result: %+v", err, result)
		}
		seen := map[string]bool{}
		for _, hit := range result.Hits {
			if seen[hit.Ref.ThreadID] {
				return errors.New("duplicate native semantic thread result")
			}
			seen[hit.Ref.ThreadID] = true
		}
		fmt.Printf("PASS real INT4 semantic retrieval: %s -> %s\n", sample.query, sample.want)
	}
	if err = r.Close(ctx); err != nil {
		return err
	}
	// Deny networking only in this disposable child process. Its verified asset
	// must support preparation, model load, indexing and retrieval offline.
	wrapper := filepath.Join(directory, "offline-embedding")
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
	command := "#!/bin/sh\nexec /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' " + quote(helper) + " \"$@\"\n"
	if err = os.WriteFile(wrapper, []byte(command), 0700); err != nil {
		return err
	}
	offline := embedding.NewNative(ctx, embedding.NativeOptions{Executable: wrapper, ModelDirectory: models, IdleTimeout: 2 * time.Second})
	r = hybridRuntime(ctx, directory, db, offline)
	if err = waitNative("offline semantic retrieval", 30*time.Second, func() bool {
		result := query(r, "切换分支之前怎样保留手头的改动", scope...)
		return result.Mode == "hybrid" && len(result.Hits) > 0 && result.Hits[0].Ref.ThreadID == "git"
	}); err != nil {
		return err
	}
	pid := embeddingChildPID()
	if pid <= 1 {
		return errors.New("native helper process was not observed")
	}
	if err = waitNative("idle process retirement", 15*time.Second, func() bool { return offline.Status().Phase == "idle" }); err != nil {
		return err
	}
	if !errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
		return errors.New("idle helper still exists after retirement")
	}
	if _, err = offline.Embed(ctx, embedding.Query, []string{"怎样保存改动后切换版本控制分支"}); err != nil {
		return err
	}
	if err = r.SetArchived(ctx, "git", true); err != nil {
		return err
	}
	for _, hit := range query(r, "切换分支之前怎样保留手头的改动", scope...).Hits {
		if hit.Ref.ThreadID == "git" {
			return errors.New("archived real-model result escaped")
		}
	}
	if err = r.ClearHistory(ctx); err != nil {
		return err
	}
	if len(query(r, "切换分支之前怎样保留手头的改动", scope...).Hits) != 0 {
		return errors.New("real-model history clear retained hits")
	}
	fmt.Println("PASS real INT4 Runtime: Chinese/English/cross-language ranking, identifiers, unique threads, network-denied offline restart, observed idle exit/reload, archive and history clear")
	if err = r.Close(ctx); err != nil {
		return err
	}
	entries, err := os.ReadDir(models)
	if err != nil {
		return err
	}
	modelName := ""
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".litertlm") {
			modelName = entry.Name()
			break
		}
	}
	if modelName == "" {
		return errors.New("verified asset not found")
	}
	bad := filepath.Join(directory, "corrupted-model")
	if err = os.MkdirAll(bad, 0700); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(bad, modelName), []byte("corrupt asset"), 0600); err != nil {
		return err
	}
	partial := filepath.Join(bad, "00000000-0000-4000-8000-000000000001.partial")
	if err = os.WriteFile(partial, []byte("interrupted download"), 0600); err != nil {
		return err
	}
	recovering := embedding.NewNative(ctx, embedding.NativeOptions{Executable: wrapper, ModelDirectory: bad})
	defer recovering.Close()
	if err = waitNative("corrupt asset refused offline", 20*time.Second, func() bool { return recovering.Status().Phase == "failed" }); err != nil {
		return err
	}
	if recovering.Status().Ready {
		return errors.New("corrupt asset admitted")
	}
	if _, err = os.Stat(partial); !errors.Is(err, os.ErrNotExist) {
		return errors.New("interrupted model staging was not reclaimed")
	}
	source, err := os.Open(filepath.Join(models, modelName))
	if err != nil {
		return err
	}
	target, err := os.Create(filepath.Join(bad, modelName))
	if err != nil {
		source.Close()
		return err
	}
	_, err = io.Copy(target, source)
	err = errors.Join(err, target.Close(), source.Close())
	if err != nil {
		return err
	}
	recovering.Retry()
	if err = waitNative("verified asset recovered by retry", 20*time.Second, func() bool { return recovering.Status().Ready }); err != nil {
		return err
	}
	if _, err = recovering.Embed(ctx, embedding.Query, []string{"本地搜索"}); err != nil {
		return err
	}
	fmt.Println("PASS model asset lifecycle: corrupted bytes rejected, interrupted staging reclaimed and explicit retry recovered offline")
	if err = recovering.Close(); err != nil {
		return err
	}
	if err = verifyEmbeddingParentExit(ctx, helper, models); err != nil {
		return err
	}
	return nil
}
func embeddingChildPID() int {
	output, err := exec.Command("/bin/ps", "-axo", "pid=,ppid=,command=").Output()
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		parent, _ := strconv.Atoi(fields[1])
		pid, _ := strconv.Atoi(fields[0])
		if parent == os.Getpid() && strings.Contains(strings.Join(fields[2:], " "), "MokuseiEmbedding") {
			return pid
		}
	}
	return 0
}

func verifyEmbeddingParentExit(ctx context.Context, helper, models string) error {
	script := `import json, os, subprocess, sys
p=subprocess.Popen([sys.argv[1], '--model-directory', sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
assert json.loads(p.stdout.readline())['event']=='hello'
p.stdin.write(json.dumps({'id':1,'operation':'prepare'})+'\n');p.stdin.flush()
while True:
 r=json.loads(p.stdout.readline())
 if r.get('event')=='result':
  assert not r.get('error'), r
  break
p.stdin.write(json.dumps({'id':2,'operation':'embed','kind':'query','texts':['a '*2000]*4})+'\n');p.stdin.flush()
while True:
 r=json.loads(p.stdout.readline())
 if r.get('event')=='status' and r.get('phase')=='ready':
  print(p.pid,flush=True)
  os._exit(0)
 if r.get('error'): raise RuntimeError(r)
`
	deadline, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	output, err := exec.CommandContext(deadline, "/usr/bin/python3", "-c", script, helper, models).Output()
	if err != nil {
		return err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(output)))
	if err != nil || pid <= 1 {
		return errors.New("invalid parent-exit probe pid")
	}
	if err = waitNative("orphaned native inference exits", 2*time.Second, func() bool {
		if errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
			return true
		}
		status, err := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "stat=").Output()
		return err == nil && strings.HasPrefix(strings.TrimSpace(string(status)), "Z")
	}); err != nil {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		return err
	}
	fmt.Println("PASS native ownership: helper exits when its Runtime parent dies during inference")
	return nil
}
