# Native catalog evidence and unresolved limits

The cache change guarantees immediate reuse of a complete same-key **native
response inventory**, background refresh with failure retention, and no partial
pagination publication. It does not prove that a native engine exposed every
model its remote providers could eventually discover. The stronger end-to-end
"all models for every selected Harness" acceptance criterion is therefore **not
established for all configurations** by this change. Build/lint and static review
are not native protocol or account tests.

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
  continues after initialization. Moku now checks the native effective settings
  and rejects gateway discovery with a custom base URL when completion cannot
  be established; an omitted effective-settings response also fails. It does
  not sleep for the gateway timeout and relabel initialization as complete.
  Ordinary Claude evidence is the correlated successful initialize response's
  model list, not elapsed time. This is not proof for arbitrary gateways or
  future clients with different initialization semantics.

## Configuration, account and client scope

Each retained directory is bound to the adapter's native environment, workspace,
configured executable and tracked source-file fingerprint. Cached entries are
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
