// Command attachment-lifecycle exercises production attachment ownership through
// Runtime, SQLite, atomic client drafts and a separately locked client process.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
)

const (
	leaseID         = "11111111-2222-4333-8444-555555555555"
	restoredLeaseID = "22222222-3333-4444-8555-666666666666"
)

var payload = []byte("Attachment lifecycle evidence\n")
var rejectedOpen = errors.New("fixture rejects native Open after input retention")

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func require(ok bool, format string, args ...any) {
	if !ok {
		panic(fmt.Sprintf(format, args...))
	}
}

func main() {
	if len(os.Args) == 4 && os.Args[1] == "lease-child" {
		holdLease(os.Args[2], os.Args[3])
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "handoff-child" {
		saveDraftAndExit(os.Args[2])
		return
	}
	only := flag.String("case", "all", "all, last-owner, crash-artifacts, fork-private, draft-restart, restored-process-refs, command-journal, corrupt-journal, draft-exit-race, failed-send, crashed-staging, stream-collection, corrupt-draft, or v1-draft")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cases := []struct {
		name string
		run  func(context.Context)
	}{
		{"last-owner", verifyLastOwner},
		{"crash-artifacts", verifyCrashArtifacts},
		{"fork-private", verifyForkAndPrivateOwner},
		{"draft-restart", verifyDraftRestart},
		{"restored-process-refs", verifyRestoredProcessRefs},
		{"command-journal", verifyCommandJournal},
		{"corrupt-journal", verifyCorruptJournal},
		{"draft-exit-race", verifyDraftExitRace},
		{"failed-send", verifyFailedSend},
		{"crashed-staging", verifyCrashedStaging},
		{"stream-collection", verifyStreamCollection},
		{"corrupt-draft", func(ctx context.Context) { verifyUnreadableDraft(ctx, true) }},
		{"v1-draft", func(ctx context.Context) { verifyUnreadableDraft(ctx, false) }},
	}
	matched := false
	for _, item := range cases {
		if *only != "all" && *only != item.name {
			continue
		}
		matched = true
		item.run(ctx)
		fmt.Printf("PASS: attachment lifecycle %s\n", item.name)
	}
	require(matched, "unknown case %q", *only)
	fmt.Println("PASS: Runtime/SQLite attachment collection, durable drafts, client crash leases and concurrent stream ownership")
}

type profile struct {
	dir, client string
	db          *store.Store
	repo        *attachments.Repository
	runtime     *core.Runtime
	mu          sync.Mutex
	logs        []string
}

func newProfile(ctx context.Context) *profile {
	dir, err := os.MkdirTemp("", "mokusei-attachment-lifecycle-")
	must(err)
	p := &profile{dir: dir, client: filepath.Join(dir, "client")}
	opened := false
	defer func() {
		if !opened {
			p.close()
		}
	}()
	p.open(ctx)
	opened = true
	return p
}

func (p *profile) open(ctx context.Context) {
	var err error
	p.db, err = store.Open(filepath.Join(p.dir, "state.sqlite"))
	must(err)
	// Recreate the repository too: internal pending imports belong to its lifetime.
	p.repo = attachments.NewWithClientStorage(filepath.Join(p.dir, "attachments"), p.client)
	p.runtime, err = core.New(ctx, core.Config{
		Store: p.db, DataDir: p.dir, DefaultCwd: p.dir, Attachments: p.repo,
		Harnesses: map[string]plugin.Harness{"fixture": fixtureHarness{}},
		Log: func(kind string, err error) {
			p.mu.Lock()
			defer p.mu.Unlock()
			p.logs = append(p.logs, kind+": "+err.Error())
		},
	})
	must(err)
}

func (p *profile) closeRuntime() {
	if p.runtime != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		must(p.runtime.Close(ctx))
		p.runtime = nil
	}
	if p.db != nil {
		must(p.db.Close())
		p.db = nil
	}
}

func (p *profile) restart(ctx context.Context) {
	p.closeRuntime()
	p.mu.Lock()
	p.logs = nil
	p.mu.Unlock()
	p.open(ctx)
}

func (p *profile) close() {
	defer os.RemoveAll(p.dir)
	p.closeRuntime()
}

