# Report application

Production evidence/read/write callbacks use the shared
[private invocation journal](../../../platform/diagnostics/README.md), with scoped
owner, execution and batch/attempt identity. Bodies stay private and are never
injected into report context or output. Retention/redaction is independent of
documents, native history and mutation receipts.

[plugin.go](plugin.go) declares the Report application, its settings and a **per-directory-scope** background agent. Each instance receives an explicit owner and scope, including Inbox. It observes successful ordinary-task completion and reads only evidence allowed by that binding. Its private conversation is distinct from the report documents shown to the user.

[domain.go](domain.go) and [model.go](model.go) define document commands, queries and projections. Mutations use the Application host's planned transaction scopes, CAS and batch receipts. Report source references and semantic tag/emoji snapshots are maintained with the document; a source deletion does not rewrite the report as an executing task. HTML and full document content are queried on demand rather than embedded in the overview catalog.

The Report session's exclusive tool bindings are `list_threads`,
`get_thread_status`, `read_lifecycle_events`, `create_report`, `list_reports`,
`read_report` and `update_report`. It exposes no `read_thread` binding or
alternative binding for model-based source-history questions. Moku's separate
`read_thread` tool and the shared ordinary-task read capability are independent.

The agent uses the shared [background runner](../background/runner.go), initializing native work lazily and disposing idle sessions. It follows Moku's saved execution profile or an independent configuration via [background settings](../background/settings.go). Admitted batches retain their configuration and request/receipt identity across retries. Settings-retention data survives history clearing.

`report.settings.enabled` defaults to true when omitted and operates independently
of Tag. Disabling revokes the active attempt and tool lifetime, interrupts/closes
native work and pauses the durable inbox. Existing report documents remain in the
catalog and reader; settings, source references, batches and write receipts stay
intact. Re-enabling resumes pending work after native cleanup, including after a
restart. User pauses do not spend the batch's failure retry budget. The host
checks enablement inside the write transaction, rejecting late background writes.

