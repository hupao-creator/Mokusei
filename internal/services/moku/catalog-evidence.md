# Native catalog evidence and unresolved limits

Moku now requires **both** complete enumeration and authenticated source
completeness at its final Runtime new-execution boundary. These are separate
fields in the snapshot. Nonempty data, all pagination pages, initialization,
plugin activation, stable reads and elapsed time do not promote source evidence.

The currently audited Codex, OpenCode, Claude and Pi interfaces have no source
attestation this implementation can substantiate. Their adapters explicitly
produce unknown source evidence. Therefore a Moku target using any of these
interfaces **blocks a cold start without a trusted matching snapshot**. This is
a deliberate safety/availability tradeoff required by the strict acceptance
criterion, not a usable full-directory implementation or a claimed native pass.
An older enumeration-only cache is not migrated/promoted into trust.

Ordinary explicit-model selection and validation remain available. Enumeration
caches and evidence-checked routing caches are separate. Only successful source
verification may publish to the latter; unknown source refreshes leave trusted
older snapshots and their original evidence intact. A trusted matching snapshot
returns immediately even when expired. Unsupported evidence is checked inside
the cache probe, so it cannot hide an already trusted same-key value. No source
attestation override, static replacement catalog or timing heuristic is provided.

A future authoritative adapter must obtain a native completion/provenance result
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
- [Pi's RPC model list](https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/modes/rpc/rpc-mode.ts)
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
