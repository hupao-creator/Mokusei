# OpenCode Go adapter

Direct ordinary input retains `followUp` when `Send` targets an already active
execution. Its existing `createdAt` is the captured submission time, not an
acceptance or model-processing time. Before native I/O, `steerInputs` durably
associates the submitted message ID with its exact native session, execution,
visible input, timestamp and annotations. This private association is excluded
from renderer projections and does not create a message or acknowledge admission.
A successful HTTP prompt reply, matching native inbox event, or user-message
history record consumes the association into one canonical message. Duplicate
evidence retains its identity and original execution even after a successor
changes the session's current execution. Different-session/identity conflicts do
not reassign a retained input. Unconfirmed dispatch associations remain private.
Cleanup retains matching late inbox events and persists matching queued inputs
before deleting native inbox items; identity or persistence failure keeps the
item and reports the error. Full/deferred execution projections retain the fact;
Agent detail uses it for compact text/time rows. Unknown imported/native input
identity and child-session prompts do not become user steer rows. Directory
compaction keeps its existing schema; no historical marker is inferred. See the
[input identity contract](../../../../design/composer.md).

Exact execution forks accept `{executionId}` beside the existing message
selector (mutually exclusive). A completed execution resolves to its last root
message in native transcript order and uses the existing checkpoint/import
path. Newer context-entry state is omitted from historical forks. Missing native
checkpoints fail without sending. See
[Report continuation](../../../../design/reading.md).

`New(plugin.HostContext)` composes the OpenCode Harness, settings, native model catalog,
installation, workspace discovery, isolated completion, fork/read and Moku telemetry.
The adapter accepts stable OpenCode 2.x releases beginning with 2.0.25. Protocol routes,
native event shapes and the descending session allocator follow the installed
`@opencode/protocol` and `@opencode/schema` 2.0.25 definitions.

Installation owns npm's process group, its lifecycle-script descendants and both
output readers. Cancellation and leader exit drain them with bounded TERM/KILL
cleanup before returning; uncertain cleanup remains an error. Combined captured
output is limited to 8 MiB, and cancellation, output-limit and nonzero-exit failures
remain observable.

Go owns process startup/shutdown, authenticated HTTP, reconnecting SSE, durable log
reconciliation, session identity reservation, state projections, execution admission,
steering, permissions/forms, tools, model validation and provider/account policy.
The installed external `opencode serve --stdio` process remains the model/tool engine.
Projected messages keep one visible representation: assistant text and reasoning
exist only in their ordered `parts`, user input uses `text`, and tool input/output
use producer-rendered `argumentsDisplay`/`resultDisplay` strings. Raw tool payloads,
assistant aggregates and tool metadata do not enter the renderer projection; the
native reader trusts the projected display instead of rebuilding or checking a
second JSON copy. Canonical state retains only the raw tool payload, not a second
extracted body. Deferred turn projections retain assistant reply text, including
interim and child-session replies, without acquiring execution-detail content.
Child-session user prompts, reasoning and tool displays stay hidden and contribute
`nonempty` markers (`text` only for the hidden child prompt,
`parts:<type>:<ordinal>` for reasoning, `argumentsDisplay`/`resultDisplay` for
tools) so collapse state survives without leaking private work. Error and failed-message payloads, including child sessions, remain
available for independent diagnostics; retained tool failures do not bypass Agent
summaries. Canonical history and full/execution projections retain their
user-visible content and diagnostics under this one-body schema.
Distinct reasoning ordinals remain separate parts through streaming, completion
and history reconciliation. Go and Swift computed reasoning text join those
parts with blank lines; chunks within one part append without separators.

