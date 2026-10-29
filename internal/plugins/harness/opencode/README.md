# OpenCode Go adapter

`New(plugin.HostContext)` composes the OpenCode Harness, settings, native model catalog,
installation, workspace discovery, isolated completion, fork/read and Moku telemetry.
The adapter accepts stable OpenCode 2.x releases beginning with 2.0.25. Protocol routes,
native event shapes and the descending session allocator follow the installed
`@opencode/protocol` and `@opencode/schema` 2.0.25 definitions.

Go owns process startup/shutdown, authenticated HTTP, reconnecting SSE, durable log
reconciliation, session identity reservation, state projections, execution admission,
steering, permissions/forms, tools, model validation and provider/account policy.
The installed external `opencode serve --stdio` process remains the model/tool engine.
An HTTP prompt receipt admits input; terminal native execution facts settle it.
New executions retain their input before dispatch. Follow-up input is retained and
acknowledged only after its native prompt receipt; a rejected steer leaves the
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

Moku target discovery always advertises a stable on-demand
`describe_native_harness` tool, whose exact options can reuse the completed catalog.
Background cache warming does not replace Moku tools or repeat session preparation. Advisory catalog and account telemetry
read snapshots and refresh in the background. Exact options and live model
admission still use the full native APIs. Workspace context does not fetch accounts.

Ordinary threads require exact provider/model/thinking choices. Native variants are
validated from their effective request encoding, including at model admission.
Default-agent discovery preserves native `Agent.list` order: the first visible
primary/all agent is the actual native default. Execution snapshots, effective
model presentation and ordinary thread defaults use that same selection even
when no `default_agent` appears in native configuration; `build` is not assumed.
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

Verification is provided by the deterministic integration runner at
[`tools/verification/opencode`](../../../../tools/verification/opencode/README.md).
The runner covers process and credential failure
boundaries with a local fake executable, and optionally exercises the installed
native CLI with a scripted loopback model endpoint and isolated temporary profiles.
The native replay also proves synthetic OAuth refresh and durable rotation in an
isolated profile. It resolves and saves native default execution settings without
`default_agent`, then sends through the production Thread adapter before and after
a cross-provider model/variant change. The loopback model request must use the new
wire model and thinking encoding while retaining conversation history, native
session identity and each execution's original model attribution.
Live native account inference and physical voice playback require separate verification.

Ordinary Thread voice implements `DiscussionPreparer` with an independent native
branch and exclusive Core project read tools. Continuous discussion uses native
prompt/wait rather than transient generate, then deletes only the private branch.
See [discussion semantics](../../../services/threadvoice/README.md).

## Permission and account boundaries

`permissionMode` accepts `auto` or `default`. An omitted creation option inherits configured Harness mode, falling back to `auto`. Automatic mode replies once only after native deny policy allows the request; forms still need typed responses. Reconnect skips already answered or stopped interactions, and no wildcard persistent allow rule is installed.

The native Console callback pins credential identity while describing and resolving the selected provider/model/variant. Account switches fail the read. Native OAuth refresh remains native; Go telemetry checks official Console authority, organization and routes, rejects redirects and bounds reads. Unknown capacity remains unknown; credentials never enter public settings or persisted sessions.

Temporary environment removal retries only wrapped `ENOTEMPTY` errors at 20 ms intervals for up to two seconds after process drain. Persistent or different errors remain visible and retain the normal failed-cleanup ownership policy.
Isolated configuration discovery, home-relative file references and permission
paths use the native process environment's `HOME`, with the existing
`OPENCODE_TEST_HOME` override for native permission roots. Isolated completion
reports failed session deletion or runtime/workspace cleanup; a runtime cleanup
failure retains the owned workspace.

`./scripts/go.sh test -race ./internal/plugins/harness/opencode` covers bridge
revision atomicity and callback draining, environment ownership, version-probe
descendants, SSE shutdown, completion cleanup and Thread admission/cancellation
with local HTTP and filesystem fixtures. The installed-native `thread` replay
also verifies that reserved JavaScript property names remain callable tool aliases.

## Initial response cards

The overview renderer supplies `initialResponseScope`, computed from the full
execution index and fork/history provenance before compaction. This fixed-size
fact is projection-only and never enters canonical session state. Native cards
use it for ordinary threads with zero or one execution; eligible agent content
retains its existing precedence. Other scopes omit the field.

The adapter replay also checks this boundary with shared production-renderer
fixtures in `tools/verification/firstresponse`. The native cross-language replay
is `python3 tools/verification/reading-presentation/run.py --initial-response`.

Settings presentation publishes an immutable native model/agent/default catalog
before optional Console account/remote billing checks finish. The response marks
`accountCheckPending`; the native editor displays this uncertainty and performs
bounded non-forced rereads. This is not an authentication success. Exact settings
validation, model descriptions and provenance continue to await the complete
filtered catalog. Initial execution-default capture uses native defaults without
forcing a global cache invalidation; execution admission remains native-owned.

The account phase belongs to SettingsAPI after native publication, retains its
existing bounded budgets, and is cancelled/joined on Close. Billing cannot mutate
an already published native projection. Refresh replaces only the matching
cwd/configuration-cwd/executable/environment/file-generation flight; obsolete
results cannot publish. No disk snapshot or credentials enter UI/cache persistence.

Form string defaults use the same model validator as public answers. External URLs use no-base WHATWG parsing, including nonfatal percent-encoding errors. An empty native form title displays “OpenCode request”; form/session identities remain required. `interactions_contract_test.go` exercises reducer admission, default preflight and typed answers with native contract regression values.
