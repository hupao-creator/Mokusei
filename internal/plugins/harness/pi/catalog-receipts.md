# Pi catalog source receipts: audited limits and proposed contract

Status: investigation/design only. No SDK bridge was installed or executed, and
no Pi inventory was promoted to complete. Under the updated policy, Pi accepts successful native RPC inventories for Moku
without requiring these proposed receipts. This document describes optional
stronger source observability, not a current admission prerequisite. Ordinary
explicit-model Threads retain their existing native validation.

## Audited implementation

The local npm packages `@earendil-works/pi-coding-agent@1.3.0` and nested
`@earendil-works/pi-ai@1.3.0` were read without executing them. Paths below are
relative to those package roots; version and source hashes are recorded in
[Moku source evidence](../../../services/moku/catalog-evidence.md).

`ModelRuntime.create` (`dist/core/model-runtime.js:79`) can ignore the result of
its initial refresh. A future bridge must use `refreshOnCreate:false` and capture
an explicit refresh result. It must honor `PI_OFFLINE`, inspect `getError()` for
configuration/composition/availability errors, and pin both package versions.
Older dependency compatibility can synthesize an empty error map; this is unknown,
not a success receipt.

The provider set must come from the effective composed native runtime, including
configured Radius gateways and custom providers, not just providers with models
in the available snapshot. A provider yielding no models might have failed.

| Native provider/source | Observed behavior | Required classification |
| --- | --- | --- |
| Standard builtins with `withRemoteCatalog` | Restores a stored overlay before network access; a 200 response can publish an overlay only if its Last-Modified is newer than the bundled generation | Success requires the accepted generation, actual overlay/bundled composition, valid complete response and final enumeration; a 200 alone is not enough |
| Same wrapper, HTTP 304 | Reuses stored models and advances checkedAt | Success only with a previously proven matching body and source/account identity; an arbitrary native cache body is unknown |
| Same wrapper, HTTP 404/501 | Persists lastModified=0 and succeeds while retaining/falling back to stored/bundled data | Fallback, never newly complete |
| Same wrapper, other HTTP failure | May write old/empty data and then throw | Error; store write is not success |
| OpenRouter | Refreshes pi.dev, then personalizes through `/models/user`; a missing key or endpoint 401/403/404 returns the input catalog; empty personalized lists fall back to builtins | Both catalog and personalization need receipts; distinguish fallback from successful account filtering, including a legitimately empty result |
| Radius and configured Radius gateways | Can import legacy OAuth gateway catalogs during the offline phase; network phase loads `/v1/config` | Legacy import is unverified cache, not fresh discovery; success requires validated gateway response, matching gateway/account and accepted publication |
| Custom `models.json`/extension provider | Composer may combine base refresh, extension refresh, model overrides and OAuth modifications | Unknown unless every participating source has an audited completion contract; do not omit the provider |
| Provider without a refresh method | Not visited by `Models.refresh` | Not success by default; a configured static authority must independently be proven |
| No resolved credentials | Cached state is restored; network phase returns without error | Skipped only if native effective auth and available-model checks prove genuinely unconfigured; an unsupported stored OAuth type or failed credential resolution is not an unconfigured provider |
| Offline/network-disabled | Restores cache but does not fetch | Skipped/offline with unknown completeness unless a trusted same-identity receipt exists |

Source locations:

- `pi-ai/dist/models.js:175`: per-provider refresh and credential skips;
  `:231`: unsupported stored OAuth and missing API-key resolution;
  `:138`: generation-checked publication.
- `coding-agent/dist/core/remote-catalog-provider.js:79`: ordinary wrapper;
  `:147`: personalized wrapper. Invalid entries can be filtered by the parser;
  a bridge must not infer a valid full response merely from nonempty output.
- `pi-ai/dist/providers/openrouter.js:21`: personalization fallback.
- `pi-ai/dist/providers/radius.js:26` and `radius-config.js:50`: legacy restore,
  gateway fetch and validation.
- `coding-agent/dist/core/provider-composer.js:397`: composition after base
  refresh; `model-runtime.js:587`: rebuild and refresh; `:335`: separate errors.

## Why a ModelsStore observer is insufficient

`publishProviderModels` serializes writes and checks generation/cancellation both
before and **after** persistence. A completed `write` can therefore be followed by
`publish` returning false with no in-memory update. A store observer cannot prove
that the enumeration consumed that data. Update-only publications have no store
receipt at all.

A superseded provider uses a combined provider/caller abort signal. Its exception
is omitted from `errors` when that combined signal is aborted, but the returned
`aborted` flag is based on the caller signal. Thus `aborted=false, errors={}` can
hide superseded providers. Also, `getModels`/`getAllModels` catch provider exceptions
and can return/omit empty lists; full enumeration needs per-provider read errors.
Patching objects returned by `getProviders()` is not a stable observation seam:
`ModelRuntime.refresh` rebuilds/recomposes providers before refreshing.

## Concrete next implementation

Add source receipts at the **native** provider and publication boundaries, exposed
through an SDK refresh result and an atomic RPC inventory response. Each expected
provider needs exactly one final receipt, with these non-secret fields:

- provider ID, refresh generation and final status: `success`, `skipped`,
  `fallback`, `error`, `aborted` or `superseded`;
- source kind and opaque source/account/configuration identity, including actual
  gateway and package/client generation;
- skip/fallback reason, HTTP/revalidation outcome where applicable, and the prior
  receipt ID when reusing trusted data;
- publication accepted flag, selected source/body digest and resulting inventory
  digest; configuration/composition/availability/enumeration errors;
- the full expected-provider set and one inventory generation shared by all rows.

Emit success only after the accepted publication and final enumeration. Missing
receipts, swallowed errors, unconfigured-provider ambiguity and superseded rows
make the whole candidate unknown. A genuine unconfigured skip still appears in
the receipt set; it does not silently disappear. An empty configured inventory
blocks under the existing admission requirement.

The Go bridge should resolve the SDK from the actual selected CLI, bind its Node
interpreter/environment and native model/auth paths, and compare identity before
and after acquisition. It must not log tokens or raw auth-bearing errors. OAuth
rotation remains native-owned; cancellation must drain native credential writes
and the child process before releasing ownership. A helper using a different SDK
or model store from execution cannot certify that execution's directory.

Persist only fully accepted, non-secret inventories plus validated receipts,
atomically and with a versioned identity contract. Native `models-store.json`
currently stores models/timestamps, not this proof; do not import it as trusted.
A single provider failure must not replace the old complete multi-provider
snapshot. Same-identity old proof returns immediately while refreshing; no valid
proof means bounded discovery, followed by explicit blocking on failure. Policy,
account, configuration or client changes invalidate that match.

This is an actionable native API change, not a current public SDK capability.
An SDK-only prototype may diagnose individual source paths, but without these
accepted-publication and source outcomes its provenance must remain unknown.
Unknown provenance does not prevent current native-inventory routing.