Canonical persisted state is version 2; the renderer projection is a separate,
transient contract that remains version 1. Version 1 canonical state duplicated
assistant text/reasoning as aggregates and tool text beside structured data, so it
is rejected with an explicit rebuild/clear error rather than silently dropping
thinking-only replies; there is no in-place migration before release. If a projection would exceed the content transport boundary, the adapter sends a
bounded fallback instead of failing the whole surface: raw tool payloads are
removed, producer-rendered tool displays and scalar fields are truncated,
assistant parts stay the sole body (no empty aggregate is injected), deferred
`nonempty` presence is filtered from the original envelope to retained message IDs
and surviving parts, and pathological execution, interaction and message counts
are reduced. Unreferenceable oversized or malformed public IDs are dropped instead
of hashed, so observation targets, tool composite IDs and native interaction
public IDs cannot silently diverge. Public and native interactions use the same
pending-first retention. Each retained interaction keeps its complete response
contract: field keys, required fields, option values/sets, defaults, conditions,
validation constraints, external URLs and permission resources are never clipped
or rewritten. Only presentation labels/descriptions may shrink. If a pending
contract cannot fit within the whole-envelope budget, projection reports an
explicit error instead of publishing an unanswerable form or changing the
execution outcome. Authors are capped at Swift's 4,096-byte field limit;
reasoning foregrounds are capped at Swift's 32,768-code-point head guard. A final
whole-envelope check falls back to a minimal legal projection, preserving
execution outcomes, if a non-interaction field still escapes the budget. The adapter may encode the envelope at most six times:
one initial check, four degraded stages, and one fixed-size minimal fallback. The renderer source indexes only the message fields used by the one-body
projection (identity, tool display inputs and presence flags) and releases the
duplicate encoded collections before projecting, so peak memory stays close to
canonical state instead of retaining a second full conversation. The projection carries `contentTruncated` so the native reader can explain the
omission/truncation; the authoritative session state is never rewritten. The transport enforces the 32 MiB response/event boundary. An HTTP prompt receipt admits input; terminal native execution facts settle it. New executions retain their input before dispatch. Follow-up message retention
requires a native prompt receipt or matching native inbox/history evidence;
the command's `Admitted` callback still requires its successful HTTP prompt
receipt. Lost HTTP acknowledgement is not automatically retried or converted
into command success merely because a message was recovered. A rejected steer leaves the
running execution available. Permission and form replies release the state lock
while waiting for native HTTP, and interruption cancels and drains those replies.

Idle native forms and terminal-state reconciliation use the same automatic
execution admission; detached state clones preserve initialized ownership maps.
Form replies consume Core-validated native values, including hidden defaults and
conditional omission, rather than decoding numeric input a second time. A local
pre-I/O rejection is explicitly classified for safe claim release and retry.
The native Reader computes public interaction IDs with the same v2 JSON-array
SHA-256 encoding as Go. The shared public-form fallback retains form metadata.

The two embedded `.mjs` files are native OpenCode plugin resources. They have no JS
build step and are loaded only by the external Harness. They register native hooks,
forward calls to the authenticated loopback Go bridge, preserve native tool object
identity and read narrow account facts from native APIs. Instructions, seeded history,
exclusive tool policy, request admission, JSON schema selection and account routing
policy are prepared or checked in Go. The application does not launch a separate
Node service for this adapter.
Runtime startup waits for the native plugin inventory to report `mokusei.harness`
active before its first RPC. OpenCode activates configured plugins asynchronously
after the location boots, and a call made before registration settles is rejected
as `rpc.unavailable` (HTTP 400). The embedded plugin identifies its own inventory
entry by either the entrypoint file or the configured directory after resolving
symlinks; newer OpenCode releases report the configured directory, which must not
be mistaken for an external plugin in isolated sessions.
Bridge configuration is validated and copied before a revision is published, so
invalid schema data or later caller mutation cannot replace a working revision.
Tool aliases include names such as `__proto__`. Closing the bridge cancels and
joins admitted tool/model callbacks before removing its files; runtime shutdown
also joins the SSE reader and its callbacks. Version probes drain their process
group, including wrapper descendants that inherit output pipes.

Native execution uses one server with OpenCode's native storage, authentication and
cache. Mokusei registers only its own root sessions and follows their native
children; unowned session API calls and unscoped session enumeration are rejected.
OAuth refresh stays in the native server. Model services and credentials are
configured by OpenCode. Account telemetry helpers live within this Harness.
Credential material is excluded from durable session/UI state.

