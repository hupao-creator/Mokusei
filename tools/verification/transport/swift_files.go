package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type swiftFileHost struct {
	*mockHost
	filesMu   sync.Mutex
	uploads   []string
	downloads []string
}

func (h *swiftFileHost) Invoke(ctx context.Context, channel string, args []json.RawMessage) (any, error) {
	if channel == "state:load" {
		return json.RawMessage(`{"revision":1,"defaultCwd":"","threads":[],"executions":[],"applicationThreads":[],"settings":{},"settingsRevision":1}`), nil
	}
	return h.mockHost.Invoke(ctx, channel, args)
}

func (*swiftFileHost) FilePolicy(context.Context) (model.AttachmentPolicy, error) {
	return model.AttachmentPolicy{ImageBytes: 1 << 20, PDFBytes: 1 << 20, FileBytes: 1 << 20, MessageBytes: 2 << 20, MessageCount: 20}, nil
}
func (*swiftFileHost) BrowseFiles(context.Context, *model.HostFileReference) (model.HostDirectory, error) {
	result := model.HostDirectory{Reference: model.HostFileReference{Path: "/fixture"}}
	for _, name := range []string{"target.txt", "alias-a", "alias-b"} {
		result.Entries = append(result.Entries, model.HostFileEntry{
			Reference: model.HostFileReference{Path: "/fixture/target.txt"}, Name: name,
			Size: 76, MimeType: "text/plain",
		})
	}
	return result, nil
}
func (*swiftFileHost) StageHostFiles(context.Context, []model.HostFileReference) ([]model.Attachment, error) {
	return nil, errors.New("unused")
}
func (h *swiftFileHost) UploadAttachment(_ context.Context, name string, size int64, digest string, source io.Reader) (model.Attachment, error) {
	content, err := io.ReadAll(source)
	if err != nil {
		return model.Attachment{}, err
	}
	expected := []byte(strings.Repeat("file boundary fixture\n", 10_000))
	hash := sha256.Sum256(expected)
	if (name != "regular.bin" && name != "symlink.bin") || !bytes.Equal(content, expected) || size != int64(len(expected)) || digest != hex.EncodeToString(hash[:]) {
		return model.Attachment{}, errors.New("native upload differed from the fixed file fixture")
	}
	h.filesMu.Lock()
	h.uploads = append(h.uploads, name)
	h.filesMu.Unlock()
	return model.Attachment{ID: "fixture-" + name, Name: name, Size: size, MimeType: "application/octet-stream", Kind: "file"}, nil
}
func (h *swiftFileHost) DownloadFile(_ context.Context, reference model.HostFileReference) (*transport.FileDownload, error) {
	if reference.Path != ".partial" && reference.Path != "ordinary.bin" {
		return nil, errors.New("unexpected native download reference")
	}
	content := []byte("download fixture\x00includes binary bytes\n")
	hash := sha256.Sum256(content)
	h.filesMu.Lock()
	h.downloads = append(h.downloads, reference.Path)
	h.filesMu.Unlock()
	return &transport.FileDownload{Reader: io.NopCloser(bytes.NewReader(content)), Name: reference.Path,
		MimeType: "application/octet-stream", Size: int64(len(content)), SHA256: hex.EncodeToString(hash[:])}, nil
}

// Swift exercises its production discovery, subscription and file-transfer code
// against the same Go HTTP boundary shipped by the runtime.
func verifySwiftFiles() (failure error) {
	directory, err := os.MkdirTemp("", "mokusei-swift-files-")
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, os.RemoveAll(directory)) }()
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, "data"), HomeDir: directory})
	if err != nil {
		return err
	}
	owner, err := profile.Acquire(p)
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, owner.Release()) }()
	host := &swiftFileHost{mockHost: newMockHost()}
	defer host.releaseAll()
	server, err := transport.Start(transport.Options{Profile: p, Epoch: owner.Epoch, Host: host})
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		failure = errors.Join(failure, server.Close(cleanup), server.Finish(cleanup))
	}()
	if err = profile.PublishConnection(p, server.Connection); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	command := swiftfixture.Test(ctx, "--no-parallel", "--filter", "RuntimeHostFilesInteropTests")
	command.Env = append(os.Environ(), "MOKUSEI_SWIFT_FILES_PROFILE="+p.DataDir)
	var output bytes.Buffer
	command.Stdout = io.MultiWriter(os.Stdout, &output)
	command.Stderr = os.Stderr
	command.WaitDelay = 5 * time.Second
	if err = command.Run(); err != nil {
		return err
	}
	if !bytes.Contains(output.Bytes(), []byte("PASS native host file boundaries")) {
		return errors.New("native host file verification was skipped")
	}
	host.filesMu.Lock()
	defer host.filesMu.Unlock()
	if strings.Join(host.uploads, ",") != "regular.bin,symlink.bin" || strings.Join(host.downloads, ",") != "ordinary.bin,.partial" {
		return fmt.Errorf("unexpected native transfers: uploads=%v downloads=%v", host.uploads, host.downloads)
	}
	fmt.Println("PASS Go/Swift file replay: FIFO rejection; regular/symlink uploads; ordinary and .partial downloads")
	return nil
}
