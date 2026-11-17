# Super Thread application

[plugin.go](plugin.go) declares the Super Thread application, its settings and a **per-directory-scope** background agent. Each instance receives an explicit owner and scope, including Inbox. It observes successful ordinary-task completion and reads only evidence allowed by that binding. Its private conversation is distinct from the report documents shown to the user.

[domain.go](domain.go) and [model.go](model.go) define document commands, queries and projections. Mutations use the Application host's planned transaction scopes, CAS and batch receipts. Report source references and semantic tag/emoji snapshots are maintained with the document; a source deletion does not rewrite the report as an executing task. HTML and full document content are queried on demand rather than embedded in the overview catalog.

Super Thread Agent's exclusive tool bindings are `create_report`, `list_reports`,
`read_report` and `update_report`. It uses automatically delivered successful
execution evidence, saved reports and the scoped title-only inventory described
below. It cannot query current task status, look up historical lifecycle events
or ask model-based source-history questions. Earlier evidence absent from its
current context and saved reports cannot be recovered by the agent. Moku's task
tools are independent.

The operational prompt describes the delivered evidence and report content
requirements without prescribing tool invocation. The verbatim ELI5 snapshot
and existing writing/host-integration requirements remain unchanged.

The agent uses the shared [background runner](../background/runner.go), initializing native work lazily and disposing idle sessions. It follows Moku's saved execution profile or an independent configuration via [background settings](../background/settings.go). Admitted batches retain their configuration and request/receipt identity across retries. Settings-retention data survives history clearing.