func (p *profile) stage(ctx context.Context) model.Attachment {
	encoded, err := json.Marshal(map[string]string{"$mokuseiArrayBuffer": base64.StdEncoding.EncodeToString(payload)})
	must(err)
	files, err := p.repo.Stage(ctx, []attachments.Import{{Source: "bytes", DisplayName: "evidence.txt", Bytes: encoded}})
	must(err)
	require(len(files) == 1, "expected one staged attachment, got %d", len(files))
	return files[0]
}

func input(file model.Attachment) model.AgentInput {
	return model.AgentInput{Parts: []model.AgentInputPart{{Kind: "local-file", File: &model.InputFile{ID: file.ID}}}}
}

func (p *profile) addThread(ctx context.Context, id string) model.ThreadRecord {
	metadata, err := (plugin.GeneratedThreadMetadata{}).Initialize(id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Attachment fixture"}}}, json.RawMessage(`{}`))
	must(err)
	at := time.Now().UnixMilli()
	record := model.ThreadRecord{
		SessionRecord: model.SessionRecord{ID: id, HarnessID: "fixture", Cwd: p.dir, Settings: json.RawMessage(`{}`), SessionState: json.RawMessage(`{}`), CreatedAt: at, UpdatedAt: at},
		Title:         "Attachment fixture", MetadataState: metadata,
	}
	_, err = p.db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("thread:"+id, record); err != nil {
			return err
		}
		return tx.SetOrder("threads", append(tx.Order("threads"), id))
	})
	must(err)
	return record
}

func assertReadable(ctx context.Context, p *profile, file model.Attachment) {
	canonical, err := p.repo.CanonicalizeInput(ctx, input(file))
	must(err)
	require(len(canonical.Parts) == 1 && canonical.Parts[0].File != nil, "attachment did not canonicalize")
	data, err := os.ReadFile(canonical.Parts[0].File.Path)
	must(err)
	require(string(data) == string(payload), "attachment content changed")
}

func assertRemoved(p *profile, file model.Attachment) {
	for _, path := range []string{file.Path, filepath.Dir(file.Path), filepath.Join(p.dir, "attachments", ".metadata", file.ID+".json")} {
		_, err := os.Stat(path)
		require(errors.Is(err, os.ErrNotExist), "attachment resource still exists or cannot be inspected: %s: %v", path, err)
	}
}

func verifyLastOwner(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	p.addThread(ctx, "last-owner")
	file := p.stage(ctx)
	_, err := p.repo.RetainInput(ctx, "last-owner", input(file))
	must(err)
	must(p.runtime.DeleteThread(ctx, "last-owner"))
	_, err = p.runtime.Thread("last-owner")
	require(err != nil, "deleted thread remains available")
	// No explicit collector call: deletion must release the final owner itself.
	assertRemoved(p, file)
	p.restart(ctx)
	assertRemoved(p, file)
}

func verifyCrashArtifacts(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	metadataOnly, payloadOnly, owned := p.stage(ctx), p.stage(ctx), p.stage(ctx)
	p.addThread(ctx, "diagnostic-owner")
	_, err := p.repo.RetainInput(ctx, "diagnostic-owner", input(owned))
	must(err)
	manifestPath := func(file model.Attachment) string {
		return filepath.Join(p.dir, "attachments", ".metadata", file.ID+".json")
	}
	retainedManifest, err := os.ReadFile(manifestPath(owned))
	must(err)
	p.closeRuntime()
	// Reproduce the exact disk states left by interruption between the two
	// removals. A new repository retires the old in-memory pending import owner.
	must(os.RemoveAll(filepath.Dir(metadataOnly.Path)))
	must(os.Remove(manifestPath(payloadOnly)))
	// A damaged live attachment must keep its remaining metadata for diagnosis.
	must(os.RemoveAll(filepath.Dir(owned.Path)))
	_, err = os.Stat(manifestPath(metadataOnly))
	must(err)
	_, err = os.Stat(payloadOnly.Path)
	must(err)
	p.open(ctx)
	assertRemoved(p, metadataOnly)
	assertRemoved(p, payloadOnly)
	currentManifest, err := os.ReadFile(manifestPath(owned))
	must(err)
	require(string(currentManifest) == string(retainedManifest), "collection changed a live owner's diagnostic manifest")
	_, err = p.runtime.Thread("diagnostic-owner")
	must(err)
	_, err = p.repo.CanonicalizeInput(ctx, input(owned))
	require(err != nil, "missing live attachment payload unexpectedly canonicalized")
	// Removing that final durable owner must also collect its metadata-only tail.
	must(p.runtime.DeleteThread(ctx, "diagnostic-owner"))
	assertRemoved(p, owned)
}

