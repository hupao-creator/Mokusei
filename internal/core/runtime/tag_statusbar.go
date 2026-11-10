package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

func (c tagsReadCapability) CaptureStatusbar(ctx context.Context) (plugin.TagStatusbar, error) {
	if err := ctx.Err(); err != nil {
		return plugin.TagStatusbar{}, err
	}
	return captureTagStatusbar(c.runtime.config.Store.Snapshot(), c.scopeID())
}

func captureTagStatusbar(snapshot store.Snapshot, scope string) (plugin.TagStatusbar, error) {
	status := plugin.TagStatusbar{Pool: scope, Capacity: maxScopeTags, Tags: []plugin.TagStatusDefinition{}, Threads: []plugin.TagStatusThread{}, Assignments: []plugin.TagStatusAssignment{}, UnassignedThreadIDs: []string{}}
	pool, _, err := readTags(snapshot, scope)
	if err != nil {
		return status, err
	}
	byName := map[string]string{}
	for _, tag := range pool {
		status.Tags = append(status.Tags, plugin.TagStatusDefinition{ID: tag.ID, Name: tag.Name, Emoji: tag.Emoji})
		byName[tagKey(tag.Name)] = tag.ID
	}
	threads, err := readThreads(snapshot)
	if err != nil {
		return status, err
	}
	for _, thread := range threads {
		if thread.Moku || thread.MokuHistory || archived(&thread) || directorytag.Scope(thread.Cwd) != scope {
			continue
		}
		status.Threads = append(status.Threads, plugin.TagStatusThread{ID: thread.ID, Title: thread.Title})
		assigned := false
		for _, name := range thread.Tags {
			if id, ok := byName[tagKey(name)]; ok {
				status.Assignments = append(status.Assignments, plugin.TagStatusAssignment{ThreadID: thread.ID, TagID: id})
				assigned = true
			}
		}
		if !assigned {
			status.UnassignedThreadIDs = append(status.UnassignedThreadIDs, thread.ID)
		}
	}
	sort.Slice(status.Tags, func(i, j int) bool { return status.Tags[i].ID < status.Tags[j].ID })
	sort.Slice(status.Threads, func(i, j int) bool { return status.Threads[i].ID < status.Threads[j].ID })
	sort.Slice(status.Assignments, func(i, j int) bool { return status.Assignments[i].ThreadID < status.Assignments[j].ThreadID })
	sort.Strings(status.UnassignedThreadIDs)
	// Content identity changes only with classification evidence, not unrelated
	// stream writes. The same immutable snapshot supplies every field and the CAS.
	raw, err := json.Marshal(status)
	if err != nil {
		return status, err
	}
	hash := sha256.Sum256(raw)
	status.Revision = hex.EncodeToString(hash[:])
	return status, nil
}

func (c tagsWriteCapability) Mutate(ctx context.Context, mutation plugin.TagMutation, options plugin.BackgroundWriteOptions) (json.RawMessage, error) {
	return c.execute(ctx, options, func(tx *store.Tx) (any, error) {
		status, err := captureTagStatusbar(tx.Snapshot(), c.scopeID())
		if err != nil {
			return nil, err
		}
		if mutation.ExpectedRevision == "" {
			return nil, errors.New("expectedRevision is required")
		}
		if mutation.ExpectedRevision != status.Revision {
			return plugin.TagMutationResult{Status: "conflict", Statusbar: status}, nil
		}
		byID := map[string]string{}
		for _, tag := range status.Tags {
			byID[tag.ID] = tag.Name
		}
		operation := plugin.SemanticTagOperation{Kind: mutation.Kind}
		switch mutation.Kind {
		case "create":
			if mutation.Name == nil || mutation.Emoji == nil {
				return nil, errors.New("name and emoji are required")
			}
			operation.Name, operation.Emoji = *mutation.Name, mutation.Emoji
		case "update", "delete":
			name, ok := byID[mutation.TagID]
			if !ok {
				return nil, errors.New("tagId is not in this pool")
			}
			operation.Name = name
			operation.Emoji = mutation.Emoji
			if mutation.Name != nil {
				if *mutation.Name == "" {
					return nil, errors.New("name must not be empty")
				}
				operation.NewName = *mutation.Name
			}
		case "assign":
			operation.Kind = "assign-many"
			for _, assignment := range mutation.Assignments {
				name, ok := byID[assignment.TagID]
				if !ok {
					return nil, errors.New("tagId is not in this pool")
				}
				operation.Assignments = append(operation.Assignments, plugin.SemanticTagAssignment{Thread: model.ThreadRef{ThreadID: assignment.ThreadID, TypeID: "agent"}, Tags: []string{name}})
			}
		default:
			return nil, errors.New("unknown tag mutation")
		}
		if _, err := c.apply(tx, operation); err != nil {
			return nil, err
		}
		status, err = captureTagStatusbar(tx.Snapshot(), c.scopeID())
		return plugin.TagMutationResult{Status: "applied", Statusbar: status}, err
	})
}
