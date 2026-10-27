package transport

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// FileHost keeps filesystem authority and attachment staging in Runtime. This
// optional capability does not expand the generic command bridge or WebKit.
type FileHost interface {
	FilePolicy(context.Context) (model.AttachmentPolicy, error)
	BrowseFiles(context.Context, *model.HostFileReference) (model.HostDirectory, error)
	StageHostFiles(context.Context, []model.HostFileReference) ([]model.Attachment, error)
	UploadAttachment(context.Context, string, int64, string, io.Reader) (model.Attachment, error)
	DownloadFile(context.Context, model.HostFileReference) (*FileDownload, error)
}

type FileDownload struct {
	Reader   io.ReadCloser
	Name     string
	MimeType string
	Size     int64
	SHA256   string
}

func (s *Server) fileHostID() string {
	return "local:" + s.Connection.Epoch
}

func (s *Server) serveFiles(w http.ResponseWriter, r *http.Request) bool {
	if !strings.HasPrefix(r.URL.Path, "/files/") {
		return false
	}
	host, ok := s.host.(FileHost)
	if !ok {
		s.send(w, 404, resultFailure(model.NewError("UNAVAILABLE", "Host file capability is unavailable")))
		return true
	}
	s.mu.Lock()
	if s.activeRequests >= maxActiveRequests {
		s.mu.Unlock()
		s.send(w, 503, resultFailure(model.NewError("CAPACITY_EXHAUSTED", "Runtime request capacity reached")))
		return true
	}
	s.activeRequests++
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.activeRequests--; s.mu.Unlock(); r.Body.Close() }()
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	abortIO := func() {
		controller := http.NewResponseController(w)
		_ = controller.SetReadDeadline(time.Now())
		_ = controller.SetWriteDeadline(time.Now())
		_ = r.Body.Close()
	}
	finish, accepted := s.fileWorkers.begin(cancel)
	if !accepted {
		s.send(w, 503, resultFailure(model.NewError("SERVICE_STOPPING", "Runtime is stopping")))
		return true
	}
	defer finish()
	abortedIO := make(chan struct{})
	stopIO := context.AfterFunc(ctx, func() { abortIO(); close(abortedIO) })
	defer func() {
		if !stopIO() {
			<-abortedIO
		}
	}()
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(10 * time.Minute))
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(10 * time.Minute))
	owner := s.fileHostID()
	check := func(ref model.HostFileReference) error {
		if ref.HostID != owner {
			return model.NewError("WRONG_HOST", "File reference belongs to another host")
		}
		return nil
	}
	var value any
	var err error
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/files/policy":
		value, err = host.FilePolicy(ctx)
	case r.Method == http.MethodPost && r.URL.Path == "/files/browse":
		var request struct {
			Reference *model.HostFileReference `json:"reference"`
		}
		err = readFileRequest(r, &request)
		if err == nil && request.Reference != nil {
			err = check(*request.Reference)
		}
		if err == nil {
			var directory model.HostDirectory
			directory, err = host.BrowseFiles(ctx, request.Reference)
			directory.Reference.HostID = owner
			if directory.Parent != nil {
				directory.Parent.HostID = owner
			}
			for i := range directory.Entries {
				directory.Entries[i].Reference.HostID = owner
			}
			value = directory
		}
	case r.Method == http.MethodPost && r.URL.Path == "/files/stage-host":
		var request struct {
			References []model.HostFileReference `json:"references"`
		}
		err = readFileRequest(r, &request)
		if err == nil {
			for _, ref := range request.References {
				if err = check(ref); err != nil {
					break
				}
			}
		}
		if err == nil {
			value, err = host.StageHostFiles(ctx, request.References)
		}
	case r.Method == http.MethodPost && r.URL.Path == "/files/upload":
		var name []byte
		name, err = base64.RawURLEncoding.DecodeString(r.Header.Get("X-Mokusei-File-Name"))
		if err == nil && (len(name) == 0 || len(name) > 4096 || r.ContentLength < 0 || r.ContentLength > 50*1024*1024) {
			err = model.NewError("INVALID_FILE", "Upload requires a bounded name and exact Content-Length")
		}
		if err == nil {
			value, err = host.UploadAttachment(ctx, string(name), r.ContentLength, r.Header.Get("X-Mokusei-SHA256"), io.LimitReader(r.Body, r.ContentLength+1))
		}
	case r.Method == http.MethodPost && r.URL.Path == "/files/download":
		var request struct {
			Reference model.HostFileReference `json:"reference"`
		}
		err = readFileRequest(r, &request)
		if err == nil {
			err = check(request.Reference)
		}
		if err == nil {
			var download *FileDownload
			download, err = host.DownloadFile(ctx, request.Reference)
			if err == nil {
				defer download.Reader.Close()
				w.Header().Set("Content-Type", download.MimeType)
				w.Header().Set("Content-Length", strconv.FormatInt(download.Size, 10))
				w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(download.Name))
				w.Header().Set("X-Mokusei-File-Name", base64.RawURLEncoding.EncodeToString([]byte(download.Name)))
				w.Header().Set("X-Mokusei-SHA256", download.SHA256)
				w.Header().Set("Cache-Control", "no-store")
				w.Header().Set("X-Content-Type-Options", "nosniff")
				w.WriteHeader(200)
				// The client verifies exact length and digest before promoting its
				// private partial file to a successful preview/export.
				_, _ = io.CopyBuffer(w, download.Reader, make([]byte, 64*1024))
				return true
			}
		}
	default:
		err = model.NewError("UNKNOWN_COMMAND", "Unknown host file operation")
	}
	if err != nil {
		s.send(w, 400, resultFailure(err))
	} else {
		s.send(w, 200, resultSuccess(value))
	}
	return true
}

