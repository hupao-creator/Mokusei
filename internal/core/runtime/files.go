package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
)

func (r *Runtime) FilePolicy(ctx context.Context) (model.AttachmentPolicy, error) {
	return attachments.Policy(), ctx.Err()
}

func hostPath(ref model.HostFileReference) (string, error) {
	if !filepath.IsAbs(ref.Path) || strings.ContainsRune(ref.Path, 0) || len(ref.Path) > 32*1024 {
		return "", errors.New("Invalid host file path")
	}
	return filepath.Clean(ref.Path), nil
}

func fileRevision(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	changed := ""
	value := reflect.ValueOf(stat).Elem()
	for _, field := range []string{"Ctimespec", "Ctim", "Birthtimespec"} {
		if current := value.FieldByName(field); current.IsValid() {
			changed += fmt.Sprint(current.Interface())
		}
	}
	identity := fmt.Sprintf("%d:%d:%d:%d:%d:%s", stat.Dev, stat.Ino, info.Size(), info.ModTime().UnixNano(), info.Mode(), changed)
	digest := sha256.Sum256([]byte(identity))
	return hex.EncodeToString(digest[:])
}

func (r *Runtime) BrowseFiles(ctx context.Context, reference *model.HostFileReference) (model.HostDirectory, error) {
	path := r.config.DefaultCwd
	var err error
	if reference != nil {
		path, err = hostPath(*reference)
	}
	if err != nil {
		return model.HostDirectory{}, err
	}
	if path == "" {
		path, err = os.UserHomeDir()
	}
	if err != nil {
		return model.HostDirectory{}, err
	}
	// Resolve the requested directory once. Entries expose the target's host
	// path, so a later symlink retarget cannot change a selected reference.
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return model.HostDirectory{}, err
	}
	directory, err := os.Open(path)
	if err != nil {
		return model.HostDirectory{}, err
	}
	defer directory.Close()
	info, err := directory.Stat()
	if err != nil || !info.IsDir() {
		return model.HostDirectory{}, errors.New("Host path is not a directory")
	}
	result := model.HostDirectory{Reference: model.HostFileReference{Path: path}, Entries: []model.HostFileEntry{}}
	if parent := filepath.Dir(path); parent != path {
		result.Parent = &model.HostFileReference{Path: parent}
	}
	// Directory listings are bounded; callers can navigate directly to a known
	// path rather than receiving an unbounded home directory tree.
	entries, err := directory.ReadDir(10001)
	if err != nil && err != io.EOF {
		return result, err
	}
	if len(entries) > 10000 {
		return result, errors.New("Directory contains more than 10000 entries; choose a narrower path")
	}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		name := entry.Name()
		entryPath := filepath.Join(path, name)
		if entry.Type()&os.ModeSymlink != 0 {
			entryPath, err = filepath.EvalSymlinks(entryPath)
			if err != nil {
				continue
			}
		}
		info, err := os.Stat(entryPath)
		if err != nil || (!info.IsDir() && !info.Mode().IsRegular()) {
			continue
		}
		revision := ""
		if !info.IsDir() {
			revision = fileRevision(info)
		}
		result.Entries = append(result.Entries, model.HostFileEntry{Reference: model.HostFileReference{Path: entryPath, Revision: revision},
			Name: name, IsDirectory: info.IsDir(), Size: info.Size(), MimeType: attachments.MimeTypeForPath(entryPath)})
	}
	sort.Slice(result.Entries, func(i, j int) bool {
		if result.Entries[i].IsDirectory != result.Entries[j].IsDirectory {
			return result.Entries[i].IsDirectory
		}
		return result.Entries[i].Name < result.Entries[j].Name
	})
	return result, nil
}

func openHostFile(reference model.HostFileReference) (*os.File, os.FileInfo, error) {
	path, err := hostPath(reference)
	if err != nil {
		return nil, nil, err
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, nil, err
	}
	info, err := file.Stat()
	if err == nil && !info.Mode().IsRegular() {
		err = errors.New("Host path is not a regular file")
	}
	if err == nil && reference.Revision != "" && reference.Revision != fileRevision(info) {
		err = model.NewError("FILE_CHANGED", "Host file changed after selection; select it again")
	}
	if err != nil {
		file.Close()
		return nil, nil, err
	}
	return file, info, nil
}

