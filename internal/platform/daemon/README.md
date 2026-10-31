# Profile ownership and service lifetime

[manager.go](manager.go) and [service.go](service.go) own start/status/stop, discovery and the exclusive profile lease. Application construction happens inside that lease. The daemon releases it after all application cleanup and admitted calls have completed, including cleanup that reports an error.

From the repository root, build with `make runtime`, then manage a selected profile:

```sh
.build/go/mokusei-runtime start --data-dir /absolute/profile
.build/go/mokusei-runtime status --data-dir /absolute/profile
.build/go/mokusei-runtime stop --data-dir /absolute/profile
```

Client disconnection does not cancel accepted work. Explicitly quitting the Mac app requests coordinated service shutdown.

Status validates private discovery before probing its endpoint. If the recorded
owner has died, a failed health probe is stale discovery even when a reused port
returns a typed HTTP rejection or a foreign health response. Caller cancellation
and local metadata failures remain errors; a live owner retains the original
rejection. Management operations refresh profile identity after a directory has
been created so an earlier path spelling does not produce another owner.

Coordinated shutdown cancels both read and write calls before waiting for them.
It retains the management endpoint and profile lease until admitted calls return
and write receipts are settled. An HTTP client disconnect cancels only its reads.

## Failed shutdown

Application cleanup failures are recorded as `runtime.shutdown.failed` before diagnostics close and in the detached process log. The stop caller receives the cleanup error, but the daemon still retires discovery, closes management connections, releases ownership and exits. A completed error never leaves a permanent stopping owner.

While cleanup is pending, authenticated `/health` reports `status: stopping`; ordinary commands are rejected and exclusive ownership remains held. Start/reopen waits up to two minutes for this owner to retire before starting a replacement. Existing profile data is retained. A late native exit helper carries the old epoch and cannot stop the replacement.

Logs live under the selected profile at `runtime/debug-logs/service.jsonl` and `runtime/process.log`.

If an `Ensure` child loses the ownership guard before a competing child publishes
its owner record, it waits for the competitor's existing private launch receipt.
Pending launches are read before the owner record to cover that handoff; errors
from either metadata read remain errors. A pending receipt never proves success:
the existing health/identity check must still confirm the published service.
The original two-minute deadline, cancellation barrier and fail-closed behavior
for an occupied port without a known pending launch remain unchanged. This
guarantee covers children using `AwaitLaunch`, not an unidentified foreground
process holding the port. Deterministic real-process tests in `manager_test.go`
cover the prepublication window and absent/invalid launch or owner metadata.

Native worker cleanup treats a reaped process group or a group containing only
zombies as stopped. On macOS, a signal probe for a zombie-only group returns
`EPERM`; bounded process-table inspection must establish that no member can
execute before cleanup succeeds. A live member or failed inspection cannot
turn a permission error into successful shutdown.

Verification: `./scripts/go.sh run -race ./tools/verification/runtime-helpers` and `./scripts/go.sh test -race ./cmd/mokusei-runtime`. On macOS, add `--swift-shutdown` to the helper replay for the actual Swift status/start/stop path through failed shutdown and same-profile reopening, dead/live owners on reused ports, unsafe metadata and cancellation. The [transport replay](../../../tools/verification/transport/README.md) also exercises real daemon shutdown with pending read/write HTTP calls and receipt recovery.
