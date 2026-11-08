package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
)

type swiftFileHost struct {
	*mockHost
	filesMu    sync.Mutex
	uploads    []string
	downloads  []string
	root       string
	clientRoot string
	repository *attachments.Repository
	staged     []model.Attachment
}

func (h *swiftFileHost) HasChannel(channel string) bool {
	return channel == "moku:submit" || channel == "moku:stage-attachments" || channel == "attachment:discard" || h.mockHost.HasChannel(channel)
}

func (h *swiftFileHost) Invoke(ctx context.Context, channel string, args []json.RawMessage) (any, error) {
	if channel == "moku:submit" {
		return h.uncertainAttachmentReceipt(ctx, args)
	}
	if channel == "state:load" {
		return json.RawMessage(`{"revision":1,"defaultCwd":"","threads":[],"executions":[],"applicationThreads":[],"settings":{},"settingsRevision":1}`), nil
	}
	if channel == "moku:stage-attachments" {
		if model.ClientAttachmentLease(ctx) == "" {
			return nil, errors.New("native stage command lost its attachment lease")
		}
		var imports []attachments.Import
		if len(args) != 1 || json.Unmarshal(args[0], &imports) != nil {
			return nil, errors.New("invalid native attachment imports")
		}
		h.filesMu.Lock()
		defer h.filesMu.Unlock()
		staged, err := h.repository.Stage(ctx, imports)
		if err == nil {
			h.staged = append(h.staged, staged...)
		}
		return staged, err
	}
	if channel == "attachment:discard" {
		var ids []string
		if len(args) != 1 || json.Unmarshal(args[0], &ids) != nil {
			return nil, errors.New("invalid native attachment discard")
		}
		h.filesMu.Lock()
		defer h.filesMu.Unlock()
		return nil, h.repository.Discard(ctx, ids)
	}
	if channel == "application:command" && len(args) == 1 {
		var mode string
		if json.Unmarshal(args[0], &mode) == nil && (mode == "attachments:collect" || mode == "attachments:reopen") {
			h.filesMu.Lock()
			defer h.filesMu.Unlock()
			if mode == "attachments:reopen" {
				h.repository = attachments.NewWithClientStorage(h.root, h.clientRoot)
			}
			return nil, h.repository.CollectOrphans(ctx, 0)
		}
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
func (h *swiftFileHost) UploadAttachment(ctx context.Context, name string, size int64, digest string, source io.Reader) (model.Attachment, error) {
	if model.ClientAttachmentLease(ctx) == "" {
		return model.Attachment{}, errors.New("native upload lost its attachment lease")
	}
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
	defer h.filesMu.Unlock()
	staged, err := h.repository.StageStream(ctx, name, size, digest, bytes.NewReader(content))
	if err != nil {
		return model.Attachment{}, err
	}
	h.uploads = append(h.uploads, name)
	h.staged = append(h.staged, staged)
	return staged, nil
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
	root := filepath.Join(p.DataDir, "attachments")
	host := &swiftFileHost{mockHost: newMockHost(), root: root, clientRoot: p.DataDir,
		repository: attachments.NewWithClientStorage(root, p.DataDir)}
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
	runSwift := func(phase string, markers ...string) error {
		command := swiftfixture.Test(ctx, "--no-parallel", "--filter", "RuntimeHostFilesInteropTests")
		command.Env = append(os.Environ(), "MOKUSEI_SWIFT_FILES_PROFILE="+p.DataDir, "MOKUSEI_SWIFT_FILES_PHASE="+phase)
		var output bytes.Buffer
		command.Stdout = io.MultiWriter(os.Stdout, &output)
		command.Stderr = os.Stderr
		command.WaitDelay = 5 * time.Second
		if err := command.Run(); err != nil {
			return err
		}
		for _, marker := range markers {
			if !bytes.Contains(output.Bytes(), []byte(marker)) {
				return fmt.Errorf("native host file verification was skipped: %s", marker)
			}
		}
		return nil
	}
	if err = runSwift("stage", "PASS native host file boundaries", "PASS native uncertain attachment receipt retained"); err != nil {
		return err
	}
	host.filesMu.Lock()
	uploads, downloads, staged := append([]string(nil), host.uploads...), append([]string(nil), host.downloads...), append([]model.Attachment(nil), host.staged...)
	host.repository = attachments.NewWithClientStorage(root, p.DataDir)
	err = host.repository.CollectOrphans(ctx, 0)
	host.filesMu.Unlock()
	if err != nil {
		return err
	}
	if strings.Join(uploads, ",") != "regular.bin,symlink.bin" || strings.Join(downloads, ",") != "ordinary.bin,.partial" || len(staged) != 3 {
		return fmt.Errorf("unexpected native transfers: uploads=%v downloads=%v staged=%d", uploads, downloads, len(staged))
	}
	// Swift has exited, so no process lock can conceal a missing draft reference.
	for i, attachment := range staged {
		_, err := os.Stat(attachment.Path)
		if i != 1 && err != nil {
			return fmt.Errorf("saved native draft or receipt lost its attachment after restart: %w", err)
		}
		if i == 1 && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("abandoned native stage survived its process: %s (%v)", attachment.ID, err)
		}
	}
	if err = runSwift("consume", "PASS native attachment draft restart", "PASS native uncertain attachment receipt released"); err != nil {
		return err
	}
	for _, attachment := range staged {
		if _, err := os.Stat(attachment.Path); !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("consumed native draft left an attachment: %s (%v)", attachment.ID, err)
		}
	}
	fmt.Println("PASS Go/Swift file replay: checked native transfers; process leases; persisted draft ownership across client exit/restart; released draft collection")
	return nil
}
