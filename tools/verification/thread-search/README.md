# Keyword thread search integration replay

```sh
./scripts/go.sh run -race ./tools/verification/thread-search
./scripts/go.sh test -race ./internal/services/threadsearch
```

The replay uses production Runtime commands, Harness text adapters, Application
and Report projections, and SQLite in disposable synthetic profiles. It does not
open native sessions or use accounts, model assets or inference services.

It covers legacy search-configuration migration with source-byte preservation,
rejection of retired management commands, automatic body indexing, Chinese
substrings, AND terms with independently searchable first-term-only and
second-term-only candidates excluded in both query orders, title identifiers,
scope isolation, exclusion of paraphrase-only matches, archive/unarchive,
source updates, cache invalidation,
database reopening, history clearing, Application reducer deletion and Report
HTML text projection. Unit tests additionally cover continuous Unicode body
bounds, busy-source deferral, cancellation, late-query fencing and unchanged
source reuse, plus metadata/body AND matching on cold and cached queries.

The [native Overview replay](../../../demos/overview-thread-search/README.md)
retains production UI coverage for metadata filtering, body-result updates,
query/scope cancellation, ranking and search/camera transitions.
