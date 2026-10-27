package plugin

import (
	"context"
	"encoding/json"
)

// ContextPlugin contributes additional context exclusively to Moku. It has no
// application records, domain commands, surfaces or background-agent authority.
type ContextPlugin interface {
	Manifest() ContextManifest
	// Register declares definitions only. Acquisition starts with the host.
	Register(ContextRegistry) error
}
type ContextManifest struct {
	ID            string   `json:"id"`
	DisplayName   string   `json:"displayName"`
	APIVersion    int      `json:"apiVersion"`
	Contributions []string `json:"contributions"`
}
type ContextRegistry interface {
	MokuContext(MokuContextDefinition) error
}

type MokuContextInput struct{ Catalogs []BoundModelCatalog }
type BoundModelCatalog struct {
	ID          string
	DisplayName string
	Load        func(context.Context) (json.RawMessage, error)
}
type MokuContextDefinition struct {
	ID        string
	Slot      string
	InjectAt  string // session-start or before-send
	TimeoutMS int64
	OnFailure string // omit or abort-send
	Create    func() (MokuContextService, error)
}
type MokuContextService interface {
	// Collect and Fallback must respect cancellation. A service may be called
	// concurrently; it owns any shared cache and acquisition synchronization.
	Collect(context.Context, MokuContextInput) (string, error)
	// Close is idempotent, cancels acquisition and drains all owned work.
	Close() error
}
type MokuContextFallback interface {
	Fallback(context.Context, MokuContextInput) (string, error)
}
