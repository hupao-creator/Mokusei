package plugin

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// ModelCatalogEntry identifies every model returned by native discovery, including
// models whose creation capabilities or account availability are not established.
// It contains no credentials or native request configuration.
type ModelCatalogEntry struct {
	Provider          string `json:"provider,omitempty"`
	ID                string `json:"id"`
	Name              string `json:"name,omitempty"`
	UnavailableReason string `json:"unavailableReason,omitempty"`
}

type CompleteModelCatalog struct {
	Models []ModelCatalogEntry `json:"models"`
}

// ModelCatalogSchema must only be called after a complete native catalog read.
// The inventory is distinct from executable schema branches: omitting unsupported
// choices must not hide their model identities from cross-Harness routing.
func ModelCatalogSchema(schema map[string]any, models []ModelCatalogEntry) (json.RawMessage, error) {
	if len(models) == 0 {
		return nil, errors.New("native model catalog is empty; Moku cannot start without a complete nonempty catalog")
	}
	seen := map[string]bool{}
	for _, entry := range models {
		key := entry.Provider + "\x00" + entry.ID
		if strings.TrimSpace(entry.ID) == "" || strings.ContainsRune(entry.ID, 0) || strings.ContainsRune(entry.Provider, 0) || seen[key] {
			return nil, errors.New("native model catalog has a missing, invalid or duplicate model identifier")
		}
		seen[key] = true
	}
	catalog := CompleteModelCatalog{Models: models}
	inventory, err := json.Marshal(catalog)
	if err != nil {
		return nil, err
	}
	schema["x-mokusei-model-catalog"] = catalog
	// Standard descriptions survive native schema serializers that discard
	// extension keywords. Never truncate the routing inventory to candidates.
	description, _ := schema["description"].(string)
	schema["description"] = fmt.Sprintf("%s\nComplete native model inventory (snapshot, not an execution guarantee): %s", description, inventory)
	return json.Marshal(schema)
}
