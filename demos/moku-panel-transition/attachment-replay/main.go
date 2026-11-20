// Run the attachment repository against the native replay's temporary profile.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Chief/internal/services/attachments"
)

func run(mode string) error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	repo := attachments.NewWithClientStorage(filepath.Join(root, "files"), filepath.Join(root, "profile"))
	switch mode {
	case "stage":
		var imports []attachments.Import
		for _, name := range []string{"first", "second"} {
			path := filepath.Join(root, name+".txt")
			if err := os.WriteFile(path, []byte(name), 0600); err != nil {
				return err
			}
			imports = append(imports, attachments.Import{Source: "path", Path: path, DisplayName: name})
		}
		files, err := repo.Stage(context.Background(), imports)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(files)
	case "busy":
		ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
		defer cancel()
		if err := repo.CollectOrphans(ctx, 0); !errors.Is(err, context.DeadlineExceeded) {
			return fmt.Errorf("collector did not wait for the active ownership lock: %v", err)
		}
		return nil
	case "collect":
		return repo.CollectOrphans(context.Background(), 0)
	}
	return fmt.Errorf("unknown replay mode %q", mode)
}

func main() {
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
