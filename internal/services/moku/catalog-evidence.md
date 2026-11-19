# Native model catalog admission

Moku uses successful nonempty native inventories for all selected Harnesses.
The initial `create_thread` schema includes each complete returned inventory,
including identities that lack executable thinking choices. Enumeration and
remote source provenance are separate: `source.complete=false` is informational,
not an admission rejection. Native cached/bundled fallback is accepted without
claiming freshness or complete remote/account discovery.

## Cache and execution boundary

Each selected target must return a usable directory. Empty, malformed,
duplicate-ID or failed cold acquisition returns an error; Codex follows all
`model/list` pages and never publishes a failed prefix. Matching complete
same-configuration caches return immediately while expired or refreshing.
Five-minute expiry starts owned background refresh; failures keep the last
success without renewing freshness and use a 30s retry cooldown. Close cancels
and joins probes. Caches are Harness-instance memory, not persisted by Moku.

Keys capture executable/environment, workspace and observable configuration/
account inputs. Bounded dependency scanning strengthens the identity; errors
use explicit-root generations and a degraded marker, while cancellation rejects.
Detected changes fence publication. Unknown transitive imports, remote policy,
keychain and credential helpers prevent a completeness claim, not all routing.

Execution resolves the actual workspace and validates native model/thinking
choices again. Settings and target enablement participate in Runtime's final
execution admission. Cached catalog presence is not current availability.

## Harness capability limits

| Harness | Current directory boundary | Limit |
| --- | --- | --- |
| [Codex](../../plugins/harness/codex/README.md) | Full paginated native inventory, matching originator at spawn/initialize; best-effort 3s ChatGPT cache-refresh hint | Shared cache timestamp is not account attestation; enrichment failure does not discard a usable routing list |
| [Claude](../../plugins/harness/claude/README.md) | Native initialized nonempty list for Moku routing | Does not prove later gateway/provider discovery complete; ordinary/custom execution validation is separate |
| [OpenCode](../../plugins/harness/opencode/README.md) | Native catalog with account filtering, captured source checked before publication | Advisory plugin inventory has a 3s budget; working response does not prove every remote provider finished |
| [Pi](../../plugins/harness/pi/README.md) | Successful completed nonempty RPC observation, offline native discovery | RPC does not expose every SDK load error/publication receipt; a usable list is not formal source proof |

Owned probe work budgets are Codex 60s, Claude 45s, OpenCode 55s (30s native
cancellation timer), Pi 30s, plus joined cleanup. These are code budgets, not
measured startup times. Ordinary defaults/settings use strict reads; Moku routing
alone uses stale complete snapshots. Codex strict reads also expire a completed
observation early after a compatible native cache write. No sleep/stable-list
heuristic establishes remote completeness.

Source: [shared cache](../../platform/discovery/cache.go),
[source identity](../../platform/discovery/source.go),
[Moku target schema](tool_schema.go), and the Harness guides above.
The [desktop e2e runner](../../../tools/e2e/README.md) uses an installed Codex
CLI and a private provider during preparation. The [Codex catalog property](../../plugins/harness/codex/catalog_property_test.go)
checks compatible cache writes around a strict read. Live account directories
and refreshes of other Harnesses need separate evidence.
