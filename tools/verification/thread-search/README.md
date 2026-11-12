# Hybrid thread search integration replay

```sh
./scripts/go.sh run -race ./tools/verification/thread-search
./scripts/go.sh test -race ./internal/services/threadsearch
```

The replay uses production Runtime commands, Harness text adapters, Application
and Report projections, and SQLite in disposable synthetic profiles. The default mode does not open native sessions or use accounts/model assets.
Its controlled vector provider exercises lifecycle interleavings, not model quality.

It covers legacy search-configuration migration with source-byte preservation,
rejection of retired management commands, automatic body indexing, Chinese
substrings, AND terms with independently searchable first-term-only and
second-term-only candidates excluded in both query orders, title identifiers,
scope isolation, exclusion of paraphrase-only matches, archive/unarchive,
source updates, cache invalidation,
database reopening, history clearing, Application reducer deletion and Report
HTML text projection. The automatic-maintenance replay runs the production
manager, Application host and SQLite at 8 and 128 unrelated documents. Plugin
callback counts require zero unrelated projections for a busy owner/telemetry
write, one projection and extraction for one changed application, and atomic
owner-local body/stamp deletion. Unit tests additionally cover continuous Unicode body
bounds, busy-source deferral, cancellation, late-query fencing and unchanged
source reuse, plus metadata/body AND matching on cold and cached queries.

The [native Overview replay](../../../demos/overview-thread-search/README.md)
retains production UI coverage for metadata filtering, body-result updates,
query/scope cancellation, ranking and search/camera transitions.

## Native INT4 and offline verification

```sh
xcrun swift build --package-path app/macos --product MokuseiEmbedding
./scripts/go.sh run -race ./tools/verification/thread-search -native-only \
  -embedding-helper app/macos/.build/debug/MokuseiEmbedding \
  -model-directory "$PWD/.build/embedding-model"
```

This is the mandatory macOS `interop/embedding-search` CI check. It downloads the
pinned official 165 MB artifact if absent, checks it and runs real production
Runtime/SQLite retrieval with LiteRT. It asserts Chinese, English and cross-language
rankings, exact identifiers and thread uniqueness. A child-only sandbox denies
network access for cached-model restart, indexing/query inference and idle
exit/reload. A separate parent-exit probe verifies that inference cannot outlive
its Runtime owner. Corrupt model bytes must be refused; interrupted staging is reclaimed,
and explicit retry recovers after a valid asset is restored. Archive and history
clear must revoke real semantic results. No Harness model task/account is used.

The default Runtime replay additionally covers content-addressed vector reuse,
equal-dimensional incompatible model spaces, late old-owner completion,
physical vector-row cleanup and keyword fallback/retry when the vector database
cannot open. The native Overview launcher runs 17 production-backed tests,
including visible model preparation followed by unchanged thread cards in hybrid
mode. Its three display/launcher-gated cases are not counted as executed by a
plain filtered Swift test run.

For signed-package acceptance, pass the packaged `Contents/MacOS/MokuseiEmbedding`
to the same native command. The package also verifies its own model-independent
linkage probe after stripping development rpaths and signing the dylib/helper.

## Optional private corpus evaluation

```sh
./scripts/go.sh run ./tools/verification/thread-search \
  -evaluate-store /absolute/profile/mokusei-go-state-v1/state.sqlite \
  -evaluation-output .build/embedding-evaluation
```

The extractor opens the source SQLite database read-only in a consistent
transaction and invokes production Harness public-text adapters. It excludes
private, archived, incomplete and unavailable text. It writes only the resulting
public corpus and a coverage summary into the specified private local output;
never commit real corpora or labels. This path is opt-in and is not run by CI.

Create a local query JSON array with `id`, `query`, `relevant` thread IDs and
`split` (`tune` or `holdout`), then run:

```sh
./scripts/go.sh run ./tools/verification/thread-search \
  -evaluation-corpus .build/embedding-evaluation/corpus.json \
  -evaluation-queries .build/embedding-evaluation/queries.json \
  -evaluation-output .build/embedding-evaluation -evaluation-variant final \
  -embedding-helper app/macos/.build/debug/MokuseiEmbedding \
  -model-directory "$PWD/.build/embedding-model"
```

`keyword`, `baseline`, `conservative`, `strict`, `short`, `coherent` and `final`
select fixed comparison configurations; `final` consumes production defaults.
Every configuration runs the real Runtime retrieval code, not a duplicated
Python implementation. Vectors are reused only when their space/pipeline matches.
Reports contain first/third-position hit counts, reciprocal rank, labelled
precision, unrelated-query rejection and timing. The readiness loop samples at
100 ms, so reported latency includes sampling quantization and cold model loads;
it is not a UI latency or hardware-independent SLA.
