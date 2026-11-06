# OpenCode and Claude discovery compared with T3 Code

The local-source search from the Codex investigation did not find a T3 checkout.
This follow-up read GitHub main. `ClaudeProvider.ts` and OpenCode's `status.ts`
matched pinned revision `2e39f1d7dec44c98a4cabdaf99d3d99209f770c0` byte-for-byte
when fetched. No native client or probe was executed for this comparison.

## OpenCode

[T3 v2 loader](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/packages/provider-opencode/src/server/status.ts#L486)
repeats native lists every 250ms until two nonempty fingerprints agree, within a
five-second budget. Its closure retains `lastLoaded`. A later read error uses the
latest nonempty result from that attempt; timeout uses fresh progress if present,
otherwise the old list. The code explicitly calls fresh progress potentially
partial. Stable reads are a startup heuristic, not formal completeness proof.
The [status projection](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/packages/provider-opencode/src/server/status.ts#L610)
reports nonempty discovery as ready, empty discovery as warning, and failures as
error with settings-derived custom-model fallback.

Moku retains its existing activation/read/account-projection lifecycle and
five-minute same-source stale-while-refresh cache, rather than adding the extra
stable-read loop. It accepts a successful native snapshot without claiming
remote completeness. The optional plugin-list request has a three-second budget;
missing/failed/unsettled plugin diagnostics cannot by themselves reject an
otherwise usable model response. Actual model/required native read failures,
malformed/empty inventories and source changes still reject a replacement.

The reviewed cache bug was Moku-specific: an outer detailed key could wrap an
inner shallow-key result and relabel configuration A's list as B. Editor,
complete, advisory and routing cache lookups now use one detailed observed source
identity. Acquisition publishes that identity, cache hits verify it, and routing
checks it again instead of overwriting it. A current source check alone cannot
prove the identity of an older cached body. This does not add a provenance gate.
The dependency scanner still has the previously documented practical fallback.

## Claude Code

[T3 capability discovery](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/ClaudeProvider.ts#L338)
uses SDK initialization with a 25-second capability budget. Optional usage has
its own deadline and cannot discard initialization. For a machine probe with
gateway discovery enabled and a custom Anthropic endpoint, it keeps the process
alive for the configured discovery grace period (default three seconds), to let
the native shared cache refresh; it does not claim that init models now prove
complete remote discovery. Workspace-only probes omit that grace period.

[T3 model projection](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/ClaudeProvider.ts#L628)
combines a version-filtered bundled catalog, native reported additions and custom
settings. Capability/auth probing failure produces warning/unknown auth without
emptying that model list. This is an intentional product fallback, not a native
attestation. Moku has no corresponding maintained bundled/versioned Claude
manifest or custom-model overlay in this adapter. It keeps native init inventories
and matching old snapshots instead, does not fabricate a fallback catalog, and
does not add a gateway sleep that would only warm a cache without rereading the
inventory. Cold native failure without an older directory remains an explicit
error. This is a documented difference, not claimed parity or a proof requirement.

## Shared caches and failure policy

[T3 registry](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/ProviderRegistry.ts#L171)
retains eligible prior rows after failed/incomplete probes; OpenCode successful
refreshes may replace removed rows, while Claude's default merge retains missing
noncustom rows. Its
[status cache](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/providerStatusCache.ts)
persists per-instance snapshots and correlates instance/driver/enabled state on
hydration. Moku caches remain in memory and are keyed to observed native source
inputs. Refresh failure retains the entire old matching snapshot; successful
refresh replaces it rather than unioning removed models. Old data is available
immediately while refresh runs, with an exposed failure note and cooldown. A new
source cannot borrow the previous source's result; restart reacquires a native
snapshot (which may itself use native disk caches).

T3's loader/status files have no counterpart to Moku's Runtime recovery handle,
full injected tool set or final execution admission callback. That lifecycle fix
is derived from Moku's own ownership/locking contract, not attributed to T3.
After a Stop-before-discovery recovery, normal preparation retires the idle
uninjected handle and opens a fully injected one. No settings change or user input
is authorized by a cache hit alone; final execution/native creation checks remain.

Verification here is static source/call-path review, Go build and lint. No tests,
regressions, native replay or CI were run. The main worktree was not changed and
no merge was performed. Runtime voice/service guards were read against local
main `5b51a66`; this is not an integrated-main execution result.
