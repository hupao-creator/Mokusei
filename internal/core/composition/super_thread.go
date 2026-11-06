package composition

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Resolve only the captured document at the application-owned read boundary.
// Never accept client-supplied report HTML or enumerate unrelated task histories.
func (b *Bootstrap) superThreadContext(ctx context.Context, id string) (json.RawMessage, error) {
	input, err := json.Marshal(map[string]string{"reportId": id})
	if err != nil {
		return nil, err
	}
	value, err := b.applications.Query(ctx, plugin.OperationRequest{PluginID: "report", OperationID: "report.context", Input: input})
	if err != nil {
		return nil, err
	}
	raw, ok := value.(json.RawMessage)
	if !ok {
		return nil, fmt.Errorf("invalid Super Thread context result")
	}
	return raw, nil
}
