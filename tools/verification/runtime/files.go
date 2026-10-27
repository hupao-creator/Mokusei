package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
)

func verifyDownloadMutation(ctx context.Context, r *core.Runtime, directory string) {
	path := filepath.Join(directory, "download-mutation.bin")
	bytes := make([]byte, 128*1024)
	for index := range bytes {
		bytes[index] = byte(index)
	}
	must(os.WriteFile(path, bytes, 0600))
	for _, mutate := range []func(){
		func() {
			file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
			must(err)
			_, err = file.Write([]byte("changed"))
			must(err)
			must(file.Close())
		},
		func() { must(os.Truncate(path, 1024)) },
		func() {
			replacement := append([]byte{}, bytes...)
			replacement[0] ^= 1
			must(os.WriteFile(path, replacement, 0600))
		},
	} {
		download, err := r.DownloadFile(ctx, model.HostFileReference{Path: path})
		must(err)
		mutate()
		n, err := io.Copy(io.Discard, download.Reader)
		must(download.Reader.Close())
		if err == nil && n == download.Size {
			panic("changed host file downloaded as complete")
		}
		must(os.WriteFile(path, bytes, 0600))
	}
	download, err := r.DownloadFile(ctx, model.HostFileReference{Path: path})
	must(err)
	n, err := io.Copy(io.Discard, download.Reader)
	must(err)
	must(download.Reader.Close())
	if n != int64(len(bytes)) {
		panic("unchanged file download is incomplete")
	}
	must(os.Remove(path))
	fmt.Println("PASS host file download rejects append, truncation and same-size replacement after opening; unchanged descriptor completes")
}
