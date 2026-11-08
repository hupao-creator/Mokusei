package applicationhost

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

// SearchSources interprets only the owning plugin's public projection and its
// explicit classification evidence capability; the search engine never inspects
// opaque application state, native conversations or files on disk.
func (h *Host) SearchSources(snapshot store.Snapshot, includeContent bool) ([]threadsearch.Source, error) {
	entries, err := h.CatalogSnapshot(context.Background(), snapshot)
	if err != nil {
		return nil, err
	}
	sources := []threadsearch.Source{}
	for _, entry := range entries {
		if source, eligible := h.searchSource(snapshot, h.threadTypes[entry.Ref.TypeID], entry, includeContent); eligible {
			sources = append(sources, source)
		}
	}
	return sources, nil
}

// The registered collection prefixes exclude Git observations, settings and
// search's own derived writes before any record or plugin projection is read.
func (h *Host) SearchSourceChanges(snapshot, previous store.Snapshot, includeContent bool) ([]threadsearch.Source, error) {
	if err := h.begin(); err != nil {
		return nil, err
	}
	defer h.operations.Done()
	sources := []threadsearch.Source{}
	for _, id := range sortedKeys(h.threadTypes) {
		definition := h.threadTypes[id]
		if !h.enabled(definition.OwnerPluginID) {
			continue
		}
		prefix := recordKey(definition.CollectionID, "")
		for _, key := range snapshot.ChangedKeys(previous, prefix) {
			if !snapshot.Has(key) {
				continue
			}
			_, record, err := h.readThread(snapshot, model.ThreadRef{ThreadID: strings.TrimPrefix(key, prefix), TypeID: id})
			if err != nil {
				return nil, err
			}
			entry, err := h.projectThread(context.Background(), definition, record)
			if err != nil {
				return nil, err
			}
			if source, eligible := h.searchSource(snapshot, definition, entry, includeContent); eligible {
				sources = append(sources, source)
			}
		}
	}
	return sources, nil
}

func (h *Host) searchSource(snapshot store.Snapshot, definition plugin.ThreadTypeDefinition, entry model.ApplicationThread, includeContent bool) (threadsearch.Source, bool) {
	if entry.Archived {
		return threadsearch.Source{}, false
	}
	for _, presentation := range entry.Presentations {
		if presentation.ID != "mokusei.overview" {
			continue
		}
		var overview struct {
			Visible *bool `json:"visible"`
		}
		if json.Unmarshal(presentation.Value, &overview) != nil || (overview.Visible != nil && !*overview.Visible) {
			return threadsearch.Source{}, false
		}
	}
	owner := recordKey(definition.CollectionID, entry.ID)
	hash, _ := snapshot.RecordHash(owner)
	source := threadsearch.Source{Ref: entry.Ref, Owner: owner, OwnerHash: hash, Identity: owner + "\x00" + strconv.FormatInt(entry.CreatedAt, 10), Title: entry.Title, Tags: entry.Tags.Tags}
	if includeContent && definition.SearchText != nil {
		source.LoadContent = func() (string, error) {
			_, record, err := h.readThread(snapshot, entry.Ref)
			if err != nil {
				return "", err
			}
			return definition.SearchText(record)
		}
	} else if includeContent && definition.Classification != nil {
		source.LoadContent = func() (string, error) {
			evidence, err := h.ClassificationEvidence(snapshot, entry.Ref)
			return evidence.Content, err
		}
	}
	return source, true
}