func verifyForkAndPrivateOwner(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	source := p.addThread(ctx, "source-owner")
	file := p.stage(ctx)
	_, err := p.repo.RetainInput(ctx, source.ID, input(file))
	must(err)
	fork, err := p.runtime.ForkThread(ctx, source.ID, json.RawMessage(`{}`))
	must(err)
	must(p.runtime.DeleteThread(ctx, source.ID))
	must(p.repo.Discard(ctx, []string{file.ID}))
	assertReadable(ctx, p, file)
	p.restart(ctx)
	assertReadable(ctx, p, file) // Only the fork owns this file so far.
	privateID := "private-attachment-owner"
	privateKey := "private-session:attachment-fixture:retained"
	privateRecord := source.SessionRecord
	privateRecord.ID = privateID
	_, err = p.db.Update(ctx, func(tx *store.Tx) error {
		return tx.Put(privateKey, plugin.PrivateSessionSnapshot{
			Ref:    plugin.PrivateSessionRef{Owner: plugin.BackgroundAgentRef{PluginID: "fixture", AgentID: "attachment-fixture", Binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}, SessionKey: "retained", SessionID: privateID},
			Record: privateRecord,
		})
	})
	must(err)
	_, err = p.repo.RetainInput(ctx, privateID, input(file))
	must(err)
	must(p.runtime.DeleteThread(ctx, fork))
	assertReadable(ctx, p, file)
	p.restart(ctx)
	assertReadable(ctx, p, file)
	_, err = p.db.Update(ctx, func(tx *store.Tx) error { return tx.Delete(privateKey) })
	must(err)
	p.restart(ctx)
	assertRemoved(p, file)
}

func draftPath(p *profile) string { return filepath.Join(p.client, "client-drafts", "fixture.json") }

func draftBytes(version int, files []model.Attachment) []byte {
	value := map[string]any{"version": version, "scope": "attachment-fixture", "value": map[string]any{"text": "unsent attachment", "attachments": append([]model.Attachment{}, files...)}}
	if version == 2 {
		ids := make([]string, 0, len(files))
		for _, file := range files {
			ids = append(ids, file.ID)
		}
		value["attachmentIDs"] = ids
	}
	data, err := json.Marshal(value)
	must(err)
	return data
}

func persistDraft(p *profile, version int, files ...model.Attachment) {
	writeClientRecord(p.client, draftPath(p), draftBytes(version, files))
}

func writeClientRecord(root, path string, data []byte) {
	withClientOwnership(root, func() { writeAtomic(path, data) })
}

func removeClientRecord(root, path string) {
	withClientOwnership(root, func() { must(os.Remove(path)) })
}

// The fixture's client writers share the same kernel gate as native draft,
// process-reference and journal writers. Production collection takes LOCK_EX.
func withClientOwnership(root string, action func()) {
	path := filepath.Join(root, "client-attachment-leases", "ownership.lock")
	must(os.MkdirAll(filepath.Dir(path), 0700))
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	must(err)
	defer file.Close()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_SH|syscall.LOCK_NB)
		if err == nil {
			break
		}
		require(errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR), "acquire shared client ownership: %v", err)
		select {
		case <-timer.C:
			panic("client writer could not acquire shared ownership lock")
		case <-ticker.C:
		}
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	action()
}

