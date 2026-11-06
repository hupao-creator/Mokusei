# Native catalog evidence and unresolved limits

Moku now requires **both** complete enumeration and authenticated source
completeness at its final Runtime new-execution boundary. These are separate
fields in the snapshot. Nonempty data, all pagination pages, initialization,
plugin activation, stable reads and elapsed time do not promote source evidence.

One narrow production source is now supported: **Codex 0.166.0's native
explicit-config static catalog**, for the unmodified OpenAI provider. Its
`model_catalog_json` must already select the absolute `CODEX_HOME/models.json`
path (`~/.codex/models.json` with the default home). Moku does not manufacture or
truncate this file. Routing launches the captured client with `--strict-config`,
checks effective `config/read`, rejects managed model/provider overrides via
`configRequirements/read`, checks the initialized client version and every configured
model ID against the fully paginated native list, and unchanged file/configuration
before publication. Missing auth-filtered IDs also reject this conservative path.
The file's absence/content and binary/account/environment belong to the cache key
before lookup. This is completeness of the **explicitly configured native
catalog**, not a claim to list every model an upstream service might offer.

This supplies an actual production writer to the routing cache. Complete matching
snapshots remain immediately usable when stale, with background refresh and
failure retention. The cache is still memory-only: a new adapter repeats strict
native acquisition; no previous-process cache is silently trusted. Cold startup
has the existing 60-second discovery budget (including native managed-config or
account loading); a warm same-source lookup does not wait for network refresh.
Changing the file, account inputs, selected executable, environment or tracked
configuration requires a new snapshot. Unsupported versions/providers/paths,
default remote Codex discovery, OpenCode, Claude and Pi still block Moku without
proof. **This is not all-Harness acceptance and must not be integrated as such.**
The selected Harness set is never silently reduced to this supported subset.

Ordinary explicit-model selection and validation remain available. Enumeration
caches and evidence-checked routing caches are separate. Only successful source
verification may publish to the latter; unknown source refreshes leave trusted
older snapshots and their original evidence intact. A trusted matching snapshot
returns immediately even when expired. Unsupported evidence is checked inside
the cache probe, so it cannot hide an already trusted same-key value. No source
attestation override, manufactured replacement catalog or timing heuristic is provided.

Other authoritative adapters must obtain a native completion/provenance result
bound to the exact provider/account/client/configuration and any asynchronous
source failures, then validate it before setting the snapshot's source evidence.
Simply flipping `Complete` on the existing list response is not an implementation
of that contract. This Sprint does not change external native clients.

## Evidence inspected

