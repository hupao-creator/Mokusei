package plugin

import (
	"crypto/sha256"
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

// CatalogSourceEvidence is separate from finishing enumeration. Adapters must
// keep unproven remote completeness false even when native enumeration is usable.
// Routing accepts native snapshots; provenance is informational, not an admission gate.
type CatalogSourceEvidence struct {
	Complete bool   `json:"complete"`
	Basis    string `json:"basis"`
}

type CompleteModelCatalog struct {
	EnumerationComplete bool                  `json:"enumerationComplete"`
	Source              CatalogSourceEvidence `json:"source"`
	ConfigurationID     string                `json:"configurationId,omitempty"`
	Models              []ModelCatalogEntry   `json:"models"`
}

// ModelCatalogSchema records complete protocol enumeration, not an attestation
// that native remote sources finished discovery. See Moku catalog-evidence.md.
// The inventory is distinct from executable schema branches: omitting unsupported
// choices must not hide their model identities from cross-Harness routing.
func ModelCatalogSchema(schema map[string]any, models []ModelCatalogEntry, identity string, source CatalogSourceEvidence) (json.RawMessage, error) {
	if identity == "" {
		return nil, errors.New("native model catalog configuration identity is missing")
	}
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
	catalog := CompleteModelCatalog{Models: models, EnumerationComplete: true, Source: source}
	inventory, err := json.Marshal(catalog)
	if err != nil {
		return nil, err
	}
	catalog.ConfigurationID = fmt.Sprintf("%x", sha256.Sum256([]byte(identity)))
	schema["x-mokusei-model-catalog"] = catalog
	// Standard descriptions survive native schema serializers that discard
	// extension keywords. Never truncate the routing inventory to candidates.
	description, _ := schema["description"].(string)
	schema["description"] = fmt.Sprintf("%s\nNative response inventory (all returned entries; may be cached and outdated; provider completeness and execution are not guaranteed): %s", description, inventory)
	return json.Marshal(schema)
}
