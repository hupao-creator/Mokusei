package report

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Statusbar describes classification membership only. It grants no authority to
// report on a Thread without completed-execution evidence in the agent's context.
type Statusbar struct {
	Scope             string                        `json:"scope"`
	Revision          string                        `json:"revision"`
	UnassignedThreads []plugin.OrdinaryTaskIdentity `json:"unassignedThreads"`
}

func registerStatusbarQuery(registry plugin.Registry) error {
	return registry.Query(plugin.QueryDefinition{
		Operation: operation("report.statusbar", typedContract[struct{}]("report.statusbar.input", nil, nil), typedContract[Statusbar]("report.statusbar.output", []string{"scope", "revision", "unassignedThreads"}, nil)),
		Audience:  plugin.QueryAudience{Background: true},
		Requires:  []plugin.CapabilityKey{plugin.OrdinaryTaskInventorySnapshotCapabilityKey},
		Read: func(_ json.RawMessage, context plugin.ReadContext) (json.RawMessage, error) {
			scope, err := reportScope(context.Owner)
			if err != nil {
				return nil, err
			}
			inventory, err := plugin.Require[plugin.OrdinaryTaskInventorySnapshotCapability](context.Capabilities, plugin.OrdinaryTaskInventorySnapshotCapabilityKey)
			if err != nil {
				return nil, err
			}
			threads, err := inventory.List(scope)
			if err != nil {
				return nil, err
			}
			status := Statusbar{Scope: scope, UnassignedThreads: []plugin.OrdinaryTaskIdentity{}}
			for _, thread := range threads {
				// Ownership includes archived reports and historical bindings in
				// other scopes. Exclude bound Threads without disclosing those owners.
				owners, err := context.Records.LookupIDs(CollectionID, bindingIndex, thread.ID)
				if err != nil {
					return nil, err
				}
				if len(owners) == 0 {
					status.UnassignedThreads = append(status.UnassignedThreads, thread)
				}
			}
			sort.Slice(status.UnassignedThreads, func(i, j int) bool { return status.UnassignedThreads[i].ID < status.UnassignedThreads[j].ID })
			// The host supplies inventory and bindings from one immutable snapshot.
			// Streaming changes and edits to unrelated reports cannot stale this
			// content identity. Writes still use report revisions and binding checks.
			encoded, err := json.Marshal(status)
			if err != nil {
				return nil, err
			}
			hash := sha256.Sum256(encoded)
			status.Revision = hex.EncodeToString(hash[:])
			return json.Marshal(status)
		},
	})
}
