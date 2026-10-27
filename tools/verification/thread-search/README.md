# On-device thread search integration replay

```sh
./scripts/go.sh run -race ./tools/verification/thread-search
./scripts/go.sh test -race ./tools/verification/thread-search
```

Run from the repository root. This uses production runtime commands, SQLite,
the local artifact downloader, hashing/extraction, owned OS process groups and
the llama.cpp HTTP adapter. Each thread and input is synthetic. Tiny synthetic
weights and a self-executing protocol peer stand in for the actual model; no
real history, native profile, installed Harness, account or model service is used.
The download server and the peer's controlled inference service are loopback.
Temporary profiles are removed. A failed assertion exits nonzero.

The Go tests extend the same real artifact boundary with tiny tar fixtures:
forward/chained library aliases resolve to the original bytes,
survive reopening, and remain covered by integrity checks after same-length
corruption. Dangling and cyclic aliases cannot publish ready state. These tests
use the existing fixture asset options and require neither a real model download nor
an inference process; they do not prove real dynamic-library loading.

Production composition supplies only a profile directory to the local provider.
The fixture alone injects tiny pinned assets and a loopback download client. The
product has no configurable embedding origin or executable-path entry. The actual
spawned peer must receive the production host, pooling, context/batch, offline,
parallelism and logging flags, and a minimal environment containing a private
temporary local token. It validates the authenticated `/v1/embeddings` request
and the task prefixes. Controlled 768-dimensional vectors establish retrieval
mechanics and scoped Chinese semantic-only matches, **not real model quality**.

Coverage:

- Default-on search migrates former disabled/paused/metadata-only settings.
  Background setup uses the real verified downloader; failed assets back off,
  catalog events cannot duplicate an active download, and keywords remain usable.
  Asset readiness automatically starts content indexing without UI actions.
- Inference failure retries without a new catalog mutation; automatic batches,
  new/offline changes, asset reuse and joined shutdown remain covered. Internal
  maintenance configure/pause/remove commands retain serialized cleanup.
- Engine/model lengths and checksums are verified before ready. Corrupt assets,
  archive traversal and cancelled streaming downloads cannot publish ready state.
- Native process health, actual loopback HTTP, bounded/invalid responses,
  refused redirects, dropped TCP, cancelled compute and idle unloading use the
  production lifecycle. No model token or conversation is in argv or logs.
- Semantic-only scores below 0.70 are excluded, including the former 0.60
  floor; above-floor paraphrases remain eligible. Title, indexed-body and native
  folded metadata literals qualify independently, and unrelated scopes stay empty.
  These controlled score fixtures verify filtering, not real model quality.
- Unicode chunk overlap, checkpoint durability/reopening, unchanged-chunk reuse,
  free owner revision updates, concurrent query coalescing and keyword fallback.
- Automatic indexing of changed/new/offline content and persisted manual pause;
  old cloud/vector spaces are atomically discarded before automatic rebuilding.
- A reconciler already reading sources cannot restart after manual pause.
  Concurrent model removal/download actions serialize through joined cleanup;
  removal also excludes a second window enabling indexing before files are gone.
  Cancelling a staged replacement while inference is active preserves the prior
  ready installation instead of publishing the replacement after cancellation.
- Ordinary/application archive and reducer deletion remove derived data with
  their source transaction. Actual runtime history replacement cancels a blocked
  embedding process, deletes derived records while keeping future search automatic;
  delayed responses cannot restore history.
- Busy-only maintenance performs no text extraction or embedding; completed
  unchanged sources are reused across status polls and unrelated store writes.
  The completed-turn policy invalidates old derived documents.
- Four actual Harness text adapters and production Report reader-text projection
  omit internal-only/attachment/tool/reasoning fields as declared. Harnesses include
  only completed executions, retaining older completed turns while excluding
  running/failed/interrupted and unknown-execution messages. Public text may
  still contain user-visible file references. Private background/Moku are excluded.

Optional engine-only smoke (Apple Silicon):

```sh
./scripts/go.sh run -race ./tools/verification/thread-search \
  --verify-engine /absolute/path/to/llama-b11748-bin-macos-arm64.tar.gz
```

This requires the exact official archive, SHA-256
`003af1321ed9be9485902a2e17aad0c874a456c10f0a4ece5a735c495f3a3afb`.
It installs that archive through the production extractor and starts the actual
server with deliberately invalid tiny synthetic weights. Startup must fail
promptly and release the process. It does **not** download real weights, make
embeddings or prove model correctness. The regular replay needs no such archive.

Real weights, CDN downloads, Metal inference quality and production-scale resource
use are outside this fixture; production now prepares assets automatically. See the
[native UI replay](../../../demos/overview-thread-search/README.md) and
[model/configuration contract](../../../internal/services/threadsearch/README.md).

Search diagnostics replay also routes the production runtime and managed provider
through the real rotating JSONL writer. It checks operation correlation, indexing
counts, score summaries, cache reuse, inference failure with keyword fallback,
cancellation while queued and during inference, and exclusion of synthetic query
text, source identities, paths, vectors, credentials and unsafe error labels.

## Retrieval behavior regressions

```sh
./scripts/go.sh test -race ./internal/services/threadsearch ./tools/verification/thread-search
```

The manager tests use real SQLite and synthetic vectors to cover scope, metadata,
index changes, model availability, deletion during a cached request, clear/pause,
caller-owned hit slices, query priority/cancelled waiters, background rest and
checkpoint recovery after inference failure.
