package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type fileReplayHost struct {
	*mockHost
	entered, exited chan struct{}
}

func (*fileReplayHost) FilePolicy(context.Context) (model.AttachmentPolicy, error) {
	return model.AttachmentPolicy{}, nil
}
func (*fileReplayHost) BrowseFiles(context.Context, *model.HostFileReference) (model.HostDirectory, error) {
	return model.HostDirectory{}, errors.New("unused")
}
func (*fileReplayHost) StageHostFiles(context.Context, []model.HostFileReference) ([]model.Attachment, error) {
	return nil, errors.New("unused")
}
func (*fileReplayHost) DownloadFile(context.Context, model.HostFileReference) (*transport.FileDownload, error) {
	return nil, errors.New("unused")
}
func (h *fileReplayHost) UploadAttachment(ctx context.Context, _ string, _ int64, _ string, source io.Reader) (model.Attachment, error) {
	close(h.entered)
	defer close(h.exited)
	_, err := io.Copy(io.Discard, source)
	return model.Attachment{}, errors.Join(err, ctx.Err())
}

func verifyFileWorkerShutdown(ctx context.Context, directory string) {
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, "file-workers"), HomeDir: directory})
	must(err)
	host := &fileReplayHost{mockHost: newMockHost(), entered: make(chan struct{}), exited: make(chan struct{})}
	server, err := transport.Start(transport.Options{Profile: p, Epoch: "file-workers", Host: host})
	must(err)
	defer server.Close(context.Background())
	socket, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", server.Connection.Port))
	must(err)
	defer socket.Close()
	_, err = fmt.Fprintf(socket, "POST /files/upload HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer %s\r\nX-Mokusei-Epoch: %s\r\nX-Mokusei-Protocol: %d\r\nX-Mokusei-File-Name: %s\r\nX-Mokusei-SHA256: %s\r\nContent-Length: 52428800\r\n\r\nstalled-upload", server.Connection.Token, server.Connection.Epoch, server.Connection.ProtocolVersion, base64.RawURLEncoding.EncodeToString([]byte("stall.bin")), strings.Repeat("0", 64))
	must(err)
	select {
	case <-host.entered:
	case <-ctx.Done():
		panic("file worker did not enter")
	}
	server.Revoke()
	drain, stop := context.WithTimeout(ctx, 2*time.Second)
	defer stop()
	must(server.Drain(drain))
	select {
	case <-host.exited:
	default:
		panic("profile could be released before file writer exited")
	}
	must(server.Close(drain))
	must(server.Close(drain))
	must(server.Finish(drain))
	fmt.Println("PASS file transport shutdown: stalled upload body aborted and worker joined before profile release; repeated close")
}