Report writing and presentation use the complete, unmodified upstream
[ELI5 skill](eli5-skill.md), embedded as a separate system-instruction entry after
[the agent's operational and host-integration instructions](instructions.txt).
Source: [anthropics/claude-plugins-community, eli5/skills/eli5/SKILL.md](https://github.com/anthropics/claude-plugins-community/blob/06ec7b6a0a82bdc4bec44bd82d4368c42f20d7c1/eli5/skills/eli5/SKILL.md),
retrieved 2026-10-29 from `main` at commit
`06ec7b6a0a82bdc4bec44bd82d4368c42f20d7c1`.
The 321-byte snapshot includes its front matter and literal `$ARGUMENTS`;
SHA-256: `3bb95cd13852051c5a1862e8b94da1de7cfba7415d418ab0ca4d762527d1b9a5`.
It is bundled locally; report generation does not fetch the skill at runtime.

The skill fits the existing HTML storage/reader capability. Operational adaptation
outside the verbatim text applies it without a user slash command, binds its topic
to permitted task evidence, and saves its HTML artifact through the existing report
tools. Big pictures can be inline SVG or HTML/CSS; the skill requires no image,
file, command, video or artifact-generation service, and grants no extra capability.
Scope, evidence integrity, permissions, batch steering, references and write
receipts remain agent/runtime responsibilities. Complete raw HTML and isolated
page execution remain tool/reader contracts. Safe-area geometry and live light/dark
theme adaptation remain host integration requirements. Other writing rules,
including application-output-language injection and tool-field language rules,
are removed. The background environment capability is still required by the shared
runner for session lifecycle; Report no longer reads its output locale.

A settings save that races configuration discovery causes re-resolution within
the same batch attempt, without failure backoff. Existing idle-session reuse
passes the same saved-version check. The Runtime replay covers these boundaries
through the production Tag/Report participants, active steering, next-batch
adoption and independent profiles that remain unaffected by Moku edits.

The Swift [Report application](../../../../app/macos/Sources/Plugins/Applications/Report/) supplies cards and a native HTML reading route using the shared navigation stack. Report documents have no ordinary task execution lifecycle. Their tags decorate the document and do not independently create Overview filter membership.

Verification: `./scripts/go.sh run -race ./tools/verification/applicationhost`, `./scripts/go.sh run -race ./tools/verification/runtime` and `./scripts/go.sh test -race ./internal/plugins/applications/report` from the repository root.
The headless Runtime replay checks the actual Report session's injected skill
against the upstream SHA-256 and rejects the removed style/language guidance in
system instructions, tool descriptions and initial/steering batch messages.


Preview and search share a non-executing HTML tree parser. It decodes standard
entities once, joins inline text without invented spaces, separates structural
blocks, preserves textarea RCDATA, and excludes nested hidden regions including
templates. The parser handles SVG/MathML namespaces, self-closing foreign
elements, CDATA and HTML integration points before text projection. Malformed
markup follows HTML tree repair: for example, plain text misplaced in head
is moved to the visible body, while title content stays hidden. This is static
source text, not computed CSS visibility or live form state.

If the tree parser rejects a document (notably its 512-open-element limit),
projection reparses bounded UTF-8 prefixes and retains a successfully parsed
prefix. Both preview and search use that same safe prefix; preview still applies
title removal and its length limit. Content at or after the rejected region can
be absent from search/preview, and a document with no visible safe prefix has
empty projected text. Recovery never scans an isolated suffix or exposes raw
markup, since its template/foreign-content context would be unknown. The original
HTML remains unchanged and available to the Reader; parser failure does not
reject a report accepted by the input size contract.


The native Report surface owns load failure and Retry state. Report detail does
not retain a second error overlay after the surface recovers. Page alert,
confirm, prompt and file selection use native sheets owned by the current visit;
suppression, replacement and disposal cancel outstanding callbacks exactly once.
Downloads are rejected with a dismissible notice while the loaded document stays
open.

## Card metadata and execution workspace

Report documents persist `emoji` (one complete Unicode emoji) and
`shortDescription` (1–220 Unicode scalars, whitespace normalized) independently
of HTML. Create requires both; update can replace either without changing the
HTML content revision. Read/list and the native catalog expose these fields.
The Report Agent supplies them through its tool schema. Its instructions ask for
a substantive, evidence-grounded card snapshot, with flexible Chinese and English
length targets suited to the five-line display; the 220-scalar limit remains a
hard validation boundary, not a target to fill. On report updates the agent
revisits the introduction when new evidence changes the report or can make the
card more useful. Existing descriptions are not rewritten in bulk; they change
only when a report update supplies a replacement. Missing or invalid metadata is
rejected; this unreleased contract has no legacy migration.

Overview uses the shared Agent card typography, excerpt renderer and upper-right
emoji badge. The metadata row displays unique source Harness logos and update
time. Each Harness logo shows `×N` when it references more than one Thread;
the count follows the existing one-execution-per-thread contract. Related executions appear only in the reader; archiving is in the card's
context menu. The HTML-derived preview remains available as its existing public
projection, while the card uses the authored short description.

The right-hand execution list occupies 30% of available panel width (excluding
the 16pt gap). Selecting a reference replaces the list with the host's actual
single-execution Harness reader at 50%. Back restores the list; removal or hiding
of the selected reference retires its reader. HTML remains mounted across these
changes. Browser-link navigation retains its existing additional workspace.

The related list uses individual native Liquid Glass items without sequence
numbers or connector lines. It shows the matching execution title, two lines of
assistant text, Harness identity and elapsed time; token usage is not displayed.
The host obtains exact-execution previews through the native Harness contract.
Missing timing is explicit and empty excerpts remain empty. Existing one-click
reader navigation and deletion/visibility handling are unchanged.
