// Package embedding isolates local model protocols and process ownership from
// retrieval. A descriptor identifies an embedding space, not merely its width.
package embedding

import (
	"context"
	"errors"
)

type Descriptor struct {
	Space         string `json:"space"`
	Name          string `json:"name"`
	Dimensions    int    `json:"dimensions"`
	DocumentBytes int    `json:"documentBytes"`
}

type Status struct {
	Phase          string `json:"phase"`
	Ready          bool   `json:"ready"`
	CompletedBytes int64  `json:"completedBytes,omitempty"`
	TotalBytes     int64  `json:"totalBytes,omitempty"`
	Reason         string `json:"reason,omitempty"`
}

type Kind string

const (
	Query    Kind = "query"
	Document Kind = "document"
)

var ErrNotReady = errors.New("embedding model is not ready")

// Providers return finite, L2-normalized vectors in Descriptor's space. They
// validate external inference output before passing it to trusted retrieval.
// Returned vector storage belongs to the caller and must not be reused by a
// later inference. Each Runtime owns and closes its own provider instance.
type Provider interface {
	Descriptor() Descriptor
	Status() Status
	Embed(context.Context, Kind, []string) ([][]float32, error)
	Retry()
	Close() error
}
