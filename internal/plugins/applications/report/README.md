# Report application

[plugin.go](plugin.go) declares the Report application, its settings and a **per-directory-scope** background agent. Each instance receives an explicit owner and scope, including Inbox. It observes successful ordinary-task completion and reads only evidence allowed by that binding. Its private conversation is distinct from the report documents shown to the user.

[domain.go](domain.go) and [model.go](model.go) define document commands, queries and projections. Mutations use the Application host's planned transaction scopes, CAS and batch receipts. Report source references and semantic tag/emoji snapshots are maintained with the document; a source deletion does not rewrite the report as an executing task. HTML and full document content are queried on demand rather than embedded in the overview catalog.

The agent uses the shared [background runner](../background/runner.go), initializing native work lazily and disposing idle sessions. It follows Moku's saved execution profile or an independent configuration via [background settings](../background/settings.go). Admitted batches retain their configuration and request/receipt identity across retries. Settings-retention data survives history clearing.

A settings save that races configuration discovery causes re-resolution within
the same batch attempt, without failure backoff. Existing idle-session reuse
passes the same saved-version check. The Runtime replay covers these boundaries
through the production Tag/Report participants, active steering, next-batch
adoption and independent profiles that remain unaffected by Moku edits.

The Swift [Report application](../../../../app/macos/Sources/Plugins/Applications/Report/) supplies cards and a native HTML reading route using the shared navigation stack. Report documents have no ordinary task execution lifecycle. Their tags decorate the document and do not independently create Overview filter membership.

Verification: `./scripts/go.sh run -race ./tools/verification/applicationhost`, `./scripts/go.sh run -race ./tools/verification/runtime` and `./scripts/go.sh test -race ./internal/plugins/applications/report` from the repository root.


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