func readFileRequest(r *http.Request, target any) error {
	if r.ContentLength > 64*1024 {
		return errors.New("File request metadata exceeds limit")
	}
	decoder := json.NewDecoder(io.LimitReader(r.Body, 64*1024+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return fmt.Errorf("File request has trailing data")
	}
	return nil
}

// File writes are lifecycle participants even though they bypass command JSON.
// Closing admission aborts stalled socket I/O before the profile can be released.
type fileWorker struct {
	mu        sync.Mutex
	completed bool
	abort     func()
}

func (w *fileWorker) stop() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.completed {
		w.abort()
	}
}

type fileWorkers struct {
	mu     sync.Mutex
	closed bool
	active map[*fileWorker]struct{}
	done   chan struct{}
}

func (f *fileWorkers) begin(abort func()) (func(), bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil, false
	}
	if f.active == nil {
		f.active = map[*fileWorker]struct{}{}
	}
	if f.done == nil {
		f.done = make(chan struct{})
	}
	worker := &fileWorker{abort: abort}
	f.active[worker] = struct{}{}
	var once sync.Once
	return func() {
		once.Do(func() {
			worker.mu.Lock()
			worker.completed = true
			worker.mu.Unlock()
			f.mu.Lock()
			defer f.mu.Unlock()
			delete(f.active, worker)
			if f.closed && len(f.active) == 0 {
				close(f.done)
				f.done = nil
			}
		})
	}, true
}
func (f *fileWorkers) close() {
	f.mu.Lock()
	if f.closed {
		f.mu.Unlock()
		return
	}
	f.closed = true
	workers := make([]*fileWorker, 0, len(f.active))
	for worker := range f.active {
		workers = append(workers, worker)
	}
	if len(workers) == 0 && f.done != nil {
		close(f.done)
		f.done = nil
	}
	f.mu.Unlock()
	for _, worker := range workers {
		worker.stop()
	}
}
func (f *fileWorkers) wait(ctx context.Context) error {
	f.mu.Lock()
	if len(f.active) == 0 {
		f.mu.Unlock()
		return nil
	}
	done := f.done
	f.mu.Unlock()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
