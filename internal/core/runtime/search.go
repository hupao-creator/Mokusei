package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strconv"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

func searchVisible(thread model.ThreadRecord) bool {
	if thread.Moku || archived(&thread) {
		return false
	}
	return true
}
func (r *Runtime) searchSources(snapshot store.Snapshot, includeContent bool) ([]threadsearch.Source, error) {
	threads, err := r.cachedThreads(snapshot)
	if err != nil {
		return nil, err
	}
	sources := []threadsearch.Source{}
	for _, thread := range threads {
		if !searchVisible(thread) {
			continue
		}
		owner := "thread:" + thread.ID
		hash, _ := snapshot.RecordHash(owner)
		source := threadsearch.Source{Ref: model.ThreadRef{ThreadID: thread.ID, TypeID: "agent"}, Owner: owner, OwnerHash: hash, Identity: owner + "\x00" + strconv.FormatInt(thread.CreatedAt, 10), Title: thread.Title, Cwd: thread.Cwd, Tags: thread.Tags}
		source.Busy = thread.Observation.BackgroundWork != nil || (thread.Observation.LatestExecution != nil && !thread.Observation.LatestExecution.Terminal())
		if includeContent {
			if harness := r.config.Harnesses[thread.HarnessID]; harness != nil {
				if adapter, ok := harness.SessionState().(plugin.SearchTextAdapter); ok {
					source.LoadContent = func() (string, error) {
						return adapter.SearchText(bytes.Clone(thread.SessionState))
					}
				}
			}
		}
		sources = append(sources, source)
	}
	r.mu.Lock()
	applications := r.config.Applications
	r.mu.Unlock()
	if host, ok := applications.(interface {
		SearchSources(store.Snapshot, bool) ([]threadsearch.Source, error)
	}); ok {
		entries, err := host.SearchSources(snapshot, includeContent)
		if err != nil {
			return nil, err
		}
		sources = append(sources, entries...)
	}
	return sources, nil
}
func (r *Runtime) searchCommand(ctx context.Context, channel string, args []json.RawMessage) (any, error) {
	ctx, cancel := r.operationContext(ctx)
	defer cancel()
	decode := func(value any) error {
		decoder := json.NewDecoder(bytes.NewReader(args[0]))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(value); err != nil {
			return errors.New("Invalid search request")
		}
		return nil
	}
	switch channel {
	case "search:status":
		return r.search.Status(ctx)
	case "search:configure":
		var request threadsearch.ConfigureRequest
		if err := decode(&request); err != nil {
			return nil, err
		}
		return r.search.Configure(ctx, request)
	case "search:model":
		var request struct {
			Action          string `json:"action"`
			ConfirmDownload bool   `json:"confirmDownload"`
		}
		if err := decode(&request); err != nil {
			return nil, err
		}
		local, ok := r.config.Embeddings.(plugin.ManagedEmbeddings)
		if !ok {
			return nil, errors.New("Local embedding engine is unavailable")
		}
		switch request.Action {
		case "download":
			if !request.ConfirmDownload {
				return nil, errors.New("Confirm the model download first")
			}
			if err := local.Download(ctx); err != nil {
				return nil, err
			}
		case "cancel":
			local.CancelDownload()
		case "remove":
			return r.search.RemoveModel(ctx)
		default:
			return nil, errors.New("Invalid model action")
		}
		return r.search.Status(ctx)
	case "search:index":
		var request threadsearch.IndexRequest
		if err := decode(&request); err != nil {
			return nil, err
		}
		return r.search.Index(ctx, request)
	case "search:query":
		var request threadsearch.QueryRequest
		if err := decode(&request); err != nil {
			return nil, err
		}
		return r.search.Query(ctx, request)
	}
	return nil, errors.New("Unknown search operation")
}
