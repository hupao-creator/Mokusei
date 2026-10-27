// Package attachments owns canonical files and their durable thread ownership.
// Native histories may retain a file independently of the visible transcript.
package attachments

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const (
	MaxBytesImport  = 20 * 1024 * 1024
	MaxMessageBytes = 100 * 1024 * 1024
	MaxMessageCount = 20
)

// IDs returned by staging are canonical lower-case UUIDs. Accepting alternate
// case would bypass the ownership lookup on case-insensitive macOS volumes.
var managedID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Import is the existing public staging request. Bytes uses the transport's
// ArrayBuffer envelope, not a lossy JSON array or caller-supplied file path.
type Import struct {
	// CheckFile fences host-selected files against the descriptor actually read.
	CheckFile   func(os.FileInfo) error `json:"-"`
	Source      string                  `json:"source"`
	Path        string                  `json:"path,omitempty"`
	DisplayName string                  `json:"displayName,omitempty"`
	Bytes       json.RawMessage         `json:"bytes,omitempty"`
}

type manifest struct {
	ID       string `json:"id"`
	Path     string `json:"path"`
	Name     string `json:"name"`
	MimeType string `json:"mimeType"`
	Size     int64  `json:"size"`
	SHA256   string `json:"sha256"`
}

type ownerIndex struct {
	Version int                 `json:"version"`
	Owners  map[string][]string `json:"owners"`
}

type Repository struct {
	root    string
	mu      sync.Mutex
	staging sync.Map
}

func New(root string) *Repository { return &Repository{root: root} }