The runner retains its internal lifecycle history reads for initial batches and
retry recovery; removing model-facing queries does not remove that authority.
Automatic batches and active-execution steering embed the shared runner's
complete lifecycle event JSON, including `data`, rather than metadata requiring
a second journal read. For `execution.completed`, `data` is the persisted
`PublicExecution` snapshot with its execution ID, status, start time and any
recorded finish time and original summary. Optional absent fields stay absent;
an empty summary stays empty. Delivery does not synthesize a final reply or
substitute the thread's current execution. See the host's
[shared delivery contract](../../../hosts/applicationhost/README.md#lifecycle-batch-delivery)
for size, retry and disclosure limits.

## Wake statusbar

Every actual initial, retry or steering send captures `report.statusbar` afresh
and appends its JSON after the unchanged lifecycle event array. The snapshot is
`scope`, opaque content `revision`, and `unassignedThreads` (ID/title only, sorted
by ID). It lists all current unarchived ordinary Threads in the instance's
Directory Scope, including Inbox, that have no Super Thread owner. It does not
filter by execution status or by the triggering event. Moku, retained Moku history,
private sessions and other scopes are excluded. A bound Thread remains classified
when its current execution changes or its Super Thread is archived. Historical
bindings in other scopes also exclude it, without exposing those owners. User
unlink, report-reference edits, archive/restore, title changes and deletion are
reflected at the next send; they do not create new wake triggers.

[statusbar.go](statusbar.go) joins title-only inventory and the host's complete
binding index from one immutable store snapshot. The background-only query has
no model tool binding and accepts no scope supplied by the model. It requires
only a snapshot inventory capability, without task history or current execution
reads. Apart from the existing host-owned scope identity, full reports, HTML,
covers, per-Thread working directories, private sessions, tools and diagnostic
bodies are absent. The existing four report tools remain unchanged.

The version changes only when the scoped unassigned ID/title content changes;
it is not an `expectedRevision` for report writes. Membership is advisory and
can change concurrently. Existing full-report read, record CAS, binding checks
and durable write receipts remain authoritative. An unassigned Thread is not
evidence of completion and does not require a report. Titles are untrusted text;
snapshot content is evidence, never instructions granting authority.
Delivered successful-execution data and saved reports
remain the only report-content evidence; missing historic execution evidence
is not reconstructed from this inventory.

The shared `sendEvents` path covers lazy first admission, later idle batches,
failure retries, pending work after restart, re-enablement after pause, and new
events steering a running execution. Each send takes a new snapshot after native
configuration preparation. Merely reconnecting an already admitted running
execution does not send input, replay events, spend an attempt or replace its
in-flight context. Its next actual send refreshes the snapshot. Already completed
recovered work settles without an unnecessary model wake. Query failures prevent
the send and follow existing retry/cancellation handling; no empty success is
substituted. Delivery keeps the existing input-size limits and never silently
truncates the unassigned list. Oversized input fails through the same retry path.

No UI status bar or new completion, polling, title-change or report-write wake is
introduced. The verbatim writing skill and report presentation remain unchanged.

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
passes the same saved-version check.

The Swift [Report application](../../../../app/macos/Sources/Plugins/Applications/Report/) supplies cards and a native HTML reading route using the shared navigation stack. Report documents have no ordinary task execution lifecycle. Their tags decorate the document and do not independently create Overview filter membership.

Preview uses a non-executing HTML tree parser. It decodes standard
entities once, joins inline text without invented spaces, separates structural
blocks, preserves textarea RCDATA, and excludes nested hidden regions including
templates. The parser handles SVG/MathML namespaces, self-closing foreign
elements, CDATA and HTML integration points before text projection. Malformed
markup follows HTML tree repair: for example, plain text misplaced in head
is moved to the visible body, while title content stays hidden. This is static
source text, not computed CSS visibility or live form state.

If the tree parser rejects a document (notably its 512-open-element limit),
projection reparses bounded UTF-8 prefixes and retains a successfully parsed
prefix. Preview uses that same safe prefix and applies
title removal and its length limit. Content at or after the rejected region can
be absent from preview, and a document with no visible safe prefix has
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
Super Thread Agent supplies them through its tool schema. Its instructions ask for
a concise, evidence-grounded two-line card snapshot; the 220-scalar limit remains a
hard validation boundary, not a target to fill. On report updates the agent
revisits the introduction when new evidence changes the report or can make the
card more useful. Existing descriptions are not rewritten in bulk; they change
only when a report update supplies a replacement. Missing or invalid metadata is
rejected; the rebrand leaves the existing document schema unchanged.

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
numbers or connector lines. It shows the matching execution title, four lines of
assistant text, Harness identity, current Thread status and cited execution elapsed
time; token usage is not displayed.
The host obtains exact-execution previews through the native Harness contract.
Missing timing is explicit and empty excerpts remain empty. Existing one-click
reader navigation is retained. Explicit report links also retain failed/interrupted
ordinary Threads that normal Overview browsing hides.

## Identity, ownership and source context

Super Thread Agent is the user-visible name of the existing private Report Agent.
The `report` plugin ID, `report.agent`, `report.settings`, `report.document`,
`report.records`, tool/operation names, session keys, batch receipts and execution
references remain stable. No rename migration, history rewrite or configuration
reset runs. The existing long prompt and verbatim ELI5 snapshot remain; the pending
shortened prompt is not adopted, and the system prompt names no concrete tools.

Create and update enforce one Super Thread per ordinary Thread inside the host's
serialized transaction, with the whole report collection in the mutation scope.
Archived documents retain ownership. A conflicting write returns
`SUPER_THREAD_BINDING_CONFLICT` and the existing owner ID, with explicit unlink
instructions. Receipt replay deduplicates creates; unchanged updates do not touch
the report revision. Updating to a newer completed execution of the same owned
Thread is allowed. Replacing `relatedExecutions` with a list omitting a Thread
releases its ownership atomically, so a later transaction may bind it elsewhere.

Pre-existing multiple bindings remain readable. Their exact references may be
retained unchanged or removed, and report content can still be edited. Adding
another owner or replacing an ambiguous reference is rejected until the other
bindings are explicitly removed. No startup migration chooses a winner, deletes
HTML, archives a document, or rewrites a reference. Retained references also
survive source deletion; unchanged references do not need fresh source evidence.

`report.relations` and `report.context` share a snapshot projection. It reads only
the report's referenced ordinary Threads within the report scope, resolves each
exact execution through its Harness, and separates current Thread execution facts
from the report's execution facts. It distinguishes missing Thread, missing
execution and changed scope. Binding counts include archived and historical
conflicts, but disclose no unrelated report content. A host-owned snapshot index
maps referenced Threads to their report IDs. After its initial construction,
only changed reports update this index; a Thread or telemetry change never
reparses unrelated report HTML. The reader shows current
running/waiting/completed/failed/interrupted state and background work separately
from the cited execution's timing; the cited state and ID remain out of the card.
Unknown historical facts never borrow current results. Queries coalesce streaming catalog invalidations; departure
cancels the reader's request, and report revision/reference fences reject stale data.

Unselected Super Thread input stays pinned open and sends to Moku. Its own persisted
draft is separate from Overview and per-execution Agent drafts. Typed text,
attachments and recorded input use `moku:submit.superThreadId`; the coordinator
resolves full current report HTML, bounded exact-execution summaries, identity,
workspace, current state and binding conflicts at admission. HTML is untrusted
context and is not executed. Failed context resolution rejects the send rather
than silently losing its source. Selecting an execution preserves the existing
ordinary Agent send/fork/receipt route; folding or returning to the list restores
Moku (see [Moku](../../../services/moku/README.md)).

Sprint validation: Go formatting, architecture lint, vet and builds, and the Swift
application product build only. Native focus/animation, accessibility, real voice,
concurrent binding and legacy-data interactions require later validation.

## Archive visibility

Archive only hides a Super Thread and all ordinary Agent Threads identified by
its stored `relatedExecutions`. The referenced execution need not still be the
latest; running successors and background tasks continue. The Host commits the
document and source flags atomically, deduplicates Thread identities and skips
already-hidden or deleted sources. A failure publishes no partial change. An
explicit repeat archive re-hides independently restored sources. Other Super
Threads (including historical conflicting owners) and Collections are not targets.

HTML, covers, conversation history, persisted records and bindings remain intact.
Explicit report queries, source reading/search, send/fork and sidecard actions
remain available under their ordinary authority checks. Archive is not deletion,
execution completion, cancellation, session close or unlink. Restore retains its
existing behavior: restore the requested report only, without cascading to source
Threads. A separately restored Thread keeps its report association.

The expanded Collection panel shows an Archive Super Thread button below each
member card, separate from its open action. The existing card context menu uses
the same capability. Pending actions prevent duplicate activation; failures stay
visible and retryable. Catalog changes refresh member counts and selection; when
fewer than two members remain, normal Overview grouping retires the Collection
and its panel, leaving a surviving report as an individual card.

## Explicit user unlink

The related-list UI does not offer an unlink action. The underlying
command remains available independently of that UI.
`report.unlink` is a user-only command with report ID, Thread ID, execution ID and
observed report revision. Its serialized collection transaction rejects a changed
link/revision, removes the associated tag-source entry, and permits an already-absent
link as an idempotent success. Existing command receipts cover response retries.
This works independently of the background Agent's enabled setting. The list and
Moku read the resulting authoritative references; no UI-only ownership state exists.

This operation releases one report's binding, not all other owners and not an
automatic move. Remaining conflicts are still visible; users must unlink remaining
owners before rebinding. It does not edit or erase claims in the report body. Rebind
creation/update remains the background report author's existing authority.

## Background edit concurrency

`report.update` carries `expectedRevision`, copied from the full report the Agent
read to decide its edit. The reducer compares it with the current record revision
before changing any field, including associations. A user unlink increments that
same revision, so an update based on the old list cannot restore the link.
`REPORT_REVISION_CHANGED` instructs the Agent to reread the full report and reconsider
its edit, not merely fetch a fresh number to replay stale fields. The tool schema
requires the version; no write adapter silently substitutes the current version.
Missing versions receive `REPORT_REVISION_REQUIRED` in the reducer. This preserves
old successful receipt replay, which the host resolves before reduction, while
unreceipted old writes must reread. Persisted report data is unchanged, existing
reports remain readable, and create/new binding uses the existing authority.

## Cover cards

New Super Thread tool calls supply `coverHTML`; updates may replace it independently
of the report document. The shared create/update field description specifies a
standalone 360×308 CSS-pixel logical HTML/CSS viewport: no host layout CSS, padding
or safe-area styles are injected. The report body's host-integration rules and `--mokusei-*` variables do
not apply to covers; the authored HTML must supply its own CSS and spacing.
Author JavaScript and external resources are unavailable. The Agent instructions
and both write tools require purposeful, evidence-grounded CSS keyframes rather
than a static cover or a generic decorative template. The complete finite timeline,
including delays and repetitions, is at most six seconds. Its final composition
must remain readable on its own, and a title or recognizable key visual stays
visible from time zero so a replay does not start with an empty background. The host holds that final frame for five seconds
and then replays; authors must not include the hold, infinite loops, hover
transitions or scroll timelines. Covers supply both light and dark palettes.
This guidance is independent of the report body's ELI5/host-integration rules.
The report introduction targets a concise two-line card.
Cover markup is HTML/CSS, limited to 64,000 Unicode scalars; inline SVG, scripts
and embedded documents are rejected at admission. See the
[cropping investigation](../../../../design/super-thread-cover-top-space.md)
for the prompt ambiguity and actual two-version evidence.

`coverHTML` and `coverRevision` persist with the report. Cover changes allocate a
new cover revision without reloading the report HTML; unchanged updates retain the
revision and existing CAS/receipt semantics. Full report reads expose the cover;
the catalog exposes only its revision. `report.cover` loads markup on demand for
mounted native cards. Documents without a
cover stay one grid row until authored cover content is supplied; no bulk generation
or rewrite runs on startup.

The production card uses one shell, one open action and its existing archive menu.
A cover makes its Overview footprint 1×2 (414×522pt on the current grid).
The native cover region preserves the logical viewport ratio: height = width ×
308/360 (354.2pt at 414pt width), followed by the 4pt gap and remaining metadata
region (163.8pt). WebKit and its cached poster both render at 360×308 and scale
uniformly as one centered surface. Fixed-pixel existing covers and percentage
layouts therefore use the same viewport without cropping or rewriting HTML.
Narrower Report cards use the same ratio; coverless cards retain metadata only.
Authored internal whitespace remains authored content, not an inferred crop.
See the [viewport investigation and panel measurements](../../../../design/super-thread-cover-layout.md).
The passive native WebKit surface uses a nonpersistent store, disabled author JavaScript,
a host-owned document response with a sandbox CSP blocking external resources.
It neither navigates nor handles input; theme follows the native appearance.
A failed cover leaves the native card usable with an unavailable label.

An isolated host-owned WebKit content world controls the admitted CSS effects.
It retains their final styles, treats an out-of-contract infinite effect as one
iteration, and accelerates an oversized timeline as a whole to fit six seconds.
Static covers remain readable. The host adds playback-only CSS to pause authored
effects and suppress transitions, without injecting layout or safe-area styles.
This does not enable document scripts or add an application API.

Preloaded neighbors remain at their beginning. A selected cover starts after
its native entrance; its eleven-second carousel dwell waits for actual WebKit
playback acknowledgement. Collection covers play their complete admitted CSS
timeline once, then hold its final frame until selection changes. Reselecting a
cover grants a new run; hover chrome, focus, redraws and pause/resume do not.
Leaving selection resets for the next visit; inactivity, hidden viewports and
cover gestures pause the current motion. Standalone cards retain their existing
animation/five-second-hold replay cycle and foreground/visibility controls.
The bounded cache retains
a final-frame poster beneath the live surface to bridge remounts without caching
browser instances. See the [animation contract and verification](../../../../design/super-thread-animated-covers.md).

Collection cards show the current report/total in their upper-right badge. Their
bottom carousel capsule fades in over 160ms while the whole card is hovered and
fades out on exit, without changing layout or intercepting pointer input while
hidden. Only pointer hover reveals the whole capsule: retained keyboard/accessibility
focus and native menu tracking never extend its visibility after pointer exit.
Controls stay mounted for native keyboard/accessibility operation; menu tracking
pauses automatic page changes until dismissal. Deactivation, viewport exit and
unmount clear remembered hover.
Page numbers follow the surviving selected member after collection updates; stale
menu actions for removed members are ignored. Single-member input displays 1/1 (ordinary Overview
grouping currently requires at least two members). Other card types are unchanged.

## Updated collection members

The native plugin exposes a stable reading fingerprint for title, emoji,
introduction, document/cover revisions and the set of exact execution references.
The desktop Host persists this fingerprint with its close/retained-reading facts;
a change revokes the old collection eligibility even across reconnect/restart.
Tag propagation, archive/restore, source status, record timestamps/revisions and
reference order alone do not split a collection. Initial observation establishes
a baseline rather than an edit. No report record, write receipt or CAS changes.
See the [desktop reading contract](../../../../app/macos/Sources/Host/Overview/README.md#viewed-application-collections)
for close/dwell rules and the limit of reading evidence without a prior fingerprint.
