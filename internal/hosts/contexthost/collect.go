package contexthost

import (
	"context"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"strings"
	"time"
)

// CollectMokuContexts uses each contribution's independent timeout/fallback and
// deterministic slot order. Acquired services remain owned by this generation.
func (h *Host) CollectMokuContexts(ctx context.Context, phase string, catalogs []plugin.BoundModelCatalog) ([]plugin.ContextEntry, error) {
	ctx, services, done, err := h.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	slots := map[string][]string{}
	total := 0
	for _, id := range keys(h.definitions) {
		if !h.definitions[id].enabled {
			continue
		}
		definition := h.definitions[id].definition
		if definition.InjectAt != phase {
			continue
		}
		service := services[id]
		if service == nil {
			return nil, fmt.Errorf("Moku context %s is not started", id)
		}
		attempt, cancel := context.WithTimeout(ctx, time.Duration(definition.TimeoutMS)*time.Millisecond)
		content, err := service.Collect(attempt, plugin.MokuContextInput{Catalogs: catalogs})
		if attempt.Err() != nil {
			err = attempt.Err()
		}
		cancel()
		if (err != nil || strings.TrimSpace(content) == "") && ctx.Err() == nil {
			if fallback, ok := service.(plugin.MokuContextFallback); ok {
				attempt, cancel = context.WithTimeout(ctx, time.Duration(definition.TimeoutMS)*time.Millisecond)
				content, err = fallback.Fallback(attempt, plugin.MokuContextInput{Catalogs: catalogs})
				if attempt.Err() != nil {
					err = attempt.Err()
				}
				cancel()
			}
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if err == nil && len(content) > 128*1024 {
			err = errors.New("Moku context contribution exceeds byte limit")
		}
		if err != nil {
			if definition.OnFailure == "abort-send" {
				return nil, fmt.Errorf("Moku context %s: %w", id, err)
			}
			continue
		}
		if strings.TrimSpace(content) == "" {
			if definition.OnFailure == "abort-send" {
				return nil, fmt.Errorf("Moku context %s returned no content", id)
			}
			continue
		}
		total += len(content)
		if len(slots[definition.Slot]) > 0 {
			total += len("\n\n")
		}
		if total > 256*1024 {
			return nil, errors.New("Moku context total exceeds byte limit")
		}
		slots[definition.Slot] = append(slots[definition.Slot], content)
	}
	result := make([]plugin.ContextEntry, 0, len(slots))
	for _, slot := range keys(slots) {
		result = append(result, plugin.ContextEntry{ID: slot, Content: strings.Join(slots[slot], "\n\n")})
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return result, nil
}
