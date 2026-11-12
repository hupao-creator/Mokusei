# Thread search

This module owns derived keyword text, passage indexing and hybrid thread ranking.
Harness and Application adapters supply public text; the injected
[embedding provider](../embedding/README.md) owns model preparation and local
inference. Search never opens native conversations or discovers credentials.
The [Overview](../../../app/macos/Sources/Host/Overview/README.md) supplies the
global eligible thread scope and immediate folded metadata matches, independent
of its browsing tag. Directory-only documents and tasks covered by reports remain
included; archive/terminal exclusions remain.

## Projections and incremental work

[documents.go](documents.go) keeps `keyword-text-v3`: metadata is bounded to 512
Unicode code points and body text to the existing 134,550-code-point prefix.
The user explicitly retained this body coverage limit. Metadata/body offsets are
stored independently so changing a title does not shift every body passage.
Owner-key snapshot diffs extract only changed eligible public sources; telemetry,
unrelated collections and derived commits do not re-extract histories. Busy
owners wait for their next source change. Extraction failures use bounded retry.
Body and freshness stamp commit atomically behind the owner/hash/epoch fence.

[semantic.go](semantic.go) watches changed body stamps and embeds bounded UTF-8
passages with overlap. Each passage has a content hash within the exact model
space, so unchanged passages reuse durable vectors after owner-only updates,
restarts or interrupted builds. A changed model space or chunking pipeline
rebuilds its derived generations. The provider owns query/document templates,
dimensions and normalization; retrieval does not contain Gemma/Qwen prompts.

[vector_store.go](vector_store.go) stores binary float32 vectors in a separate
profile-local SQLite database, never in the authoritative resident JSON snapshot.
Queries stream vector rows under a bounded working set with cancellation checks.
A complete generation commits before its small publication stamp is admitted in
the authoritative owner transaction. Unpublished, incompatible or stale generations
cannot produce hits. Revoked generations and unused passage vectors are reclaimed.
Vector database failures preserve keyword search and expose retryable status.

## Queries and ranking

[query.go](query.go) preserves whitespace-term substring AND across metadata and
body; native case/diacritic/width-folded matches independently qualify. Semantic
passage evidence aggregates to one result per ThreadRef. Exact title substrings
remain first; reciprocal rank fusion (constant 60) combines keyword and semantic
rankings. Scores are ranking values, not confidence percentages.

The [default tuning](tuning.go) uses 768-byte passages, 192-byte overlap, a 0.76
semantic floor and at most 12 semantic candidates. With both body and metadata,
semantic evidence is `0.8 * max(body, metadata) + 0.2 * metadata`; this reduces a
long conversation's ability to outrank the dedicated thread merely by quoting it.
Keyword matches are retained independently of this semantic candidate limit.
The zero Tuning value selects the defaults; explicit internal tuning supplies the
complete configuration for evaluation or another model. There is no user selector.

Cold queries return keyword hits immediately while a bounded query-embedding
cache prepares semantic evidence. The native client polls pending work at a
bounded shorter interval, then resumes its ordinary three-second refresh.
The decoded keyword-body cache remains limited to 64 MiB; query result and query
embedding caches each hold at most eight entries. Every response revalidates the
live owner and history epoch; model/input incompatibility never reuses old vectors.

## Lifecycle and verification

Model preparation starts in the composed macOS Runtime. The native provider
verifies the pinned INT4 artifact, runs CPU inference locally, prioritizes queries
between short background batches and retires its process after 90 idle seconds.
Model changes do not require UI changes. Verified weights survive history clear;
no conversation text is sent to the download service.

Archive/deletion revoke derived text and vector publication stamps in the owner
transaction. Physical row reclamation is separate, not a cross-database atomic
transaction. History clear cancels and joins publishers, advances the epoch and
clears persisted vector rows before resuming. `search:status` and `search:query`
remain cancellable reads; `search:retry` is a zero-argument recovery command.
Retired configure/model/index controls remain unsupported.

The [Runtime/native replay](../../../tools/verification/thread-search/README.md)
checks SQLite, cache reuse, model-space replacement, late completion, fallback,
archive and history clearing. The macOS CI interop lane also runs the genuine
INT4 model, cross-language retrieval, a network-denied offline restart, observed
idle exit/reload, corrupt-asset refusal and retry recovery. Controlled vectors
exercise lifecycle interleavings but never certify semantic quality.

An optional local corpus evaluator uses production public-text adapters against
a read-only profile snapshot. Corpora, labels and detailed results stay in an
ignored private directory; they are not CI fixtures. A 16-thread local corpus
motivated the defaults. Its 21 initial labelled queries and seven subsequent
queries found 21/22 positive targets first, all 22 within three results, and no
hits for six unrelated queries. This is bounded local evidence, not a general
retrieval-accuracy claim; related implementation/merge threads can still tie.

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