Moku target discovery reuses complete same-configuration catalogs and exposes
exact options in its initial creation tool schema. An installation-only deferred target is not an admitted discovery result. A cold configuration waits for account
filtering; complete cached directories return immediately regardless of age.
Expired entries trigger an owned background refresh with a 30-second failure
cooldown. Concurrent refreshes do not block routing through the last complete
snapshot. The native phase has
a 30-second cancellation timer and the whole flight a 55-second budget, with
process cleanup joined. The editor can still show the earlier native projection
with `accountCheckPending`; Moku routing does not use that partial projection.

The full native model inventory accompanies creation options, including disabled,
unsupported and account-excluded models. Unknown capabilities may block a model's
creation branch, but never remove its identity from Moku's routing inventory.
Missing/empty catalogs and read errors block Moku preparation only when no
complete matching snapshot exists. Configuration
identity is checked both at native publication and after account filtering.
Freshness expires after five minutes; routing returns the complete old snapshot
while refreshing. Failed, empty and malformed refreshes never replace it.
Creation and execution still require strict settings reads and native checks. Advisory catalog reads also report cold or
expired state explicitly. Keychain, remote and untracked include-file changes
still rely on TTL/manual refresh or live admission. Workspace context does not
fetch accounts; creation and live model admission retain their native checks.

Ordinary threads require exact provider/model/thinking choices. Native variants are
validated from their effective request encoding, including at model admission.
Mokusei always selects the native `build` primary agent. Settings normalization,
execution snapshots, effective model presentation, restored Thread settings,
isolated prompts all use build, including previously saved
`plan` selections and native configurations with a different default agent.
The native build agent must be available; there is no fallback to another agent.
Settings omit the Agent selector and description, and creation schemas expose no
agent choice. Native model/variant overrides on build still apply.
`auto` permissions reply once to requests that pass native deny rules; forms still
require typed responses. Exclusive sessions reject ambient plugins, MCP and tool
execution. Forks reserve new identities and import frozen history upon admission;
reads use native `/fork` and `/generate` in the source database, retaining native
lineage and cache affinity. The source primary request retains a bounded private
instruction prefix; generate restores it only when history anchors still match,
so native instruction folding does not invalidate a warmed provider prefix.
User/assistant/tool messages remain native fork data. Success and cancellation
clean up the temporary session before closing its independently owned runtime.
Text, file/skill references, PNG/JPEG/WebP/GIF images and PDFs are supported. Audio and
nonautomatic image detail remain explicit errors, matching the previous adapter.

## Permission and account boundaries

`permissionMode` accepts `auto` or `default`. An omitted creation option inherits configured Harness mode, falling back to `auto`. Automatic mode replies once only after native deny policy allows the request; forms still need typed responses. Reconnect skips already answered or stopped interactions, and no wildcard persistent allow rule is installed.

The native Console callback pins credential identity while describing and resolving the selected provider/model/variant. Account switches fail the read. Native OAuth refresh remains native; Go telemetry checks official Console authority, organization and routes, rejects redirects and bounds reads. Unknown capacity remains unknown; credentials never enter public settings or persisted sessions.

Temporary environment removal retries only wrapped `ENOTEMPTY` errors at 20 ms intervals for up to two seconds after process drain. Persistent or different errors remain visible and retain the normal failed-cleanup ownership policy.
Isolated configuration discovery, home-relative file references and permission
paths use the native process environment's `HOME`, with the existing
`OPENCODE_TEST_HOME` override for native permission roots. Isolated completion
reports failed session deletion or runtime/workspace cleanup; a runtime cleanup
failure retains the owned workspace.

Reserved JavaScript property names remain valid tool aliases in the bridge;
no installed-native thread replay is configured here.

## Initial response cards

The overview renderer supplies `initialResponseScope`, computed from the full
execution index and fork/history provenance before compaction. This fixed-size
fact is projection-only and never enters canonical session state. Native cards
use it for ordinary threads with zero or one execution; eligible agent content
retains its existing precedence. Other scopes omit the field.