func writeAtomic(path string, data []byte) {
	must(os.MkdirAll(filepath.Dir(path), 0700))
	file, err := os.OpenFile(path+".partial", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	must(err)
	_, err = file.Write(data)
	must(errors.Join(err, file.Sync(), file.Close()))
	must(os.Rename(path+".partial", path))
}

func verifyDraftRestart(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	client := startLease(ctx, p.client)
	defer client.stop()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	// GC and a fresh daemon must preserve the Stage -> atomic draft handoff.
	must(p.repo.CollectOrphans(ctx, 0))
	assertReadable(ctx, p, file)
	p.restart(ctx)
	assertReadable(ctx, p, file)
	persistDraft(p, 2, file)
	client.stop()
	p.restart(ctx)
	assertReadable(ctx, p, file)
	// Removing an in-memory chip cannot revoke the persisted draft's ownership.
	must(p.repo.Discard(ctx, []string{file.ID}))
	p.restart(ctx)
	assertReadable(ctx, p, file)
	removeClientRecord(p.client, draftPath(p))
	must(p.repo.Discard(ctx, []string{file.ID}))
	assertRemoved(p, file)
}

func verifyRestoredProcessRefs(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	importer := startLease(ctx, p.client)
	defer importer.stop()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	persistDraft(p, 2, file)
	importer.stop()
	restored := startLeaseID(ctx, p.client, restoredLeaseID)
	defer restored.stop()
	refsPath := filepath.Join(p.client, "client-attachment-leases", restoredLeaseID+".refs.json")
	// Restoring a draft must pin the read value before another writer clears it.
	withClientOwnership(p.client, func() {
		data, err := os.ReadFile(draftPath(p))
		must(err)
		var draft struct {
			AttachmentIDs []string `json:"attachmentIDs"`
		}
		must(json.Unmarshal(data, &draft))
		require(len(draft.AttachmentIDs) == 1 && draft.AttachmentIDs[0] == file.ID, "restored draft lost its attachment")
		refs, err := json.Marshal(map[string]any{"version": 1, "attachmentIDs": draft.AttachmentIDs})
		must(err)
		writeAtomic(refsPath, refs)
		writeAtomic(draftPath(p), draftBytes(2, nil))
	})
	must(p.repo.CollectOrphans(ctx, 0))
	assertReadable(ctx, p, file)
	p.restart(ctx)
	assertReadable(ctx, p, file)
	// The new live process alone is insufficient once its exact references end.
	writeClientRecord(p.client, refsPath, []byte(`{"version":1,"attachmentIDs":[]}`))
	must(p.repo.CollectOrphans(ctx, 0))
	assertRemoved(p, file)
	restored.stop()
	must(p.repo.CollectOrphans(ctx, 0))
	_, err := os.Stat(refsPath)
	require(errors.Is(err, os.ErrNotExist), "retired client reference file survived collection: %v", err)
}

func commandRecord(file model.Attachment, status string) map[string]any {
	fingerprint := sha256.Sum256([]byte(file.ID))
	return map[string]any{
		"key": "attachment-fixture", "id": "33333333-4444-4555-8666-777777777777",
		"fingerprint": hex.EncodeToString(fingerprint[:]), "channel": "thread:send",
		"status": status, "attachmentIDs": []string{file.ID},
	}
}

func persistJournal(p *profile, records ...map[string]any) {
	data, err := json.Marshal(map[string]any{"version": 1, "hostID": "local", "records": append([]map[string]any{}, records...)})
	must(err)
	writeClientRecord(p.client, filepath.Join(p.client, "client-command-journal.json"), data)
}

func verifyCommandJournal(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	client := startLease(ctx, p.client)
	defer client.stop()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	persistJournal(p, commandRecord(file, "unresolved"))
	client.stop()
	for _, status := range []string{"unresolved", "unknown", "indeterminate", "accepted"} {
		persistJournal(p, commandRecord(file, status))
		p.restart(ctx)
		assertReadable(ctx, p, file)
		must(p.repo.CollectOrphans(ctx, 0))
		assertReadable(ctx, p, file)
	}
	persistJournal(p)
	p.restart(ctx)
	assertRemoved(p, file)
}

func verifyCorruptJournal(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	client := startLease(ctx, p.client)
	defer client.stop()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	record := commandRecord(file, "unknown")
	delete(record, "attachmentIDs")
	persistJournal(p, record)
	client.stop()
	require(p.repo.CollectOrphans(ctx, 0) != nil, "command record without attachmentIDs authorized collection")
	assertReadable(ctx, p, file)
	p.restart(ctx)
	assertReadable(ctx, p, file)
	assertCollectionFailureLogged(p)
	persistJournal(p)
	p.restart(ctx)
	assertRemoved(p, file)
}

func verifyFailedSend(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	client := startLease(ctx, p.client)
	defer client.stop()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	persistDraft(p, 2, file)
	client.stop()
	p.addThread(ctx, "failed-send")
	_, err := p.runtime.SendThread(ctx, "failed-send", input(file))
	require(errors.Is(err, rejectedOpen), "expected native failure after RetainInput, got %v", err)
	data, err := os.ReadFile(filepath.Join(p.dir, "attachments", ".owners.json"))
	must(err)
	var index struct {
		Owners map[string][]string `json:"owners"`
	}
	must(json.Unmarshal(data, &index))
	retained := false
	for _, id := range index.Owners["failed-send"] {
		retained = retained || id == file.ID
	}
	require(retained, "failed native opening did not cross durable input retention")
	must(p.runtime.DeleteThread(ctx, "failed-send"))
	must(p.repo.Discard(ctx, []string{file.ID}))
	p.restart(ctx)
	assertReadable(ctx, p, file)
	removeClientRecord(p.client, draftPath(p))
	p.restart(ctx)
	assertRemoved(p, file)
}

func verifyCrashedStaging(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	client := startLease(ctx, p.client)
	defer client.stop()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	must(p.repo.CollectOrphans(ctx, 0))
	assertReadable(ctx, p, file)
	client.stop() // SIGKILL releases the kernel lock without deleting its file.
	p.restart(ctx)
	assertRemoved(p, file)
	_, err := p.repo.Stage(model.WithClientAttachmentLease(ctx, leaseID), []attachments.Import{{Source: "bytes", DisplayName: "late.txt", Bytes: json.RawMessage(`{"$mokuseiArrayBuffer":"bGF0ZQ=="}`)}})
	require(err != nil, "dead client's lease admitted a new import")
}

type observedReader struct {
	io.Reader
	started chan struct{}
	once    sync.Once
}

func (r *observedReader) Read(data []byte) (int, error) {
	r.once.Do(func() { close(r.started) })
	return r.Reader.Read(data)
}

func verifyStreamCollection(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.CloseWithError(context.Canceled)
	source := &observedReader{Reader: reader, started: make(chan struct{})}
	digest := sha256.Sum256(payload)
	type result struct {
		file model.Attachment
		err  error
	}
	staged := make(chan result, 1)
	go func() {
		file, err := p.repo.StageStream(ctx, "evidence.txt", int64(len(payload)), hex.EncodeToString(digest[:]), source)
		staged <- result{file, err}
	}()
	joined := false
	var collected chan error
	collectionJoined := false
	defer func() {
		_ = writer.CloseWithError(context.Canceled)
		if !joined {
			select {
			case <-staged:
			case <-time.After(5 * time.Second):
				panic("stream staging did not join during fixture cleanup")
			}
		}
		if collected != nil && !collectionJoined {
			select {
			case <-collected:
			case <-time.After(5 * time.Second):
				panic("collection did not join during fixture cleanup")
			}
		}
	}()
	select {
	case <-source.started:
	case <-ctx.Done():
		panic(ctx.Err())
	case <-time.After(5 * time.Second):
		panic("stream writer never started")
	}
	entries, err := os.ReadDir(filepath.Join(p.dir, "attachments"))
	must(err)
	var activeDir string
	for _, entry := range entries {
		if entry.IsDir() && entry.Name() != ".metadata" {
			require(activeDir == "", "unexpected multiple staging directories")
			activeDir = filepath.Join(p.dir, "attachments", entry.Name())
		}
	}
	require(activeDir != "", "stream is blocked without an owned output directory")
	collected = make(chan error, 1)
	go func() { collected <- p.repo.CollectOrphans(ctx, 0) }()
	select {
	case err := <-collected:
		collectionJoined = true
		must(err)
	case <-time.After(2 * time.Second):
		panic("collection blocked behind the in-progress stream")
	}
	_, err = os.Stat(filepath.Join(activeDir, "evidence.txt"))
	must(err)
	select {
	case result := <-staged:
		joined = true
		panic(fmt.Sprintf("stream returned before its input arrived: %v", result.err))
	default:
	}
	_, err = writer.Write(payload)
	must(err)
	must(writer.Close())
	var complete result
	select {
	case complete = <-staged:
		joined = true
	case <-time.After(5 * time.Second):
		panic("stream did not finish after its bytes arrived")
	}
	must(complete.err)
	must(p.repo.CollectOrphans(ctx, 0))
	assertReadable(ctx, p, complete.file)
	must(p.repo.Discard(ctx, []string{complete.file.ID}))
	assertRemoved(p, complete.file)
}

func verifyUnreadableDraft(ctx context.Context, malformed bool) {
	p := newProfile(ctx)
	defer p.close()
	client := startLease(ctx, p.client)
	defer client.stop()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	if malformed {
		writeClientRecord(p.client, draftPath(p), []byte(`{"version":2,"scope":`))
	} else {
		persistDraft(p, 1, file)
	}
	client.stop()
	require(p.repo.CollectOrphans(ctx, 0) != nil, "unreadable draft authorized attachment collection")
	assertReadable(ctx, p, file)
	p.restart(ctx)
	assertReadable(ctx, p, file)
	assertCollectionFailureLogged(p)
	removeClientRecord(p.client, draftPath(p))
	p.restart(ctx)
	assertRemoved(p, file)
}

func assertCollectionFailureLogged(p *profile) {
	p.mu.Lock()
	logs := append([]string(nil), p.logs...)
	p.mu.Unlock()
	for _, message := range logs {
		require(len(message) >= len("attachments.collect:") && message[:len("attachments.collect:")] == "attachments.collect:", "unexpected startup error: %s", message)
	}
	require(len(logs) > 0, "unreadable client ownership failure was not surfaced by Runtime startup")
}

type clientLease struct {
	command *exec.Cmd
	done    chan error
	path    string
	joined  bool
}

func startLease(ctx context.Context, root string) *clientLease {
	return startLeaseID(ctx, root, leaseID)
}

func startLeaseID(ctx context.Context, root, id string) *clientLease {
	self, err := os.Executable()
	must(err)
	command := exec.Command(self, "lease-child", root, id)
	command.Env = append(os.Environ(), "GORACE=atexit_sleep_ms=0")
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	client := &clientLease{command: command, done: make(chan error, 1), path: filepath.Join(root, "client-attachment-leases", id+".lock")}
	must(command.Start())
	go func() { client.done <- command.Wait() }()
	ready := false
	defer func() {
		if !ready {
			client.stop()
		}
	}()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		if _, err := os.Stat(client.path + ".ready"); err == nil {
			file, err := os.OpenFile(client.path, os.O_RDWR, 0)
			must(err)
			err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
			_ = file.Close()
			require(errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN), "child did not hold a real flock: %v", err)
			ready = true
			return client
		}
		select {
		case err := <-client.done:
			client.joined = true
			panic(fmt.Sprintf("lease child exited before readiness: %v", err))
		case <-ctx.Done():
			panic(ctx.Err())
		case <-timer.C:
			panic("lease child did not acquire its lock")
		case <-ticker.C:
		}
	}
}

