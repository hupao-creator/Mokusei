package git

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strconv"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Service struct{}

func New() *Service { return &Service{} }
func (*Service) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{BuiltIn: true, ID: "git", DisplayName: "Git", APIVersion: 1, Contributes: plugin.Contributions{
		BackgroundAgents: []string{"git.monitor"}, Collections: []string{Worktrees},
		Queries: []string{"git.list", "git.files", "git.diff"}, Commands: []string{"git.sync"}}}
}
func (*Service) Register(registry plugin.Registry) error {
	c := &client{gate: make(chan struct{}, 2)}
	if err := registry.Collection(plugin.CollectionDefinition{ID: Worktrees, OwnerPluginID: "git", Retention: "history", Contract: contract("git.worktree", validateWorktree)}); err != nil {
		return err
	}
	pageInput := contract("git.page", func(p *PageInput) error {
		if p.Limit < 1 || p.Limit > 1000 {
			return errors.New("invalid Git page limit")
		}
		if p.Cursor != "" {
			n, e := strconv.Atoi(p.Cursor)
			if e != nil || n < 0 {
				return errors.New("invalid Git cursor")
			}
		}
		return nil
	})
	id := "git.list"
	output := plugin.ValueContract{ID: id + ".output", SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) {
		return contract[Page[Activity]]("page", nil).Validate(raw)
	}}
	if err := registry.Query(plugin.QueryDefinition{Operation: operation(id, pageInput, output), Audience: plugin.QueryAudience{User: true, Background: true}, Read: func(raw json.RawMessage, ctx plugin.ReadContext) (json.RawMessage, error) {
		input := decode[PageInput](raw)
		rows, err := ctx.Records.List(Worktrees)
		if err != nil {
			return nil, err
		}
		offset := 0
		if input.Cursor != "" {
			offset, _ = strconv.Atoi(input.Cursor)
		}
		start := min(offset, len(rows))
		end := start + min(input.Limit, len(rows)-start)
		next := ""
		if end < len(rows) {
			next = strconv.Itoa(end)
		}
		page := Page[Activity]{Items: []Activity{}, NextCursor: next}
		for _, row := range rows[start:end] {
			page.Items = append(page.Items, Activity{row.ID, decode[Worktree](row.Value)})
		}
		return json.Marshal(page)
	}}); err != nil {
		return err
	}
	syncInput := contract("git.sync.input", func(input *SyncInput) error {
		if input.AttemptedAt < 0 || input.Observations == nil || len(input.Observations) > 10000 {
			return errors.New("invalid Git sync batch")
		}
		for _, o := range input.Observations {
			if !validRoot(o.Root) || o.AttemptedAt != input.AttemptedAt || !validError(o.Error) || o.Error != nil && o.Snapshot != nil {
				return errors.New("invalid Git observation")
			}
			if err := validateDirectories(o.Directories); err != nil {
				return err
			}
			if o.Snapshot != nil {
				if o.Snapshot.Root != o.Root {
					return errors.New("Git observation root mismatch")
				}
				if err := validateSnapshot(*o.Snapshot); err != nil {
					return err
				}
			}
		}
		return nil
	})
	null := plugin.ValueContract{ID: "git.null", SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) {
		if !model.IsNull(raw) {
			return nil, errors.New("expected null")
		}
		return json.RawMessage("null"), nil
	}}
	if err := registry.Command(plugin.CommandDefinition{Operation: operation("git.sync", syncInput, null), Audience: plugin.CommandAudience{Background: "allow-unbatched"}, Plan: func(_ json.RawMessage, ctx plugin.ReadContext) ([]plugin.MutationScope, error) {
		scope, err := ctx.Records.Scope(Worktrees, "")
		if err != nil {
			return nil, err
		}
		return []plugin.MutationScope{scope}, nil
	}, Reduce: reduceSync}); err != nil {
		return err
	}
	filesInput := contract("git.files.input", func(i *FilesInput) error {
		if !validID(i.ActivityID) {
			return errors.New("invalid Git activity identity")
		}
		return nil
	})
	selection := contract("git.diff.input", func(i *Selection) error {
		if !validID(i.ActivityID) || !validPath(i.Path) || !validScope(i.Scope) {
			return errors.New("invalid Git diff selection")
		}
		return nil
	})
	requires := []plugin.CapabilityKey{plugin.ApplicationProcessCapabilityKey}
	read := func(ctx context.Context, access plugin.ExternalReadContext, id string) (plugin.ApplicationProcessCapability, string, error) {
		record, err := access.Snapshot.Records.Get(Worktrees, id)
		if err != nil {
			return nil, "", err
		}
		if record == nil {
			return nil, "", errors.New("Git activity is no longer available")
		}
		w := decode[Worktree](record.Value)
		if !w.Available {
			return nil, "", errors.New("Git worktree is no longer available")
		}
		p, err := plugin.Require[plugin.ApplicationProcessCapability](access.Capabilities, plugin.ApplicationProcessCapabilityKey)
		if err != nil {
			return nil, "", err
		}
		return p, w.Snapshot.Root, c.validateRoot(ctx, p, w.Snapshot.Root)
	}
	if err := registry.ExternalQuery(plugin.ExternalQueryDefinition{Operation: operation("git.files", filesInput, contract[FilesResult]("git.files.output", nil)), Audience: plugin.QueryAudience{User: true}, Requires: requires, Read: func(ctx context.Context, raw json.RawMessage, access plugin.ExternalReadContext) (json.RawMessage, error) {
		input := decode[FilesInput](raw)
		p, root, err := read(ctx, access, input.ActivityID)
		if err != nil {
			return nil, err
		}
		_, files, err := c.status(ctx, p, root)
		if err != nil {
			return nil, err
		}
		return json.Marshal(FilesResult{files, time.Now().UnixMilli()})
	}}); err != nil {
		return err
	}
	if err := registry.ExternalQuery(plugin.ExternalQueryDefinition{Operation: operation("git.diff", selection, contract[DiffContent]("git.diff.output", nil)), Audience: plugin.QueryAudience{User: true}, Requires: requires, Read: func(ctx context.Context, raw json.RawMessage, access plugin.ExternalReadContext) (json.RawMessage, error) {
		input := decode[Selection](raw)
		p, root, err := read(ctx, access, input.ActivityID)
		if err != nil {
			return nil, err
		}
		diff, err := c.diff(ctx, p, root, input)
		if err != nil {
			return nil, err
		}
		return json.Marshal(diff)
	}}); err != nil {
		return err
	}
	return registry.BackgroundAgent(plugin.BackgroundAgentDefinition{ID: "git.monitor", InstancePolicy: plugin.GlobalInstance, Requires: []plugin.CapabilityKey{plugin.OrdinaryTaskReadCapabilityKey, plugin.ApplicationProcessCapabilityKey, plugin.BackgroundEnvironmentCapabilityKey}, Create: func(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
		tasks, err := plugin.Require[plugin.OrdinaryTaskReadCapability](ctx.Capabilities, plugin.OrdinaryTaskReadCapabilityKey)
		if err != nil {
			return nil, err
		}
		p, err := plugin.Require[plugin.ApplicationProcessCapability](ctx.Capabilities, plugin.ApplicationProcessCapabilityKey)
		if err != nil {
			return nil, err
		}
		environment, err := plugin.Require[plugin.BackgroundEnvironmentCapability](ctx.Capabilities, plugin.BackgroundEnvironmentCapabilityKey)
		if err != nil {
			return nil, err
		}
		return &monitor{domain: ctx.Domain, tasks: tasks, process: p, client: c, environment: environment}, nil
	}})
}
func marshal(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}
func reduceSync(raw json.RawMessage, ctx plugin.TransactionContext) (json.RawMessage, error) {
	input := decode[SyncInput](raw)
	rows, err := ctx.Records.List(Worktrees)
	if err != nil {
		return nil, err
	}
	worktrees := map[string]model.VersionedRecord{}
	for _, r := range rows {
		previous := decode[Worktree](r.Value)
		// Fence the complete reconciliation, including deletions, against late batches.
		if input.AttemptedAt <= previous.Sync.AttemptedAt {
			return json.RawMessage("null"), nil
		}
		worktrees[previous.Snapshot.Root] = r
	}
	seen := map[string]bool{}
	for _, o := range input.Observations {
		seen[o.Root] = true
		record, exists := worktrees[o.Root]
		previous := decode[Worktree](record.Value)
		if !exists && o.Snapshot == nil {
			continue
		}
		next := previous
		next.Directories = o.Directories
		next.Sync.AttemptedAt = o.AttemptedAt
		next.Sync.Error = o.Error
		if o.Error == nil {
			next.Available = o.Snapshot != nil
			next.Sync.ObservedAt = o.AttemptedAt
			if o.Snapshot != nil {
				next.Snapshot = *o.Snapshot
			}
		}
		oldMeaning, nextMeaning := previous, next
		oldMeaning.Sync = SyncStatus{}
		nextMeaning.Sync = SyncStatus{}
		meaningful := !exists || !reflect.DeepEqual(oldMeaning, nextMeaning)
		if !meaningful && reflect.DeepEqual(previous.Sync.Error, next.Sync.Error) && o.AttemptedAt-previous.Sync.AttemptedAt < 60000 {
			continue
		}
		id := record.ID
		var revision *int64
		if exists {
			revision = &record.Revision
		} else {
			id = ctx.AllocateID("worktree:" + o.Root)
		}
		saved, e := ctx.Records.Put(Worktrees, id, marshal(next), plugin.RecordWriteOptions{ExpectedRevision: revision, TouchUpdatedAt: meaningful})
		if e != nil {
			return nil, e
		}
		worktrees[o.Root] = saved
	}
	for root, record := range worktrees {
		if !seen[root] {
			if err := ctx.Records.Delete(Worktrees, record.ID, record.Revision); err != nil {
				return nil, err
			}
		}
	}
	return json.RawMessage("null"), nil
}
