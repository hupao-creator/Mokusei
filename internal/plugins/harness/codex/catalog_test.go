package codex

import (
	"context"
	"errors"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
)

func TestCatalogPresentationReportsCleanupFailure(t *testing.T) {
	failure := errors.New("native ownership uncertain")
	catalog := NewCatalog(func(context.Context, string, string) (*AppServer, error) { return nil, discovery.Cleanup(failure) })
	value, err := catalog.LoadPresentation(context.Background(), "fixture", "", false)
	if err != nil {
		t.Fatal(err)
	}
	cli, _ := csRecord(value["cli"])
	if cli["available"] != false || cli["error"] == nil {
		t.Fatal("failed native cleanup was presented as available")
	}
	if !errors.Is(catalog.Close(), failure) {
		t.Fatal("catalog Close lost native cleanup failure")
	}
}