Settings presentation publishes an immutable native model/agent/default catalog
before optional Console account/remote billing checks finish. The response marks
`accountCheckPending`, but the native editor keeps that transient state silent:
the user sees no banner or retry action while account evidence is merely
unsettled, and bounded non-forced rereads fold in the filtered result. Settled
failures still surface through the CLI status message and retry action. A
pending check is not an authentication success. Exact settings validation,
model descriptions and provenance continue to await the complete filtered
catalog. Initial execution-default capture uses native defaults without forcing
a global cache invalidation; execution admission remains native-owned.

The account phase belongs to SettingsAPI after native publication, retains its
existing bounded budgets, and is cancelled/joined on Close. Billing cannot mutate
an already published native projection. Refresh replaces only the matching
cwd/configuration-cwd/executable/environment/file-generation flight; obsolete
results cannot publish. No disk snapshot or credentials enter UI/cache persistence.

Form string defaults use the same model validator as public answers. External URLs use no-base WHATWG parsing, including nonfatal percent-encoding errors. An empty native form title displays “OpenCode request”; form/session identities remain required.

This Harness does not advertise `ThreadCapabilities.FollowUpOnly`: its native
input protocol has no proven atomic active-only condition. Lazy Moku notices
therefore wait for the next independently triggered input and travel with its
system context, even while this Harness is running. An explicit follow-up-only
Send returns `ErrFollowUpUnavailable` before retaining or dispatching anything;
ordinary inputs keep their existing behavior.

`search.go` supplies completed-execution public passages with their execution IDs
for Moku grep. Existing index text joins the same passages, preserving its prior
exclusions. This extracts only retained Mokusei state, not complete native history;
see the [search contract](../../../services/threadsearch/README.md#moku-deterministic-grep).

Accepted inputs retain `ordinary`/`internal` presentation in message state;
native user-message imports also preserve it when supplied in metadata. Both
search projections exclude internal inputs and user messages with unknown
visibility. Grep reports `unknown-input-visibility` for omitted inputs, including
older persisted messages and native messages without a visibility marker. Public
assistant text remains available even when input coverage is incomplete.

Compact renderer directories retain up to 600 characters of execution `summary` for each
execution, including historical executions, so Report can display a bounded
assistant excerpt without acquiring full conversation content. Native
`executionPreview` pairs that exact execution's text with its own timestamps.
Compact card `text` is still a bounded preview, not the full assistant body; when
the card also selects a reasoning part, the preview is retained instead of being
erased, and a selected text part remains the single body. Prompt, reasoning and
tool-payload admission is unchanged; no latest-execution fallback is used for
historical references.

Catalog caches live on the Harness instance and are not persisted to disk. Close
cancels and joins background refreshes; Moku handle replacement retains caches.

The startup RPC crosses OpenCode 2.0.25 plugin activation readiness. The separate
plugin inventory is advisory with a three-second request budget: failure, absence
or unsettled activation is reported in provenance without discarding a working
native model response. Account cache
identity includes native database credential selection/revision columns without
reading secrets or invalidating on unrelated session writes. Neither activation
nor repeated stable model lists attest every remote provider completed discovery;
see [evidence limits](../../../services/moku/catalog-evidence.md).

Moku routing accepts successful nonempty native inventories, including native
cached/fallback data, without requiring remote source-completion proof. Source
completeness remains unknown in the schema. A matching old snapshot returns
immediately; failed refreshes retain it and add a retained-snapshot note. Cold
acquisition failure still reports an error. See the current
[admission and evidence contract](../../../services/moku/catalog-evidence.md).

Production discovery captures its absolute executable and environment through the
same `captureLaunch` helper as ordinary startup. It passes those captured values
directly to the runtime, rather than invoking a closure that resolves them again.
Before publication and after discovery, the source resolver is checked again;
changed launch/configuration/account identities reject the observation.

Editor, complete, advisory and routing reads use the same detailed observed
source key, including project namespaces and referenced configuration files.
Snapshots carry their acquisition identity before publication, and cache hits
must match it. The outer routing cache verifies that identity rather than
relabeling an inner result. A source change during acquisition rejects that
observation; an old same-key directory remains available on failed refresh.
See [OpenCode/Claude T3 comparison](../../../services/moku/catalog-evidence.md).