func (c *clientLease) stop() {
	if c.joined {
		return
	}
	err := c.command.Process.Kill()
	require(err == nil || errors.Is(err, os.ErrProcessDone), "kill lease child: %v", err)
	select {
	case <-c.done:
		c.joined = true
	case <-time.After(5 * time.Second):
		panic("lease child was not reaped")
	}
	file, err := os.OpenFile(c.path, os.O_RDWR, 0)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	must(err)
	defer file.Close()
	must(syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
	must(syscall.Flock(int(file.Fd()), syscall.LOCK_UN))
}

func holdLease(root, id string) {
	path := filepath.Join(root, "client-attachment-leases", id+".lock")
	file := acquireLease(root, id)
	defer file.Close()
	writeAtomic(path+".ready", []byte("locked"))
	time.Sleep(2 * time.Minute)
}

func acquireLease(root, id string) *os.File {
	path := filepath.Join(root, "client-attachment-leases", id+".lock")
	var file *os.File
	withClientOwnership(root, func() {
		var err error
		file, err = os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
		must(err)
		must(syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
	})
	return file
}

// Pausing at the first production cancellation check orders the real filesystem
// handoff without a sleep or a test-only hook in the collector. A collector that
// snapshots drafts before inspecting process leases will miss this saved draft.
type collectionBarrier struct {
	context.Context
	entered, release chan struct{}
	enter, resume    sync.Once
}

func (b *collectionBarrier) Err() error {
	b.enter.Do(func() {
		close(b.entered)
		select {
		case <-b.release:
		case <-b.Context.Done():
		}
	})
	return b.Context.Err()
}

func (b *collectionBarrier) open() { b.resume.Do(func() { close(b.release) }) }

func verifyDraftExitRace(ctx context.Context) {
	for iteration := 0; iteration < 3; iteration++ {
		verifyDraftExitHandoff(ctx)
	}
}

func verifyDraftExitHandoff(ctx context.Context) {
	p := newProfile(ctx)
	defer p.close()
	self, err := os.Executable()
	must(err)
	command := exec.Command(self, "handoff-child", p.dir)
	command.Env = append(os.Environ(), "GORACE=atexit_sleep_ms=0")
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	must(command.Start())
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	childJoined := false
	defer func() {
		if !childJoined {
			_ = command.Process.Kill()
			select {
			case <-exited:
			case <-time.After(5 * time.Second):
				panic("draft handoff child did not join")
			}
		}
	}()
	data := awaitFile(ctx, filepath.Join(p.dir, "handoff.json"))
	var file model.Attachment
	must(json.Unmarshal(data, &file))
	assertReadable(ctx, p, file)
	_, err = os.Stat(draftPath(p))
	require(errors.Is(err, os.ErrNotExist), "draft already existed before the gated handoff")
	barrier := &collectionBarrier{Context: ctx, entered: make(chan struct{}), release: make(chan struct{})}
	collected := make(chan error, 1)
	go func() { collected <- p.repo.CollectOrphans(barrier, 0) }()
	collectionJoined := false
	defer func() {
		barrier.open()
		if !collectionJoined {
			select {
			case <-collected:
			case <-time.After(5 * time.Second):
				panic("gated collection did not join")
			}
		}
	}()
	select {
	case <-barrier.entered:
	case <-time.After(5 * time.Second):
		panic("collector never reached its process inspection barrier")
	}
	writeAtomic(filepath.Join(p.dir, "publish-draft"), []byte("save and exit"))
	select {
	case err := <-exited:
		childJoined = true
		must(err)
	case <-time.After(5 * time.Second):
		panic("draft handoff child did not save and exit")
	}
	_, err = os.Stat(draftPath(p))
	must(err)
	barrier.open()
	select {
	case err := <-collected:
		collectionJoined = true
		must(err)
	case <-time.After(5 * time.Second):
		panic("collector did not resume after the client exited")
	}
	assertReadable(ctx, p, file)
	p.restart(ctx)
	assertReadable(ctx, p, file)
}

func awaitFile(ctx context.Context, path string) []byte {
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		data, err := os.ReadFile(path)
		if err == nil {
			return data
		}
		require(errors.Is(err, os.ErrNotExist), "read handoff barrier: %v", err)
		select {
		case <-ctx.Done():
			panic(ctx.Err())
		case <-timer.C:
			panic("handoff file deadline: " + filepath.Base(path))
		case <-ticker.C:
		}
	}
}

func saveDraftAndExit(root string) {
	p := &profile{dir: root, client: filepath.Join(root, "client")}
	lease := acquireLease(p.client, leaseID)
	defer lease.Close()
	p.repo = attachments.NewWithClientStorage(filepath.Join(root, "attachments"), p.client)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	file := p.stage(model.WithClientAttachmentLease(ctx, leaseID))
	data, err := json.Marshal(file)
	must(err)
	writeAtomic(filepath.Join(root, "handoff.json"), data)
	awaitFile(ctx, filepath.Join(root, "publish-draft"))
	// Deliberately bypass the writer gate only in this deterministic old-order
	// regression, so the collector's lease/draft snapshot order stays observable.
	writeAtomic(draftPath(p), draftBytes(2, []model.Attachment{file}))
}

// The fixture exposes only the idle/fork state needed by Runtime. Native Open
// deliberately fails so the failed-send check crosses the real RetainInput path.
type fixtureHarness struct{ plugin.Harness }

func (fixtureHarness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "fixture", DisplayName: "Attachment fixture"}
}
func (fixtureHarness) DefaultSettings() json.RawMessage         { return json.RawMessage(`{}`) }
func (fixtureHarness) SessionState() plugin.SessionStateAdapter { return fixtureState{} }
func (fixtureHarness) Metadata() plugin.ThreadMetadataAdapter {
	return plugin.GeneratedThreadMetadata{}
}
func (fixtureHarness) Open(context.Context, plugin.OpenContext) (plugin.Handle, error) {
	return nil, rejectedOpen
}
func (fixtureHarness) Fork(_ context.Context, request plugin.ForkRequest) (plugin.ForkResult, error) {
	return plugin.ForkResult{SessionState: request.Source.SessionState, Settings: request.Source.Settings, MetadataState: request.Source.MetadataState}, nil
}

type fixtureState struct{ plugin.SessionStateAdapter }

func (fixtureState) Project(json.RawMessage) (model.PublicObservation, error) {
	return model.PublicObservation{}, nil
}
func (fixtureState) ProjectRenderer(json.RawMessage, model.RendererScope) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (fixtureState) ReadContext(json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
