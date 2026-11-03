# Thread search

This module owns derived keyword-search text, background indexing and ranking.
Harness and Application adapters supply public text; search does not open native
conversations, discover credentials, download models or perform inference.
The [Overview](../../../app/macos/Sources/Host/Overview/README.md) supplies the
global eligible thread scope and immediate folded metadata matches, independent
of its active browsing tag. This includes directory-only documents and tasks
covered by reports; hidden and archived owners remain excluded.

## Documents and queries

[documents.go](documents.go) stores a bounded continuous text projection under
`keyword-text-v1`. Metadata is bounded to 512 runes and body content to 134550
runes, retaining the former indexed-body coverage. Busy sources wait until their
owner settles. Unchanged source hashes reuse current documents without extracting
history again. The decoded document cache has a 64 MiB budget; the result cache
holds at most eight queries.

[query.go](query.go) matches whitespace-separated terms as substring AND across
metadata and indexed body text. Native case/diacritic/width-folded metadata
matches qualify independently. Exact title substrings rank ahead of other
literal matches. Results are restricted to the requested live scope and current
eligible owners. Cancellation and final owner/epoch validation prevent stale
results from escaping after changes, archive, deletion or history clearing.
There are no vector scores or paraphrase-only matches.

## Compatibility and lifecycle

Opening an old search configuration migrates only `search-config`, derived
`search-document:*` and retired `search-usage` records. Old disabled/paused model
settings do not disable keyword search. Source conversations, reports,
preferences and other settings are preserved. Old model files remain on disk
unused; this version neither reads nor deletes them. Background indexing rebuilds
body text without network access, while metadata search is immediately usable.

Archive/delete/hidden-state changes remove derived text in the owner's transaction.
History clear cancels queries and joins indexing before clearing derived text and
advancing the epoch. Remaining `search:status` and `search:query` operations are
cancellable reads. Retired model/configure/index management commands are rejected.
The UI periodically refreshes active queries as body indexing completes.

Verification: [thread-search replay](../../../tools/verification/thread-search/README.md)
and `./scripts/go.sh test -race ./internal/services/threadsearch` cover real
SQLite indexing, cache invalidation, migration, bounds, cancellation and lifecycle.
