// Seed an exclusively owned replay profile through the production store.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

func main() {
	if err := seed(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func seed() error {
	options := flag.NewFlagSet("native-interaction", flag.ContinueOnError)
	selected := options.String("harnesses", "", "comma-separated enabled Harnesses in this isolated profile")
	if err := options.Parse(os.Args[1:]); err != nil {
		return err
	}
	if options.NArg() != 1 || !filepath.IsAbs(options.Arg(0)) {
		return errors.New("usage: native-interaction [-harnesses codex,claude,pi,opencode] /absolute/new/profile")
	}
	ids := []string{"codex", "claude", "pi", "opencode"}
	enabled := map[string]bool{}
	if *selected != "" {
		for _, id := range strings.Split(*selected, ",") {
			switch id {
			case "codex", "claude", "pi", "opencode":
			default:
				return fmt.Errorf("unknown Harness: %s", id)
			}
			if enabled[id] {
				return fmt.Errorf("duplicate Harness: %s", id)
			}
			enabled[id] = true
		}
		if !enabled["codex"] {
			return errors.New("the seeded conversations require Codex")
		}
	}
	root := options.Arg(0)
	// Refuse existing profiles so the fixture cannot overwrite user records.
	if err := os.Mkdir(root, 0700); err != nil {
		return err
	}
	db, err := store.Open(filepath.Join(root, "mokusei-go-state-v1", "state.sqlite"))
	if err != nil {
		return err
	}
	at := time.Now().UnixMilli()
	native, err := json.Marshal(codex.EmptyState(at))
	if err != nil {
		return errors.Join(err, db.Close())
	}
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		if *selected != "" {
			settings := model.DefaultSettings(ids)
			// Defaults belong to each real adapter; no native account discovery
			// or execution is needed to construct its empty configuration.
			host := plugin.HostContext{}
			for _, harness := range []plugin.Harness{codex.New(host), claude.New(host), pi.New(host), opencode.New(host)} {
				settings.Harnesses[harness.Descriptor().ID] = harness.DefaultSettings()
			}
			settings.Moku.HostHarnessPreference = "codex"
			settings.Moku.TargetHarnessIDs = strings.Split(*selected, ",")
			settings.PluginEnabled = map[string]bool{}
			for _, id := range ids {
				settings.PluginEnabled["harness:"+id] = enabled[id]
			}
			if err := tx.Put("settings", settings); err != nil {
				return err
			}
		}
		ids := []string{"interaction-a", "interaction-b", "interaction-c"}
		for i, id := range ids {
			archived := false
			record := model.ThreadRecord{SessionRecord: model.SessionRecord{
				ID: id, HarnessID: "codex", SessionState: native, Settings: json.RawMessage(`{}`),
				Cwd: filepath.Dir(root), CreatedAt: at + int64(i), UpdatedAt: at + int64(i),
			}, Title: "Navigation replay " + id, Archived: &archived, Tags: []string{"replay"}, TagEmojis: map[string]string{"replay": "🔁"}}
			if err := tx.Put("thread:"+id, record); err != nil {
				return err
			}
		}
		return tx.SetOrder("threads", ids)
	})
	return errors.Join(err, db.Close())
}
