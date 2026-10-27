// Package localembedding runs a pinned, text-only EmbeddingGemma 2 model on
// the user's machine. Only an explicit Download action accesses the internet.
package localembedding

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

const Model = "google/embeddinggemma-2"
const Revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"
const Engine = "llama.cpp-b11748"
const Space = plugin.LocalEmbeddingSpace

// Assets is a transport/file fixture seam; composition always uses pinnedAssets.
// Product commands cannot supply paths, endpoints, checksums or executable code.
type Asset struct {
	URL, SHA256 string
	Bytes       int64
}
type Assets struct{ Model, Runtime Asset }

func pinnedAssets() Assets {
	a := Assets{Model: Asset{
		URL:    "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/" + Revision + "/embeddinggemma-2-Q8_0.gguf",
		SHA256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135", Bytes: 309855456}}
	if runtime.GOOS != "darwin" {
		return a
	}
	switch runtime.GOARCH {
	case "arm64":
		a.Runtime = Asset{URL: "https://github.com/ggml-org/llama.cpp/releases/download/b11748/llama-b11748-bin-macos-arm64.tar.gz", SHA256: "003af1321ed9be9485902a2e17aad0c874a456c10f0a4ece5a735c495f3a3afb", Bytes: 16103472}
	case "amd64":
		a.Runtime = Asset{URL: "https://github.com/ggml-org/llama.cpp/releases/download/b11748/llama-b11748-bin-macos-x64.tar.gz", SHA256: "fa10a8f9fbab806c8e4423ea8848ec317ed601d2bc009a45880a509e69f372f0", Bytes: 11809415}
	}
	return a
}

type entry struct {
	Path, Hash string
	Bytes      int64
}
type manifest struct {
	Space, ArchiveHash, Executable string
	Files                          []entry
}

func digest(ctx context.Context, path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	var total int64
	buf := make([]byte, 1<<20)
	for {
		if err = ctx.Err(); err != nil {
			return "", total, err
		}
		n, e := f.Read(buf)
		h.Write(buf[:n])
		total += int64(n)
		if e == io.EOF {
			break
		}
		if e != nil {
			return "", total, e
		}
	}
	return hex.EncodeToString(h.Sum(nil)), total, nil
}
func (p *Provider) verify(ctx context.Context) bool {
	p.filesMu.Lock()
	defer p.filesMu.Unlock()
	if p.verified {
		model, modelErr := os.Stat(filepath.Join(p.directory, "text.gguf"))
		executable, engineErr := os.Stat(p.executable)
		if modelErr == nil && model.Mode().IsRegular() && model.Size() == p.assets.Model.Bytes && engineErr == nil && executable.Mode().IsRegular() && executable.Mode()&0111 != 0 {
			return true
		}
		p.verified = false
	}
	raw, err := os.ReadFile(filepath.Join(p.directory, "ready.json"))
	if err != nil {
		return false
	}
	var m manifest
	if json.Unmarshal(raw, &m) != nil || m.Space != Space || m.ArchiveHash != p.assets.Runtime.SHA256 || len(m.Files) == 0 || !safePath(m.Executable) {
		return false
	}
	hash, size, err := digest(ctx, filepath.Join(p.directory, "text.gguf"))
	if err != nil || hash != p.assets.Model.SHA256 || size != p.assets.Model.Bytes {
		return false
	}
	for _, f := range m.Files {
		if !safePath(f.Path) {
			return false
		}
		hash, size, err = digest(ctx, filepath.Join(p.directory, "engine", f.Path))
		if err != nil || hash != f.Hash || size != f.Bytes {
			return false
		}
	}
	executable := filepath.Join(p.directory, "engine", m.Executable)
	info, err := os.Stat(executable)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
		return false
	}
	p.executable = executable
	p.verified = true
	return true
}
func safePath(path string) bool {
	return path != "" && path != "." && !filepath.IsAbs(path) && filepath.Clean(path) == path && path != ".." && !strings.HasPrefix(path, ".."+string(filepath.Separator))
}
func (p *Provider) fetch(ctx context.Context, asset Asset, path string) error {
	req, err := http.NewRequestWithContext(ctx, "GET", asset.URL, nil)
	if err != nil {
		return err
	}
	response, err := p.downloadHTTP.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return errors.New("download unavailable")
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	writer := io.MultiWriter(f, h)
	data := make([]byte, 128*1024)
	var total int64
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		n, e := response.Body.Read(data)
		total += int64(n)
		if total > asset.Bytes {
			return errors.New("download exceeds pinned size")
		}
		if _, err = writer.Write(data[:n]); err != nil {
			return err
		}
		p.mu.Lock()
		p.setup.DownloadedBytes += int64(n)
		p.mu.Unlock()
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
	}
	if total != asset.Bytes || hex.EncodeToString(h.Sum(nil)) != asset.SHA256 {
		return errors.New("download integrity mismatch")
	}
	return f.Sync()
}
func extract(archive, directory string) (manifest, error) {
	f, err := os.Open(archive)
	if err != nil {
		return manifest{}, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return manifest{}, err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	m := manifest{Space: Space}
	var total int64
	links := map[string]string{}
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return m, e
		}
		path := filepath.Clean(strings.TrimSuffix(h.Name, "/"))
		if path == "." {
			continue
		}
		if !safePath(path) {
			return m, errors.New("unsafe runtime archive")
		}
		target := filepath.Join(directory, path)
		switch h.Typeflag {
		case tar.TypeDir:
			if err = os.MkdirAll(target, 0700); err != nil {
				return m, err
			}
		case tar.TypeSymlink:
			link := filepath.Clean(filepath.Join(filepath.Dir(path), h.Linkname))
			if filepath.IsAbs(h.Linkname) || !safePath(link) {
				return m, errors.New("unsafe runtime link")
			}
			links[path] = link
		case tar.TypeReg, tar.TypeRegA:
			total += h.Size
			if h.Size < 0 || total > 150<<20 || len(m.Files) > 2000 {
				return m, errors.New("runtime archive limit")
			}
			if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
				return m, err
			}
			out, e := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if e != nil {
				return m, e
			}
			hasher := sha256.New()
			n, e := io.Copy(io.MultiWriter(out, hasher), tr)
			closeErr := out.Close()
			if e != nil {
				return m, e
			}
			if closeErr != nil {
				return m, closeErr
			}
			if n != h.Size {
				return m, io.ErrUnexpectedEOF
			}
			mode := os.FileMode(0600)
			if h.Mode&0111 != 0 {
				mode = 0700
			}
			if err = os.Chmod(target, mode); err != nil {
				return m, err
			}
			m.Files = append(m.Files, entry{Path: path, Hash: hex.EncodeToString(hasher.Sum(nil)), Bytes: n})
			if filepath.Base(path) == "llama-server" {
				if m.Executable != "" {
					return m, errors.New("ambiguous runtime")
				}
				m.Executable = path
			}
		default:
			return m, errors.New("unsupported runtime archive entry")
		}
	}
	// Materialize file aliases after regular files, avoiding symlink traversal.
	// Official macOS archives use versioned dylib aliases.
	for pass := 0; len(links) > 0 && pass < 16; pass++ {
		for path, target := range links {
			info, e := os.Stat(filepath.Join(directory, target))
			if e != nil || !info.Mode().IsRegular() {
				continue
			}
			total += info.Size()
			if total > 150<<20 || len(m.Files) > 2000 {
				return m, errors.New("runtime archive alias limit")
			}
			from, e := os.Open(filepath.Join(directory, target))
			if e != nil {
				return m, e
			}
			if e = os.MkdirAll(filepath.Dir(filepath.Join(directory, path)), 0700); e != nil {
				from.Close()
				return m, e
			}
			out, e := os.OpenFile(filepath.Join(directory, path), os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
			if e != nil {
				from.Close()
				return m, e
			}
			hasher := sha256.New()
			n, e := io.Copy(io.MultiWriter(out, hasher), from)
			from.Close()
			closeErr := out.Close()
			if e != nil {
				return m, e
			}
			if closeErr != nil {
				return m, closeErr
			}
			m.Files = append(m.Files, entry{Path: path, Hash: hex.EncodeToString(hasher.Sum(nil)), Bytes: n})
			delete(links, path)
		}
	}
	if len(links) > 0 || m.Executable == "" {
		return m, errors.New("runtime executable missing")
	}
	return m, nil
}
func (p *Provider) install(ctx context.Context) error {
	if err := os.MkdirAll(p.directory, 0700); err != nil {
		return err
	}
	// A killed runtime cannot run deferred cleanup. Reclaim only our own staged
	// directories on the next explicit download, never on a search/status call.
	leftovers, err := os.ReadDir(p.directory)
	if err != nil {
		return err
	}
	for _, item := range leftovers {
		if item.IsDir() && strings.HasPrefix(item.Name(), "install-") {
			if err = os.RemoveAll(filepath.Join(p.directory, item.Name())); err != nil {
				return err
			}
		}
	}
	stage, err := os.MkdirTemp(p.directory, "install-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	if err = p.fetch(ctx, p.assets.Runtime, filepath.Join(stage, "runtime.tar.gz")); err != nil {
		return err
	}
	m, err := extract(filepath.Join(stage, "runtime.tar.gz"), filepath.Join(stage, "engine"))
	if err != nil {
		return err
	}
	m.ArchiveHash = p.assets.Runtime.SHA256
	if err = p.fetch(ctx, p.assets.Model, filepath.Join(stage, "text.gguf")); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	raw, _ := json.Marshal(m)
	if err = os.WriteFile(filepath.Join(stage, "ready.json"), raw, 0600); err != nil {
		return err
	}
	// Wait for active inference before replacing files. Cancellation while waiting
	// must leave the existing installation intact. Manifest is committed last.
	p.runMu.Lock()
	defer p.runMu.Unlock()
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = p.stop(); err != nil {
		return err
	}
	p.filesMu.Lock()
	defer p.filesMu.Unlock()
	if err = ctx.Err(); err != nil {
		return err
	}
	p.verified = false
	os.Remove(filepath.Join(p.directory, "ready.json"))
	if err = os.RemoveAll(filepath.Join(p.directory, "engine")); err != nil {
		return err
	}
	for _, name := range []string{"engine", "text.gguf", "ready.json"} {
		if err = os.Rename(filepath.Join(stage, name), filepath.Join(p.directory, name)); err != nil {
			return err
		}
	}
	return nil
}

func downloadClient() *http.Client {
	return &http.Client{Timeout: 30 * time.Minute, CheckRedirect: func(r *http.Request, via []*http.Request) error {
		if len(via) > 5 || r.URL.Scheme != "https" || r.URL.User != nil || r.URL.Port() != "" && r.URL.Port() != "443" {
			return errors.New("download redirect refused")
		}
		host := strings.ToLower(r.URL.Hostname())
		for _, domain := range []string{"github.com", "githubusercontent.com", "huggingface.co", "hf.co"} {
			if host == domain || strings.HasSuffix(host, "."+domain) {
				return nil
			}
		}
		return errors.New("download host refused")
	}}
}