func (r *Runtime) StageHostFiles(ctx context.Context, references []model.HostFileReference) ([]model.Attachment, error) {
	if r.config.Attachments == nil {
		return nil, errors.New("Attachment repository unavailable")
	}
	if len(references) > attachments.MaxMessageCount {
		return nil, errors.New("附件数量不能超过 20 个")
	}
	imports := make([]attachments.Import, 0, len(references))
	for _, ref := range references {
		file, info, err := openHostFile(ref)
		if err != nil {
			return nil, err
		}
		file.Close()
		imports = append(imports, attachments.Import{Source: "path", Path: ref.Path, DisplayName: info.Name(), CheckFile: func(opened os.FileInfo) error {
			if fileRevision(opened) != fileRevision(info) {
				return model.NewError("FILE_CHANGED", "Host file changed after selection; select it again")
			}
			return nil
		}})
	}
	// Stage reopens with its own descriptor identity/size checks. Check the
	// caller's revision again afterward to close replacement during staging.
	result, err := r.config.Attachments.Stage(ctx, imports)
	if err != nil {
		return nil, err
	}
	for _, ref := range references {
		file, _, e := openHostFile(ref)
		if e == nil {
			file.Close()
		} else {
			ids := make([]string, 0, len(result))
			for _, item := range result {
				ids = append(ids, item.ID)
			}
			_ = r.config.Attachments.Discard(context.WithoutCancel(ctx), ids)
			return nil, e
		}
	}
	return result, nil
}

func (r *Runtime) UploadAttachment(ctx context.Context, name string, size int64, digest string, source io.Reader) (model.Attachment, error) {
	store, ok := r.config.Attachments.(interface {
		StageStream(context.Context, string, int64, string, io.Reader) (model.Attachment, error)
	})
	if !ok {
		return model.Attachment{}, errors.New("Attachment streaming is unavailable")
	}
	return store.StageStream(ctx, name, size, digest, source)
}

func (r *Runtime) DownloadFile(ctx context.Context, reference model.HostFileReference) (*transport.FileDownload, error) {
	file, original, err := openHostFile(reference)
	if err != nil {
		return nil, err
	}
	failed := true
	defer func() {
		if failed {
			file.Close()
		}
	}()
	hash := sha256.New()
	n, err := io.CopyBuffer(hash, io.LimitReader(fileContextReader{ctx, file}, original.Size()+1), make([]byte, 64*1024))
	if err != nil {
		return nil, err
	}
	current, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if n != original.Size() || fileRevision(current) != fileRevision(original) {
		return nil, model.NewError("FILE_CHANGED", "Host file changed while preparing the download")
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	failed = false
	return &transport.FileDownload{Reader: &fileDownloadReader{ctx: ctx, file: file, size: original.Size(), revision: fileRevision(original)}, Name: original.Name(),
		MimeType: attachments.MimeTypeForPath(reference.Path), Size: original.Size(), SHA256: hex.EncodeToString(hash.Sum(nil))}, nil
}

type fileContextReader struct {
	ctx    context.Context
	source io.Reader
}

func (r fileContextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(p)
}

type fileDownloadReader struct {
	ctx      context.Context
	file     *os.File
	size     int64
	read     int64
	revision string
}

func (r *fileDownloadReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if r.read >= r.size {
		return 0, io.EOF
	}
	if int64(len(p)) > r.size-r.read {
		p = p[:r.size-r.read]
	}
	n, err := r.file.Read(p)
	if r.read+int64(n) == r.size {
		current, statErr := r.file.Stat()
		if statErr != nil {
			return 0, statErr
		}
		if fileRevision(current) != r.revision {
			return 0, model.NewError("FILE_CHANGED", "Host file changed during download")
		}
	}
	r.read += int64(n)
	return n, err
}
func (r *fileDownloadReader) Close() error { return r.file.Close() }
