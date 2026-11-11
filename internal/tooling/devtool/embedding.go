package devtool

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const embeddingLibrary = "libCLiteRTLM_mac.dylib"
const embeddingDependency = "@rpath/" + embeddingLibrary

func stageEmbedding(ctx context.Context, repo, directory, app string) (string, error) {
	executable := filepath.Join(app, "Contents/MacOS/MokuseiEmbedding")
	hash, err := copyStable(filepath.Join(directory, "MokuseiEmbedding"), executable)
	if err != nil {
		return "", err
	}
	frameworks := filepath.Join(app, "Contents/Frameworks")
	if err = os.MkdirAll(frameworks, 0755); err != nil {
		return "", err
	}
	library := filepath.Join(frameworks, embeddingLibrary)
	if _, err = run(ctx, repo, nil, "/usr/bin/lipo", filepath.Join(directory, embeddingLibrary), "-thin", "arm64", "-output", library); err != nil {
		return "", err
	}
	if err = os.Chmod(library, 0755); err != nil {
		return "", err
	}
	for _, path := range []string{executable, library} {
		rpaths, err := machORPaths(ctx, path)
		if err != nil {
			return "", err
		}
		for _, rpath := range rpaths {
			if !portableRPath(rpath) {
				if _, err = run(ctx, repo, nil, "/usr/bin/install_name_tool", "-delete_rpath", rpath, path); err != nil {
					return "", err
				}
			}
		}
		if _, err := assertPortableMachO(ctx, path, frameworks, false); err != nil {
			return "", err
		}
	}
	if err = copyFile(filepath.Join(repo, "app/macos/build/licenses/LiteRT-LM-LICENSE"), filepath.Join(app, "Contents/Resources/licenses/LiteRT-LM-LICENSE"), 0644); err != nil {
		return "", err
	}
	return hash, nil
}

// This runs the signed, staged executable after removing all build-directory
// rpaths, proving that the packaged library resolves without SwiftPM caches.
func probeEmbedding(ctx context.Context, app string) error {
	executable := filepath.Join(app, "Contents/MacOS/MokuseiEmbedding")
	output, err := run(ctx, app, nil, executable, "--describe")
	if err != nil {
		return err
	}
	var hello struct {
		Event      string `json:"event"`
		Descriptor struct {
			Space      string `json:"space"`
			Dimensions int    `json:"dimensions"`
		} `json:"descriptor"`
	}
	if err := json.Unmarshal([]byte(output), &hello); err != nil {
		return err
	}
	if hello.Event != "hello" || hello.Descriptor.Space == "" || hello.Descriptor.Dimensions < 1 || hello.Descriptor.Dimensions > 4096 {
		return fmt.Errorf("invalid packaged embedding handshake")
	}
	return nil
}
