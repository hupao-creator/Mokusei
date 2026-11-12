# Scoped semantic tags

Production injected callbacks use the shared
[private invocation journal](../../../platform/diagnostics/README.md), capturing
this instance's bound scope and the runner's batch/attempt at entry. This is
separate from native history and mutation receipts and does not infer model retries.

[plugin.go](plugin.go) registers a per-directory Tag Agent, including Inbox. Each
pool has at most **five** semantic tags. Every wake reviews all unarchived ordinary
Threads in that pool; archived Threads, Moku, private sessions and other scopes
are excluded. Runtime bindings enforce the same boundary on reads and writes.

Accepted input (user or application), actual title changes, restoration and its
own initialization inventory wake the agent. Execution completed/failed/interrupted
facts do not. Events schedule work but their payloads are never sent to Tag.
The runner initializes lazily and disposes idle sessions. Its dedicated
`title-classification` session key keeps earlier excerpt-based native history
outside this title-only context contract.

## Statusbar and tools

Every initial send, retry and active steering captures one authoritative statusbar:
`pool`, opaque `revision`, `capacity` (five), `tags` (stable ID/name/emoji), `threads`
(ID/title only), `assignments` (threadId/tagId), and `unassignedThreadIds`.
All fields come from one immutable store snapshot. The revision is a content hash
of classification-relevant state; unrelated streaming/status changes do not stale
it. Thread titles, tag names and all tool results are evidence, never instructions.
No input excerpt, assistant output, execution status, conversation history, or
Overview context is exposed. There is no user-facing statusbar UI.

The exclusive tool set is:

- `read_statusbar`: refresh the full current pool view.
- `create_tag(name, emoji, expectedRevision)`: create one tag, reusing duplicate names.
- `update_tag(tagId, name?, emoji?, expectedRevision)`: preserve identity and members.
- `delete_tag(tagId, expectedRevision)`: delete an empty tag; active members reject it.
- `assign_threads(assignments, expectedRevision)`: batch threadId/tagId replacements,
  each to exactly one existing tag; one invalid entry rejects the entire transaction.

Writes compare the supplied revision inside the same transaction as the mutation.
They return `status: applied` or `status: conflict` with the fresh `statusbar`.
Conflicts apply no classification change. Durable receipts preserve exactly-once
mutation effects across retries; read fresh status when resuming. Reorganization
can span calls: move members, delete an empty tag, create a better category, and
redistribute. Each call is atomic; the whole multi-call reorganization is resumable.
Before finishing, the agent reads status again and checks complete active coverage.

## Archive boundary

An archived Thread retains its name/emoji decoration as a historical snapshot,
but is absent from status, active usage, assignments and inventory. Tag mutations
never rewrite that decoration; a category used only by archives can be deleted.
Restoring clears its historical assignment and wakes classification into the
current active pool. The model cannot assign an archived Thread directly.

Saved configuration applies at the next batch configuration boundary. Active
batch steering retains its admitted profile. A save during native discovery
causes re-resolution without spending a batch retry, including when the initial
discovery result matches an existing idle session. The Runtime replay exercises
the production Tag and Report participants in inherited and independent modes.

`tag.settings.enabled` is independent of Report and defaults to true when
omitted. Saving false immediately revokes the active attempt and its tools;
the runner interrupts/closes its native session and pauses without deleting the
pool, assignments, profiles, batch identity or receipts. User pauses refund the
interrupted attempt rather than exhausting failure retries. Re-enabling resumes
pending work, including events retained across a disabled restart. The consumer
uses durable pending replay so a queued event cannot disappear before admission.
Overview filtering and existing tags remain available while the Agent is off.

## Names and emoji

[Mutation tools](tools.go) validate complete shapes before batch write admission.
Unknown nested fields, missing required values, null decorations, empty updates
and malformed IDs reject the call. Runtime owns name normalization, five-tag
capacity, scope/active-member validation and transactional revision comparison.

Tags have stable internal IDs; normalized names remain unique within their pool.
Public Thread envelopes still carry label names and emoji. Names cannot contain
emoji prefixes. [taglabel](../../../services/taglabel/) validates complete Unicode
Emoji 16.0 sequences. Invalid nonempty generated emoji falls back to `🏷️`;
missing/empty creation emoji rejects. An omitted update emoji preserves it.

Every public thread envelope includes `tagEmojis`, even when empty. Keys match semantic tags, excluding directory tags. Emoji-only changes publish revisions and update Report source decoration. [generate-tag-emoji.py](../../../../scripts/generate-tag-emoji.py) generates the Swift table from the pinned data; the parity test checks agreement.

Overview displays emoji and name separately from the identity, groups aliases with identical membership, and includes singly used semantic tags. Directory labels come from [directorytag](../../../services/directorytag/directorytag.go). [Overview presentation](../../../../app/macos/Sources/Host/Overview/README.md) owns visual filtering and motion.

Verification: affected Go race tests and `./scripts/go.sh run -race ./tools/verification/runtime`. The production replay covers title-only injection, exact tools, full scoped membership, stable IDs, atomic writes, stale revisions, five-slot reorganization, archive/restore, terminal non-wake and title-change steering/idle wake. Hosted Complete coverage includes existing native label presentation checks.