func (r *Repository) Stage(ctx context.Context, imports []Import) ([]model.Attachment, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(imports) > MaxMessageCount {
		return nil, errors.New("附件数量不能超过 20 个")
	}
	var total int64
	for _, item := range imports {
		n, err := validateImport(item)
		if err != nil {
			return nil, err
		}
		total += n
		if total > MaxMessageBytes {
			return nil, errors.New("附件总大小不能超过 100 MB")
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(r.root, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(r.root, 0700); err != nil {
		return nil, err
	}
	owners, err := r.readOwners()
	if err != nil {
		return nil, err
	}
	// The index exists before any managed directory is created. Its absence in a
	// populated repository is corruption, never authorization to collect files.
	if err = r.writeOwners(owners); err != nil {
		return nil, err
	}
	result := make([]model.Attachment, 0, len(imports))
	cleanup := func() {
		for _, a := range result {
			_ = r.remove(a.ID)
		}
	}
	total = 0
	for _, item := range imports {
		if err = ctx.Err(); err != nil {
			cleanup()
			return nil, err
		}
		a, e := r.stageOne(ctx, item)
		if e != nil {
			cleanup()
			return nil, e
		}
		result = append(result, a)
		total += a.Size
		if total > MaxMessageBytes {
			cleanup()
			return nil, errors.New("附件总大小不能超过 100 MB")
		}
	}
	return result, nil
}

func validateImport(item Import) (int64, error) {
	if len(item.DisplayName) > 4096 {
		return 0, errors.New("附件名称过长")
	}
	switch item.Source {
	case "path":
		if !filepath.IsAbs(item.Path) || strings.ContainsRune(item.Path, 0) || len(item.Bytes) > 0 {
			return 0, errors.New("附件路径无效")
		}
		info, err := os.Stat(item.Path)
		if err != nil {
			return 0, fmt.Errorf("附件不可访问: %w", err)
		}
		if !info.Mode().IsRegular() {
			return 0, errors.New("附件不是普通文件")
		}
		if info.Size() > sizeLimit(MimeTypeForPath(item.Path)) {
			return 0, errors.New("附件过大")
		}
		return info.Size(), nil
	case "bytes":
		if item.Path != "" {
			return 0, errors.New("字节附件不接受路径")
		}
		b, err := decodeBytes(item.Bytes)
		return int64(len(b)), err
	default:
		return 0, errors.New("无效的附件导入来源")
	}
}

func decodeBytes(raw json.RawMessage) ([]byte, error) {
	var envelope struct {
		Data string `json:"$mokuseiArrayBuffer"`
	}
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil, errors.New("附件内容缺失")
	}
	if err := model.Unmarshal(raw, &envelope); err != nil {
		return nil, errors.New("附件内容缺失")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || len(fields) != 1 {
		return nil, errors.New("附件内容缺失")
	}
	if _, ok := fields["$mokuseiArrayBuffer"]; !ok {
		return nil, errors.New("附件内容缺失")
	}
	if len(envelope.Data) > base64.StdEncoding.EncodedLen(MaxBytesImport) {
		return nil, errors.New("无路径的粘贴内容不能超过 20 MB")
	}
	b, err := base64.StdEncoding.Strict().DecodeString(envelope.Data)
	if err != nil {
		return nil, errors.New("附件编码无效")
	}
	if len(b) > MaxBytesImport {
		return nil, errors.New("无路径的粘贴内容不能超过 20 MB")
	}
	return b, nil
}

func (r *Repository) stageOne(ctx context.Context, item Import) (model.Attachment, error) {
	var source io.ReadCloser
	var mime, extension string
	var expectedSize int64
	var original os.FileInfo
	var err error
	if item.Source == "path" {
		var file *os.File
		file, err = os.OpenFile(item.Path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
		if err == nil {
			original, err = file.Stat()
			if err == nil && item.CheckFile != nil {
				err = item.CheckFile(original)
			}
			if err == nil && !original.Mode().IsRegular() {
				err = errors.New("附件不是普通文件")
			}
			if err != nil {
				_ = file.Close()
			} else {
				expectedSize = original.Size()
			}
		}
		source = file
		mime = MimeTypeForPath(item.Path)
		extension = filepath.Ext(item.Path)
	} else {
		var data []byte
		data, err = decodeBytes(item.Bytes)
		mime = sniffMime(data)
		extension = extensionFor(mime)
		expectedSize = int64(len(data))
		source = io.NopCloser(bytes.NewReader(data))
	}
	if err != nil {
		return model.Attachment{}, err
	}
	defer source.Close()
	validate := func() error {
		if original == nil {
			return nil
		}
		current, err := source.(*os.File).Stat()
		if err != nil {
			return err
		}
		if item.CheckFile != nil {
			if err := item.CheckFile(current); err != nil {
				return err
			}
		}
		if !os.SameFile(original, current) || original.Size() != current.Size() || !original.ModTime().Equal(current.ModTime()) {
			return errors.New("附件在导入时发生变化")
		}
		return nil
	}
	return r.stageReader(ctx, item.DisplayName, extension, mime, expectedSize, "", source, validate)
}

// stageReader is the single canonical staging writer for host paths, clipboard
// bytes and local upload streams. No attachment is returned until the complete size,
// checksum and source identity have passed and its manifest is durable.
func (r *Repository) stageReader(ctx context.Context, displayName, extension, mime string, expectedSize int64, expectedHash string,
	source io.Reader, validate func() error) (result model.Attachment, err error) {
	if expectedSize < 0 || expectedSize > sizeLimit(mime) {
		return result, errors.New("附件过大")
	}
	id, err := newID()
	if err != nil {
		return result, err
	}
	r.staging.Store(id, true)
	defer r.staging.Delete(id)
	name := sanitizeName(displayName, extension)
	dir := filepath.Join(r.root, id)
	if err = os.Mkdir(dir, 0700); err != nil {
		return result, err
	}
	defer func() {
		if err != nil {
			_ = r.remove(id)
		}
	}()
	path := filepath.Join(dir, name)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return result, err
	}
	hash := sha256.New()
	n, copyErr := io.CopyBuffer(io.MultiWriter(file, hash), io.LimitReader(contextReader{ctx, source}, expectedSize+1), make([]byte, 64*1024))
	digest := hex.EncodeToString(hash.Sum(nil))
	if copyErr == nil && n != expectedSize {
		copyErr = errors.New("附件传输不完整或大小发生变化")
	}
	if copyErr == nil && expectedHash != "" && digest != expectedHash {
		copyErr = errors.New("附件校验值不匹配")
	}
	if copyErr == nil && validate != nil {
		copyErr = validate()
	}
	if copyErr == nil {
		copyErr = ctx.Err()
	}
	if copyErr == nil {
		copyErr = file.Sync()
	}
	closeErr := file.Close()
	if copyErr != nil {
		return result, copyErr
	}
	if closeErr != nil {
		return result, closeErr
	}
	m := manifest{ID: id, Path: path, Name: name, MimeType: mime, Size: n, SHA256: digest}
	if err = os.MkdirAll(filepath.Join(r.root, ".metadata"), 0700); err != nil {
		return result, err
	}
	if err = atomicJSON(r.manifestPath(id), m); err != nil {
		return result, err
	}
	if err = ctx.Err(); err != nil {
		return result, err
	}
	return attachment(m), nil
}

func (r *Repository) CanonicalizeInput(ctx context.Context, input model.AgentInput) (model.AgentInput, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.canonicalize(ctx, input)
}

func (r *Repository) canonicalize(ctx context.Context, input model.AgentInput) (model.AgentInput, error) {
	if err := validateAnnotations(input); err != nil {
		return model.AgentInput{}, err
	}
	result := input
	result.Parts = make([]model.AgentInputPart, 0, len(input.Parts))
	result.Annotations = bytes.Clone(input.Annotations)
	seen := map[string]bool{}
	var total int64
	for _, part := range input.Parts {
		if err := ctx.Err(); err != nil {
			return model.AgentInput{}, err
		}
		if !isFilePart(part.Kind) {
			result.Parts = append(result.Parts, part)
			continue
		}
		if part.File == nil {
			return model.AgentInput{}, errors.New("附件引用缺失")
		}
		if seen[part.File.ID] {
			return model.AgentInput{}, errors.New("附件重复")
		}
		seen[part.File.ID] = true
		if len(seen) > MaxMessageCount {
			return model.AgentInput{}, errors.New("附件数量不能超过 20 个")
		}
		a, err := r.canonicalFile(ctx, part.File.ID)
		if err != nil {
			return model.AgentInput{}, err
		}
		if part.File.Path != "" && part.File.Path != a.Path {
			return model.AgentInput{}, errors.New("附件路径与 ID 不匹配")
		}
		total += a.Size
		if total > MaxMessageBytes {
			return model.AgentInput{}, errors.New("附件总大小不能超过 100 MB")
		}
		part.File = &model.InputFile{ID: a.ID, Path: a.Path, Name: a.Name, MimeType: a.MimeType, Size: a.Size}
		if strings.HasPrefix(a.MimeType, "image/") {
			part.Kind = "image"
		} else if strings.HasPrefix(a.MimeType, "audio/") {
			part.Kind = "audio"
			part.Detail = ""
		} else {
			part.Kind = "local-file"
			part.Detail = ""
		}
		result.Parts = append(result.Parts, part)
	}
	return result, nil
}

func (r *Repository) RetainInput(ctx context.Context, threadID string, input model.AgentInput) (model.AgentInput, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := validOwner(threadID); err != nil {
		return model.AgentInput{}, err
	}
	canonical, err := r.canonicalize(ctx, input)
	if err != nil {
		return model.AgentInput{}, err
	}
	ids := []string{}
	for _, part := range canonical.Parts {
		if isFilePart(part.Kind) && part.File != nil {
			ids = append(ids, part.File.ID)
		}
	}
	if len(ids) == 0 {
		return canonical, nil
	}
	owners, err := r.readOwners()
	if err != nil {
		return model.AgentInput{}, err
	}
	owners[threadID] = unique(append(owners[threadID], ids...))
	if err = r.writeOwners(owners); err != nil {
		return model.AgentInput{}, err
	}
	return canonical, nil
}

func (r *Repository) RetainOwners(ctx context.Context, threadIDs []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	owners, err := r.readOwners()
	if err != nil {
		return err
	}
	live := map[string]bool{}
	for _, id := range threadIDs {
		if err = validOwner(id); err != nil {
			return err
		}
		live[id] = true
	}
	for id := range owners {
		if !live[id] {
			delete(owners, id)
		}
	}
	return r.writeOwners(owners)
}

func (r *Repository) InheritOwners(ctx context.Context, source, threadID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := validOwner(source); err != nil {
		return err
	}
	if err := validOwner(threadID); err != nil {
		return err
	}
	owners, err := r.readOwners()
	if err != nil {
		return err
	}
	if len(owners[source]) == 0 {
		return nil
	}
	owners[threadID] = unique(append(owners[threadID], owners[source]...))
	return r.writeOwners(owners)
}

func (r *Repository) ReleaseOwner(ctx context.Context, threadID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := validOwner(threadID); err != nil {
		return err
	}
	owners, err := r.readOwners()
	if err != nil {
		return err
	}
	if _, exists := owners[threadID]; !exists {
		return nil
	}
	delete(owners, threadID)
	return r.writeOwners(owners)
}

func (r *Repository) Preview(ctx context.Context, threadID, id string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	owners, err := r.readOwners()
	if err != nil {
		return "", err
	}
	owned := false
	for _, candidate := range owners[threadID] {
		if candidate == id {
			owned = true
			break
		}
	}
	if !owned {
		return "", errors.New("附件不属于此 Thread")
	}
	a, err := r.canonicalFile(ctx, id)
	if err != nil {
		return "", err
	}
	if a.MimeType != "image/png" {
		return "", errors.New("仅支持 PNG 批注截图")
	}
	// Re-open without following a substituted symlink, bound the read, and
	// validate the exact returned bytes against the staged manifest. A prior
	// path/hash check cannot authorize a second unbounded os.ReadFile.
	file, err := os.OpenFile(a.Path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() != a.Size || info.Size() > sizeLimit(a.MimeType) {
		return "", errors.New("附件在预览时发生变化")
	}
	data, err := io.ReadAll(io.LimitReader(contextReader{ctx, file}, sizeLimit(a.MimeType)+1))
	if err != nil {
		return "", err
	}
	if int64(len(data)) != a.Size {
		return "", errors.New("附件在预览时发生变化")
	}
	manifestData, err := os.ReadFile(r.manifestPath(id))
	if err != nil {
		return "", err
	}
	var staged manifest
	if err = model.Unmarshal(manifestData, &staged); err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	if staged.ID != id || staged.Size != int64(len(data)) || staged.SHA256 != hex.EncodeToString(digest[:]) {
		return "", errors.New("附件在预览时发生变化")
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(data), nil
}

func (r *Repository) Discard(ctx context.Context, ids []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, id := range ids {
		if _, active := r.staging.Load(id); active {
			return errors.New("附件仍在导入，请等待导入完成")
		}
		if !managedID.MatchString(id) {
			return errors.New("附件 ID 无效")
		}
	}
	owners, err := r.readOwners()
	if err != nil {
		return err
	}
	live := ownedIDs(owners)
	for _, id := range ids {
		if err = ctx.Err(); err != nil {
			return err
		}
		if !live[id] {
			if err = r.remove(id); err != nil {
				return err
			}
		}
	}
	return nil
}

func (r *Repository) CollectOrphans(ctx context.Context, ttl time.Duration) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if ttl < 0 {
		return errors.New("附件回收 TTL 无效")
	}
	owners, err := r.readOwners()
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(r.root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	live := ownedIDs(owners)
	cutoff := time.Now().Add(-ttl)
	for _, entry := range entries {
		if err = ctx.Err(); err != nil {
			return err
		}
		if !entry.IsDir() || !managedID.MatchString(entry.Name()) || live[entry.Name()] {
			continue
		}
		if _, active := r.staging.Load(entry.Name()); active {
			continue
		}
		info, err := entry.Info()
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !info.ModTime().After(cutoff) {
			if err = r.remove(entry.Name()); err != nil {
				return err
			}
		}
	}
	return nil
}

func (r *Repository) canonicalFile(ctx context.Context, id string) (model.Attachment, error) {
	if !managedID.MatchString(id) {
		return model.Attachment{}, errors.New("附件 ID 无效")
	}
	data, err := os.ReadFile(r.manifestPath(id))
	if err != nil {
		return model.Attachment{}, err
	}
	var m manifest
	if err = model.Unmarshal(data, &m); err != nil {
		return model.Attachment{}, errors.New("附件 staging metadata 无效")
	}
	if m.ID != id || m.Name == "" || filepath.Base(m.Name) != m.Name || !filepath.IsAbs(m.Path) || strings.ContainsRune(m.Path, 0) || m.Size < 0 || m.MimeType == "" || !hashPattern.MatchString(m.SHA256) {
		return model.Attachment{}, errors.New("附件 staging metadata 无效")
	}
	root, err := filepath.EvalSymlinks(r.root)
	if err != nil {
		return model.Attachment{}, err
	}
	entry, err := os.Lstat(filepath.Join(r.root, id))
	if err != nil {
		return model.Attachment{}, err
	}
	if !entry.IsDir() || entry.Mode()&os.ModeSymlink != 0 {
		return model.Attachment{}, errors.New("附件目录已被替换")
	}
	info, err := os.Lstat(m.Path)
	if err != nil {
		return model.Attachment{}, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return model.Attachment{}, errors.New("附件不是普通文件")
	}
	path, err := filepath.EvalSymlinks(m.Path)
	if err != nil {
		return model.Attachment{}, err
	}
	if path != filepath.Join(root, id, m.Name) {
		return model.Attachment{}, errors.New("附件不属于 Attachment repository")
	}
	if info.Size() != m.Size {
		return model.Attachment{}, errors.New("附件在 staging 后已被替换")
	}
	file, err := os.Open(path)
	if err != nil {
		return model.Attachment{}, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return model.Attachment{}, err
	}
	if !os.SameFile(info, opened) {
		return model.Attachment{}, errors.New("附件在 staging 后已被替换")
	}
	mime := MimeTypeForPath(m.Name)
	if mime == "application/octet-stream" {
		mime = m.MimeType
	}
	if m.Size > sizeLimit(mime) {
		return model.Attachment{}, errors.New("附件过大")
	}
	hash := sha256.New()
	n, err := io.Copy(hash, io.LimitReader(contextReader{ctx, file}, sizeLimit(mime)+1))
	if err != nil {
		return model.Attachment{}, err
	}
	if n != m.Size || hex.EncodeToString(hash.Sum(nil)) != m.SHA256 {
		return model.Attachment{}, errors.New("附件在 staging 后已被替换")
	}
	m.Path = path
	m.MimeType = mime
	return attachment(m), nil
}

func (r *Repository) readOwners() (map[string][]string, error) {
	data, err := os.ReadFile(filepath.Join(r.root, ".owners.json"))
	if errors.Is(err, os.ErrNotExist) {
		entries, e := os.ReadDir(r.root)
		if e != nil && !errors.Is(e, os.ErrNotExist) {
			return nil, e
		}
		for _, entry := range entries {
			if managedID.MatchString(entry.Name()) {
				return nil, errors.New("Attachment owner index 缺失；停止回收以保留附件")
			}
		}
		return map[string][]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	var index ownerIndex
	if err = model.Unmarshal(data, &index); err != nil || index.Version != 1 || index.Owners == nil {
		return nil, errors.New("Attachment owner index 不符合当前格式")
	}
	for id, entries := range index.Owners {
		if err = validOwner(id); err != nil {
			return nil, err
		}
		if entries == nil {
			return nil, errors.New("Attachment owner index 包含无效附件列表")
		}
		for _, entry := range entries {
			if !managedID.MatchString(entry) {
				return nil, errors.New("Attachment owner index 包含无效附件 ID")
			}
		}
	}
	return index.Owners, nil
}

func (r *Repository) writeOwners(owners map[string][]string) error {
	if err := os.MkdirAll(r.root, 0700); err != nil {
		return err
	}
	return atomicJSON(filepath.Join(r.root, ".owners.json"), ownerIndex{Version: 1, Owners: owners})
}
func (r *Repository) manifestPath(id string) string {
	return filepath.Join(r.root, ".metadata", id+".json")
}
func (r *Repository) remove(id string) error {
	if !managedID.MatchString(id) {
		return errors.New("附件 ID 无效")
	}
	if err := os.RemoveAll(filepath.Join(r.root, id)); err != nil {
		return err
	}
	err := os.Remove(r.manifestPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
func attachment(m manifest) model.Attachment {
	return model.Attachment{ID: m.ID, Path: m.Path, Name: m.Name, MimeType: m.MimeType, Size: m.Size, Kind: KindForMimeType(m.MimeType)}
}
func ownedIDs(owners map[string][]string) map[string]bool {
	live := map[string]bool{}
	for _, ids := range owners {
		for _, id := range ids {
			live[id] = true
		}
	}
	return live
}
func unique(ids []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}
func validOwner(id string) error {
	if id == "" || len(id) > 128 || id == "__proto__" || id == "constructor" || id == "prototype" || strings.ContainsFunc(id, func(r rune) bool { return r == 0 || unicode.IsSpace(r) }) {
		return errors.New("Attachment owner Thread ID 无效")
	}
	return nil
}
func isFilePart(kind string) bool { return kind == "image" || kind == "audio" || kind == "local-file" }
func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r contextReader) Read(b []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(b)
}
func atomicJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".mokusei-*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(tmp, path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
