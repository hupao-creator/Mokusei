package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
)

const aliasLibraryContents = "synthetic shared library bytes"

// Alias headers precede their targets, as allowed by the external tar format.
// The real downloader/extractor owns ordering, copying and integrity metadata.
func aliasArchive(t *testing.T, links ...tar.Header) []byte {
	t.Helper()
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	tw := tar.NewWriter(gz)
	for _, link := range links {
		link.Typeflag = tar.TypeSymlink
		if err := tw.WriteHeader(&link); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []struct {
		name, data string
		mode       int64
	}{
		{"fixture/llama-server", "#!/bin/sh\nexit 1\n", 0700},
		{"fixture/libsample.1.dylib", aliasLibraryContents, 0600},
	} {
		if err := tw.WriteHeader(&tar.Header{Name: file.name, Mode: file.mode, Size: int64(len(file.data))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(file.data)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func aliasProviders(t *testing.T, engine []byte) (string, func() *localembedding.Provider, *atomic.Int64) {
	t.Helper()
	model := []byte("synthetic model; never used for inference")
	var downloads atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		downloads.Add(1)
		switch r.URL.Path {
		case "/engine":
			_, _ = w.Write(engine)
		case "/model":
			_, _ = w.Write(model)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	directory := t.TempDir()
	assets := localembedding.Assets{Runtime: asset(server.URL+"/engine", engine), Model: asset(server.URL+"/model", model)}
	return directory, func() *localembedding.Provider {
		p := localembedding.New(localembedding.Options{Directory: directory, Assets: &assets, DownloadHTTP: server.Client()})
		t.Cleanup(func() {
			if err := p.Close(); err != nil {
				t.Error(err)
			}
		})
		return p
	}, &downloads
}

func TestRuntimeArchiveAliasesSurviveReopenAndDetectCorruption(t *testing.T) {
	engine := aliasArchive(t,
		tar.Header{Name: "fixture/libsample.dylib", Linkname: "libsample.current.dylib"},
		tar.Header{Name: "fixture/libsample.current.dylib", Linkname: "libsample.1.dylib"})
	directory, freshProvider, downloads := aliasProviders(t, engine)
	p := freshProvider()
	install(p)
	var alias string
	for _, name := range []string{"libsample.dylib", "libsample.current.dylib"} {
		var found []string
		// Inspect only this test's installation, without depending on the
		// provider's private cache-directory or manifest layout.
		err := filepath.WalkDir(directory, func(path string, entry fs.DirEntry, err error) error {
			if err == nil && entry.Name() == name {
				found = append(found, path)
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(found) != 1 {
			t.Fatalf("installed alias %s must exist exactly once; got %v", name, found)
		}
		data, err := os.ReadFile(found[0])
		if err != nil || string(data) != aliasLibraryContents {
			t.Fatalf("installed alias %s lost target bytes: %q, %v", name, data, err)
		}
		alias = found[0]
	}
	if err := p.Close(); err != nil {
		t.Fatal(err)
	}
	before := downloads.Load()
	reopened := freshProvider()
	if !reopened.Available(t.Context()) {
		t.Fatal("intact alias installation must remain ready after reopen")
	}
	if err := reopened.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(alias, []byte(strings.Repeat("x", len(aliasLibraryContents))), 0600); err != nil {
		t.Fatal(err)
	}
	if freshProvider().Available(t.Context()) {
		t.Fatal("same-length installed alias corruption must invalidate readiness after reopen")
	}
	if downloads.Load() != before {
		t.Fatal("readiness checks must not download replacements")
	}
}

func TestUnresolvedRuntimeArchiveAliasesNeverBecomeReady(t *testing.T) {
	for _, scenario := range []struct {
		name  string
		links []tar.Header
	}{
		{"dangling", []tar.Header{{Name: "fixture/libfirst.dylib", Linkname: "missing.dylib"}}},
		{"cycle", []tar.Header{
			{Name: "fixture/libfirst.dylib", Linkname: "libsecond.dylib"},
			{Name: "fixture/libsecond.dylib", Linkname: "libfirst.dylib"},
		}},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			_, freshProvider, _ := aliasProviders(t, aliasArchive(t, scenario.links...))
			p := freshProvider()
			if err := p.Download(t.Context()); err != nil {
				t.Fatal(err)
			}
			wait("unresolved alias installation settles", func() bool { return !p.SetupStatus().Downloading })
			if p.Available(t.Context()) || p.SetupStatus().Ready || p.SetupStatus().Reason != "download-failed" {
				t.Fatalf("unresolved %s alias must reject the installation: %+v", scenario.name, p.SetupStatus())
			}
			if freshProvider().Available(t.Context()) {
				t.Fatal("failed alias installation must not publish durable readiness")
			}
		})
	}
}