- [Codex pagination in T3 Code](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/CodexProvider.ts#L363)
  follows `nextCursor`. Moku now does the same, including hidden models, and
  rejects missing termination, invalid/repeated cursors, malformed entries and
  duplicate IDs. A later-page failure returns no accumulated result, so it cannot
  replace a successful cached inventory.
- [Codex 0.166.0 native model manager](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/models-manager/src/manager.rs)
  catches refresh failures and can retain/fall back to bundled model metadata.
  Its [public response](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server-protocol/src/protocol/v2/model.rs)
  provides pagination, but does not expose remote-discovery success or catalog
  provenance. Exhausting cursors proves enumeration, not absence of native
  fallback. Moku does not read a shared `models_cache.json` timestamp as proof of
  this process/account/client's successful refresh. Spawn and initialize now use
  the same `mokusei_desktop` originator, avoiding the known pre-initialize client
  mismatch. This does not itself prove an online fetch succeeded.
- [OpenCode's T3 loader](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/packages/provider-opencode/src/server/status.ts#L486)
  explicitly acknowledges partial results despite repeated/stable reads. Moku
  does not use that heuristic. In audited OpenCode 2.0.25,
  [RPC handling](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/server/src/handlers/rpc.ts)
  waits for `Plugin.awaitActivation`; Moku's existing startup `refresh` RPC
  crosses that barrier before catalog reads. Missing/failed plugin inventory now
  rejects the snapshot. This proves announced plugin activation settled, not
  completion of arbitrary future plugin/remote discovery.
- OpenCode's [models.dev plugin](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/core/src/plugin/models-dev.ts)
  can apply later background catalog updates. Its
  [OpenCode provider plugin](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/core/src/plugin/provider/opencode.ts)
  can handle a remote configuration failure internally. Neither a nonempty
  `/api/model` result nor the activation barrier proves all remote sources
  finished successfully. This remains an unresolved completeness boundary;
  supporting arbitrary such sources requires native completion/provenance
  evidence, not a longer timeout or a static list.
- [Claude gateway discovery in T3 Code](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/ClaudeProvider.ts#L340)
  continues after initialization. This uncertainty is now confined to Moku
  routing. Shared Claude `readCatalog` does not query or reject gateway
  completeness, so normal explicit-model creation can use the initialized list.
  `initialize` is enumeration evidence only, not a source-completion signal.
- Historical [Pi's RPC model list](https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/modes/rpc/rpc-mode.ts)
  returns `getAvailableSnapshot`; the
  [registry facade](https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/core/model-registry.ts)
  exposes load errors separately. RPC model results do not attest that source
  loading completed without fallback/errors. Offline mode and disabled
  extensions do not supply that missing evidence, so Pi is also unknown rather
  than an assumed exception.

## Final admission and unconsumed input

Runtime checks initial Send, exact-ended successor renewal and native Accept
through one guard before its only three execution-ID reservations. `Commit`
already refuses unreserved IDs. The prepared injection binds immutable catalog
and settings evidence to its handle; native Open cannot start Moku work before
that handle is published. Direct Runtime Send callers also own configuration
admission. Background work and coordinator `live` observations cannot bypass the
final guard. Unknown source failure does not allocate a new execution or call
native Send/project.

Only exact configuration-pending responses permit automatic reprepare. Core
pre-consumption failures carry an exact `MokuAdmissionRejectedError` so pending
outbox attempts can be released safely, including after exact native
`ErrExecutionEnded`. Wrapped/uncertain native outcomes never become proof of
non-consumption. Existing executions may still be steered with their originally
admitted configuration; new foreground work with pending settings waits for
background work to drain.

## Configuration, account and client scope

Moku routing identity uses the actual resolved executable/environment from the
probe launch. Codex captures its selected `ExecutableTarget` and starts that exact
client; OpenCode similarly captures the executable/environment before startup.
Claude and Pi retain their resolved launch inputs. Routing inspection includes
lexical/canonical ancestors, native namespaces (`.codex`, `.opencode`, `.claude`,
`.pi`), symlinks and recognized literal file references. It rechecks dependencies
and launch identity after acquisition. Reads are bounded and failures reject
identity rather than treating missing evidence as a match.

This is not a complete parser for arbitrary native imports, commands or remote
includes. Computed dependencies, unknown reference syntax, external credential
helpers and concurrent filesystem ABA changes do not gain an affirmative source
attestation from a local hash. Such sources remain unverified and cannot seed a
trusted Moku cache. Native ordinary validation keeps its existing enumeration
path instead of receiving this extra Moku-only completeness gate. Cached entries are
memory-only and never imported from another application process or historic
conversation. Known source changes cannot reuse an older configuration's cache;
matching old directories are allowed to be outdated and are labeled accordingly.

OpenCode 2 credentials live in the native database, not only `auth.json`. The
cache key now includes a read-only digest of non-secret credential identity,
selection and revision columns from the
[native credential table](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/core/src/credential/sql.ts).
Unrelated session writes do not change this digest. Database read/schema failure
prevents claiming an account match. Credential revision changes, including some
token rotations, conservatively require rediscovery; no credential values are
read, logged or persisted by this identity check.

Claude also tracks its account settings file and the usual macOS login keychain
file; Codex tracks that keychain file, the default CLI path and standard desktop
binary in addition to its existing home/config/auth inputs. These are local
invalidation signals, not a universal account attestation. Custom keychains,
external credential helpers, untracked configuration includes and remote policy
changes cannot all be proven unchanged from these signals. A source with those
unobservable identity/completion changes cannot be claimed to satisfy the
strongest completeness/current-account requirement. Native creation validation
still protects the selected execution; it cannot prove an unenumerated model
was not missed during routing.

## Verification scope

No new test cases, regression runs, native CLI replay or CI are part of this
Sprint. Existing fixtures were adjusted only for changed contracts. Local
`go build ./...`, `make lint`, diff review and static lifecycle/publication review
cover compilation and structural correctness, not the unresolved native-source
claims above. These limits must be reported with the local commit, not presented
as a successful full-model-directory acceptance result.

## Follow-up source audit and usable alternatives

Codex source selection is checked against revision
`6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`:

- [`build_models_manager`](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/thread_manager.rs#L509)
  passes the loaded configured catalog into the selected provider.
- [`ConfiguredModelProvider::create_models_manager`](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/model-provider/src/provider.rs#L549)
  selects `StaticModelsManager` before the remote manager when that catalog exists.
  Bedrock/GCP and overridden provider configurations are outside this implementation's proof.
- [Startup fallback](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server/src/lib.rs#L575)
  is disabled by strict config. The same flag also prevents catalog reload fallback
  in `config_manager.rs`. Ordinary Thread launch does not gain this extra flag.
- [`load_model_catalog`](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/config/mod.rs#L2280)
  parses native `ModelsResponse`; this is not a generic list of model names.
  To use this path, supply the complete authoritative native-format file, select
  it in native config, use audited Codex 0.166.0 and select only supported Harnesses
  in Moku. Mokusei does not generate this authority from a possibly partial list.

Pi was additionally inspected from installed npm package
`@earendil-works/pi-coding-agent@1.3.0`, including its nested `@earendil-works/pi-ai@1.3.0` implementation:

- `dist/core/model-runtime.js:587`: `refresh` returns `aborted` and provider
  `errors`, but the compatibility path synthesizes an empty error map if an older
  dependency returns void. Availability failures can instead appear in `getError`
  (`:335`). A successful return alone is insufficient.
- Nested `@earendil-works/pi-ai/dist/models.js:175`: cached provider state is
  restored first. Missing resolved credentials skip the network phase without an
  error. A legitimate unconfigured provider must be distinguished using native
  `getProviderAuthStatus`/`checkAuth` and the available-model snapshot; it is not a
  failed configured provider. Credential resolution failures are errors.
- `dist/core/remote-catalog-provider.js:79`: 404/501 persists a zero
  `lastModified` and succeeds with old/bundled data; 304 reuses the stored body;
  successful remote overlays only apply when newer than the bundled generation.
  OpenRouter personalization can also fall back when its list is empty. Therefore
  `aborted == false` plus `errors.size == 0` is not a source attestation.

A Pi SDK bridge is a viable next implementation route only if it observes each
configured provider's actual publication/source receipts, validates dependency
versions, checks configuration/composition/availability errors, distinguishes
missing credentials from fallback, and binds the same SDK, model store and auth
inputs used by RPC execution. None of that is claimed by the current RPC adapter.
Adding a bridge that merely calls `refresh` would certify the known counterexample.
For OpenCode/Claude, the concrete protocol extension needed is an atomic inventory
snapshot with source completion/failure and configuration/account generation;
activation/initialization alone is not that contract. Until available, ordinary
explicit-model Threads are usable; strict cross-Harness Moku including these
sources remains unavailable. Disabling the guard is not an alternative delivered
by this patch.

OpenCode production discovery now uses `NewSettings(host, nil)` and the shared
`captureLaunch` resolver. The environment and absolute executable used in its key
are passed directly to `NewRuntime`; the old production callback that resolved
again is gone. Publication and final acquisition re-resolve and compare the
source key, rejecting changes. Injected test factories remain separate from this
production path. This fixes launch identity, not native source completeness.

For reproducible Pi source review, SHA-256 of the installed files above:
`model-runtime.js`: `578b742bea061fed029b8e139c6c0bcfe31e60665e9c0c6a08769761ef169dfd`;
`remote-catalog-provider.js`: `17e8f3482422aed20ba638b99a8862405f7d3be51c4ffc9eb7ffff1b030a421b`;
`pi-ai/dist/models.js`: `5624951d7fa7c436427b28ef6975051b91690e5e6341d84ab89ad3f1e1adc3d8`.
These are static inspection records, not native execution results.
