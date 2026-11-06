# Native model discovery: current admission and source limits

Moku uses successful, nonempty native directory snapshots for **all selected
Harnesses**. The full returned inventory is available in the initial creation
tool schema; it is not deferred until the model requests discovery. Codex follows
all model/list pages. Source provenance remains a separate informational field:
`source.complete=false` does not block admission and is never flipped merely
because enumeration succeeded. Native cache/bundled fallback is accepted, with
freshness and remote completeness explicitly not guaranteed.

This supersedes the proof-gated interpretation in candidates `1b77b68`,
`03f4de6` and `d339fea`. The Codex static-file/version/strict-config path has been
removed, as have fixed source-proof rejections in Claude, OpenCode, Pi and Moku
context. No MDM/SDK attestation is required to use an otherwise working catalog.
See [the T3 comparison](../../plugins/harness/codex/t3-discovery.md).

## Admission, failures and lifecycle

- Each selected target is discovered; a missing target is never silently skipped.
  Cold startup waits for a native directory. Empty, malformed, duplicate-ID or
  failed directory acquisition produces an explicit error when no matching older
  snapshot is available. A later Codex page failure never publishes a prefix.
- Same-configuration successful snapshots return immediately, even when expired
  or while a refresh runs. Expiry after five minutes starts one owned background
  refresh. Failure retains the old snapshot without renewing its timestamp;
  retries have a 30-second cooldown. The exposed source basis notes a retained
  snapshot after a background refresh failure, without copying native secrets or
  raw error bodies into schemas. Cold failures still return their actual errors.
- Snapshots and failure state belong to the Harness instance. Close cancels and
  joins discovery. They are memory-only; after restart native acquisition runs
  again. This differs from T3's persisted provider status cache. Existing native
  caches can still supply the native response, but Moku does not import arbitrary
  transcripts or another application's status files.
- Keys bind the captured executable/environment, workspace and observable config/
  account inputs, including Codex system config/requirements/legacy managed files.
  A bounded dependency scan strengthens identity when possible. Scan failure
  falls back to explicit-root file generations with a distinct degraded key;
  cancellation still rejects. This is practical invalidation, not proof of every
  import, remote policy, MDM or credential helper. These limits no longer impose
  a formal-proof gate. Changes detected during acquisition reject publication.
- Enabled/disabled target changes and saved settings remain part of Runtime
  admission. New configuration cannot reuse an unrelated key. Runtime's initial
  Send, exact-ended renewal and native Accept guards remain in place before
  execution allocation; safe unconsumed-input retry behavior is unchanged.
- Creation resolves the actual target workspace and revalidates exact native
  model/thinking choices. A listed model with unknown creation capabilities stays
  visible in the inventory but cannot acquire a fabricated executable branch.
  Model availability at execution is not guaranteed by cached discovery.

Codex config/auto-review enrichment failure no longer discards an otherwise good
routing directory. Ordinary defaults/settings validation still checks those
errors. ChatGPT cold/background discovery has a best-effort three-second refresh
window, including the account-kind check and optional second enumeration. The
first complete result survives timeout, cache-stamp errors or failed rereads;
warm routing never waits for this window. Overall existing probe budgets remain
Codex 60s, Claude 45s, OpenCode 55s (30s native cancellation timer), Pi 30s, plus
owned cleanup. These are bounds, not measured startup times.

## What the native results do and do not say

**Codex.** T3's inspected main and pinned comparison files agree: successful full
native pagination is usable, including native fallback. Its refresh hint uses
`models_cache.json.fetched_at`; this file is shared by clients and is not an
account-specific attestation. Moku sets the same originator at spawn and initialize
and uses the timestamp only to decide whether to enumerate again.

**OpenCode.** Startup still crosses native activation, and existing native
catalog/account checks run. The separate plugin list is advisory and bounded to
three seconds, so its failure does not reject a usable model response. All cache
layers share and verify the detailed acquisition identity; the outer layer does
not relabel an older shallow-key result. The captured launch fix is retained: production
fingerprinting and launch use the same executable/environment, then recheck before
publication. A successful native snapshot is accepted without inventing remote
completeness. The
[T3 loader](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/packages/provider-opencode/src/server/status.ts#L486)
acknowledges later/partial discovery. OpenCode's
[models.dev plugin](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/core/src/plugin/models-dev.ts)
and [provider plugin](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/core/src/plugin/provider/opencode.ts)
can update later or handle remote failures internally. Refresh and native creation
checks remain useful; formal source receipts are no longer prerequisites.

**Claude.** Initialized nonempty model lists are accepted. Gateway discovery may
continue later, as described by the
[T3 provider](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/ClaudeProvider.ts#L340).
No sleep or stable-read heuristic is advertised as proof. Ordinary explicit model
validation is unchanged.

**Pi.** Successful RPC model inventory reads are accepted. `aborted/errors` from
SDK refresh, credential skips, fallback and superseded publication are still not
formal receipts; see the [SDK investigation](../../plugins/harness/pi/catalog-receipts.md).
That investigation is optional future observability work, not an admission gate.
Pi checks a completed catalog before caching, so a discovery-error observation
cannot overwrite a previous successful routing snapshot.

The Pi audit used installed `@earendil-works/pi-coding-agent@1.3.0` and nested
`@earendil-works/pi-ai@1.3.0`. SHA-256 records:
`model-runtime.js`: `578b742bea061fed029b8e139c6c0bcfe31e60665e9c0c6a08769761ef169dfd`;
`remote-catalog-provider.js`: `17e8f3482422aed20ba638b99a8862405f7d3be51c4ffc9eb7ffff1b030a421b`;
`pi-ai/dist/models.js`: `5624951d7fa7c436427b28ef6975051b91690e5e6341d84ab89ad3f1e1adc3d8`.

## Verification scope

Static call-path, publication/cleanup and diff review, Go build and lint only.
No tests were added or run; no native replay, CI, PR, push, system-prompt change
or main integration is part of this Sprint. Removing unconditional gates makes
normal native acquisition reachable; it is not a claim that all four installed
clients have been exercised successfully with the current user's accounts.

The follow-up [OpenCode/Claude T3 comparison](t3-native-discovery.md) records the
upstream best-effort behavior and differences. Runtime also distinguishes an
uninjected recovery-only Moku handle from a prepared execution owner: once idle,
normal preparation closes it and reopens with the complete injection instead of
reusing an owner without tools/callbacks. Native voice cannot attach to that
cleanup-only owner. See [Runtime recovery](../../core/runtime/README.md#moku-recovery-only-handles).
