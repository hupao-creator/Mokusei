# Thread search

This module owns derived search documents, scheduling and ranking. Harness and Application adapters supply public text; search does not open native conversations or discover model credentials. The [Overview](../../../app/macos/Sources/Host/Overview/README.md) supplies the visible thread scope and immediate keyword matches.

[manager.go](manager.go), [automatic.go](automatic.go) and [preparation.go](preparation.go) enable local model preparation and incremental content indexing automatically. While assets are unavailable, keyword search remains usable. Preparation failures retain retry state; successful setup resumes indexing without requiring a new thread event. Production inference uses [localembedding](../localembedding/README.md).

## Documents and queries

[documents.go](documents.go) uses versioned source fingerprints and 768-dimensional vectors. Content chunks contain up to 1200 runes with 150-rune overlap, metadata is bounded to 512 runes and titles to 128; a thread has at most 128 chunks. Compatible unchanged chunk hashes reuse vectors. Model-space/text-policy changes invalidate incompatible derived data.

[query.go](query.go) restricts results to the requested scope and current eligible owners. Keyword terms match as substring AND across the continuous indexed text (including metadata), independent of vector chunk boundaries. The literal text retains the same 128-chunk content bound and participates in the decoded-cache byte budget; the versioned index rebuilds older documents. Exact matches rank first, and semantic-only matches require cosine similarity of at least 0.70. A thread's best chunk supplies its semantic score. The implementation uses local exact vector comparison, not a remote search service. Busy sources and completed public content follow the owning adapter's eligibility rules.

[cache.go](cache.go) retains bounded decoded documents and query results; cache identities include source/configuration ownership. Query vectors are memory-only. Request cancellation and a final current-snapshot check prevent a stale result from escaping under a new scope or epoch.

## Deletion and lifecycle

Archive/delete/hidden-state changes invalidate the owner's derived document and explicit scope in the same authoritative transaction. Workers recheck source identity before inference and commit. History clear cancels requests, joins indexing and stops the helper before deleting the derived index and advancing the epoch. Verified public model assets remain cached. A failed process drain keeps the generation fenced.

`search:status` and `search:query` are cancellable reads; `search:configure`, `search:index` and `search:model` use validated explicit commands. Configuration revision is separate from routine index writes. The UI periodically refreshes the same search while preserving its last successful ranking.

Verification: [thread-search replay](../../../tools/verification/thread-search/README.md), plus `./scripts/go.sh test -race ./internal/services/threadsearch`. Synthetic assets/vectors exercise lifecycle and retrieval boundaries; actual model quality requires real-weight evaluation.
