# Thread search

This module owns derived keyword-search text, background indexing and ranking.
Harness and Application adapters supply public text; search does not open native
conversations, discover credentials, download models or perform inference.
The [Overview](../../../app/macos/Sources/Host/Overview/README.md) supplies the
global eligible thread scope and immediate folded metadata matches, independent
of its active browsing tag. This includes directory-only documents and tasks
covered by reports. Archive and existing terminal visibility exclusions still apply.
Attention Agent collapse only changes browsing, so those threads remain searchable.

## Documents and queries

[documents.go](documents.go) stores a bounded continuous text projection under
`keyword-text-v2`. Metadata is bounded to 512 runes and body content to 134550
runes, retaining the former indexed-body coverage. Automatic maintenance diffs
immutable owner records and projects only the changed ordinary Threads or declared
Application collections. Telemetry, other application collections and derived
index commits do not enumerate sources. Busy sources wait for their next owner
change; they do not keep a periodic global scan alive. Failed extraction retains
bounded exponential retry, independent of incoming event volume.

Each indexed body has a bounded stamp containing its source/body hashes, pipeline
version and truncation flag. Status and index freshness read these stamps without
decoding body text; unchanged sources do not extract history again. Body and stamp
commit atomically under the owner/epoch fence. Their keys share an owner prefix,
so deleting one source only removes its own derived rows. The decoded query-body
cache has a 64 MiB budget; the result cache holds at most eight queries.

Initial discovery, source-registration replacement and history-epoch changes
reconcile the complete eligible set. Explicit status/query reads may enumerate
the requested catalog; the automatic scheduler never uses global status as its
work queue. A coalesced store notification still discovers every changed owner
by comparing snapshots, and cancellation never acknowledges unfinished work.

[query.go](query.go) matches whitespace-separated terms as substring AND across
metadata and indexed body text. Native case/diacritic/width-folded metadata
matches qualify independently. Exact title substrings rank ahead of other
literal matches. Results are restricted to the requested live scope and current
eligible owners. Cancellation and final owner/epoch validation prevent stale
results from escaping after changes, archive, deletion or history clearing.
There are no vector scores or paraphrase-only matches.

## Compatibility and lifecycle

Opening an old search configuration migrates only `search-config`, derived
`search-document:*`, `search-document-stamp:*` and retired `search-usage` records.
The v2 pipeline rebuilds only this derived state to establish owner-addressed keys
and independent freshness stamps. Old disabled/paused model
settings do not disable keyword search. Source conversations, reports,
preferences and other settings are preserved. Old model files remain on disk
unused; this version neither reads nor deletes them. Background indexing rebuilds
body text without network access, while metadata search is immediately usable.

Archive, deletion and changes that revoke the owner’s original search eligibility remove derived text in the owner's transaction.
History clear cancels queries and joins indexing before clearing derived text and
advancing the epoch. Remaining `search:status` and `search:query` operations are
cancellable reads. Retired model/configure/index management commands are rejected.
The UI periodically refreshes active queries as body indexing completes.

Verification: [thread-search replay](../../../tools/verification/thread-search/README.md)
and `./scripts/go.sh test -race ./internal/services/threadsearch` cover real
SQLite indexing, cache invalidation, migration, bounds, cancellation and lifecycle.

## Moku deterministic grep

[grep.go](grep.go) scans authoritative ordinary-thread sources supplied by Runtime,
without using the derived index to exclude candidates. It reuses the Harness
public-text extraction boundary through `SearchPassageAdapter`; the existing
`SearchText` index projection joins those same passages. Busy threads remain
candidates for their earlier completed executions. Archive inclusion is independent
of Overview visibility. No native session, model request, filesystem history or
credential lookup is used to obtain conversation text.

Defaults: literal, Unicode case-insensitive, body only, include archived, 20
matching threads (maximum 50). Literal queries preserve spaces and support Chinese
without tokenization; no diacritic/width normalization occurs. Regex uses Go's
linear-time RE2 syntax, including inline flags; invalid patterns fail. Matches
cannot cross passage boundaries. `field:title` searches only current thread titles.
Invalid arguments, patterns and mismatched cursors are caller-correctable tool
errors; cancellation and Runtime failures retain their original classification.
`threadIds` (up to 100; empty means unrestricted) and exact `directoryScopeId`
intersect within the current profile. Inbox uses `inbox`; scope follows the existing
Directory Scope resolver, not a display tag or execution worktree directory.

Each thread yields its first matching passage and first match in that passage,
in stored adapter order. Results contain thread ID, available execution ID,
zero-based passage index, original UTF-8 byte match offsets and an exact excerpt:
up to 80 code points before the match and 320 from its start. Long matches report
`matchTruncated`; snippets are never rewritten or normalized. This is thread
retrieval, not an enumeration/count of every occurrence. Titles have no execution
locator. Passage indexes are snapshot-local, not persistent message identities.

Pages sort by thread ID, not relevance or update time. Query-bound keyset cursors
allow changing only the page size. Pages read live snapshots: new/changed records
behind a cursor require restarting. An empty page can have a continuation. There
is no cross-page snapshot or completeness claim. Per-page extraction is limited
to 100 threads and 32 MiB of session JSON; a single state over 16 MiB is explicitly
unavailable. These are extraction limits, not bounds on the pre-existing Runtime
catalog cache/enumeration. Bodies are decoded serially, never cached by grep;
cancellation is checked between threads and passages (adapter decode and each
bounded regex search are synchronous). Owner hashes are revalidated against a
final snapshot; changed/deleted sources lose their hits and request refresh.

Coverage is only public completed-execution text retained in Mokusei state.
Running, waiting, failed/interrupted execution text, reasoning, tool payloads,
attachments, internal prompts, private Report/Tag agents, Moku and Moku history
are excluded. Native compaction or earlier retention limits cannot be undone.
Internal-input exclusion relies on the Harness's retained visibility markers:
Pi/OpenCode user inputs without those markers are omitted, with the explicit
`unknown-input-visibility` issue even when another passage matches. Their public
assistant text remains searchable. Public assistant text may quote internal or
sensitive input; grep does not redact public text or infer its origin. Shared
index extraction also omits these unknown-visibility inputs on its next rebuild.
Unsupported Harnesses, missing/invalid/oversized state, no public text and
concurrent source changes are explicit page-local `issues`, never silent
negative evidence. Adapter errors are sanitized. Public text can itself contain
user-authored sensitive material or file paths and reaches the current Moku
Harness/model and the existing tool audit; it is untrusted evidence, not instructions.

Attention Agent collapse affects browsing only. Ordinary search keeps these owners eligible, including their existing body index. A search hit is read-only. The detail entry records the restoring visit.
