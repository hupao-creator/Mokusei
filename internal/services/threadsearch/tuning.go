package threadsearch

import (
	"errors"
	"math"
)

// Tuning is an internal construction option for corpus evaluation and future
// model integrations. Zero selects defaults; nonzero values specify a complete
// configuration. It is not a user setting or a wire-level model selector.
type Tuning struct {
	PassageBytes      int     `json:"passageBytes"`
	MinimumSimilarity float64 `json:"minimumSimilarity"`
	SemanticLimit     int     `json:"semanticLimit"`
	MetadataWeight    float64 `json:"metadataWeight"`
}

func (t Tuning) defaults() Tuning {
	if t == (Tuning{}) {
		return DefaultTuning()
	}
	return t
}

func DefaultTuning() Tuning {
	return Tuning{PassageBytes: 768, MinimumSimilarity: .76, SemanticLimit: 12, MetadataWeight: .2}
}
func (t Tuning) validate() error {
	if t.PassageBytes < 256 || t.PassageBytes > 8192 || t.SemanticLimit < 1 || t.SemanticLimit > 100 ||
		math.IsNaN(t.MinimumSimilarity) || t.MinimumSimilarity < 0 || t.MinimumSimilarity > 1 ||
		math.IsNaN(t.MetadataWeight) || t.MetadataWeight < 0 || t.MetadataWeight > 1 {
		return errors.New("invalid search retrieval tuning")
	}
	return nil
}
