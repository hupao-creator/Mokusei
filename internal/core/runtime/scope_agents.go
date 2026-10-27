package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"path"
	"sort"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

func (r *Runtime) refreshScopeAgents(ctx context.Context) {
	if r.config.Applications == nil {
		return
	}
	if host, ok := r.config.Applications.(interface {
		RefreshScopeAgents(context.Context) error
	}); ok {
		if err := host.RefreshScopeAgents(ctx); err != nil {
			r.log("background.scope.refresh", err)
		}
	}
}

// DirectoryScopes lists durable directory identities without plugin knowledge.
func (r *Runtime) DirectoryScopes() ([]plugin.DirectoryScope, error) {
	snapshot := r.config.Store.Snapshot()
	scopes := map[string]plugin.DirectoryScope{"inbox": {ID: "inbox", Label: "Inbox"}}
	for _, key := range snapshot.Keys("directory-scope:") {
		var scope plugin.DirectoryScope
		if _, err := snapshot.Get(key, &scope); err != nil {
			return nil, err
		}
		if err := scope.Validate(); err != nil {
			return nil, err
		}
		scopes[scope.ID] = scope
	}
	threads, err := readThreads(snapshot)
	if err != nil {
		return nil, err
	}
	for _, thread := range threads {
		if !thread.Moku {
			scope := directoryScope(thread)
			scopes[scope.ID] = scope
		}
	}
	result := make([]plugin.DirectoryScope, 0, len(scopes))
	for _, scope := range scopes {
		result = append(result, scope)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result, nil
}
func directoryScope(thread model.ThreadRecord) plugin.DirectoryScope {
	scope := directorytag.Scope(thread.Cwd)
	label := directorytag.Name(thread.Cwd)
	if scope == "inbox" {
		label = "Inbox"
	} else if label == "" {
		label = path.Base(scope)
	}
	return plugin.DirectoryScope{ID: scope, Label: label}
}
func rememberDirectoryScope(tx *store.Tx, thread model.ThreadRecord) error {
	scope := directoryScope(thread)
	if err := scope.Validate(); err != nil {
		return err
	}
	sum := sha256.Sum256([]byte(scope.ID))
	key := "directory-scope:" + hex.EncodeToString(sum[:])
	var previous plugin.DirectoryScope
	ok, err := tx.Get(key, &previous)
	if err != nil || (ok && previous == scope) {
		return err
	}
	return tx.Put(key, scope)
}
