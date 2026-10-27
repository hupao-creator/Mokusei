package applicationhost

import (
	"context"
	"encoding/json"
	"strconv"

	"github.com/hupao-creator/Mokusei/internal/core/model"
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
		if entry.Archived {
			continue
		}
		visible := true
		for _, presentation := range entry.Presentations {
			if presentation.ID == "mokusei.overview" {
				var overview struct {
					Visible *bool `json:"visible"`
				}
				if json.Unmarshal(presentation.Value, &overview) != nil {
					visible = false
					break
				}
				visible = overview.Visible == nil || *overview.Visible
			}
		}
		if !visible {
			continue
		}
		definition, record, err := h.readThread(snapshot, entry.Ref)
		if err != nil {
			return nil, err
		}
		owner := recordKey(definition.CollectionID, entry.ID)
		hash, _ := snapshot.RecordHash(owner)
		source := threadsearch.Source{Ref: entry.Ref, Owner: owner, OwnerHash: hash, Identity: owner + "\x00" + strconv.FormatInt(record.CreatedAt, 10), Title: entry.Title, Tags: entry.Tags.Tags}
		if includeContent && definition.SearchText != nil {
			source.LoadContent = func() (string, error) { return definition.SearchText(record) }
		} else if includeContent && definition.Classification != nil {
			source.LoadContent = func() (string, error) {
				evidence, err := h.ClassificationEvidence(snapshot, model.ThreadRef{ThreadID: entry.ID, TypeID: entry.Ref.TypeID})
				return evidence.Content, err
			}
		}
		sources = append(sources, source)
	}
	return sources, nil
}
