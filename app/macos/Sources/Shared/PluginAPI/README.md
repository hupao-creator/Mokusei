# Native plugin contracts

[HarnessPlugin.swift](HarnessPlugin.swift) and [HarnessRegistry.swift](HarnessRegistry.swift) define native Harness registration and presentation. [HarnessThread.swift](HarnessThread.swift) carries public thread state/actions; each plugin interprets its own serialized projection. Shared hosts do not parse another Harness's private timeline.

Overview cards receive only a responder for already-pending permission/question
interactions and a callback to open the reading page. They do not receive
`HarnessThreadActions` or a follow-up draft route, so Overview cannot originate
steer/send input for a selected Thread. Reading surfaces retain the full thread
action contract; Sidecard and Runtime message capabilities are independent.

Moku's `ThreadNote` projection includes a text revision, an independent `readingRevision` CAS counter and at most one server-authored `lastExposure` with the exact earlier text. The strict decoder rejects malformed or inconsistent evidence. An exposure means the UI completed eligible foreground viewport coverage; it is not user approval or proof of understanding. The Host derives its update indicator from this projection, never from a local seen file.

`HarnessThread.mokuHistory` identifies a previous Moku conversation retained
after switching Harness. It requires an archived envelope without the current
Moku flag or note. Hosts use this validated field for the read-only history
selector; the Runtime rejects execution, settings changes and unarchive attempts.

[ApplicationContracts.swift](ApplicationContracts.swift), [ApplicationCapabilities.swift](ApplicationCapabilities.swift) and [ApplicationRegistry.swift](ApplicationRegistry.swift) describe native application surfaces and injected operations. Runtime transactions and background-agent authority remain in the [Go Application host](../../../../../internal/hosts/applicationhost/README.md).

`ApplicationBackgroundExecutionSettings.enabled` is independent of inheritance
and retained overrides. Missing values decode as true; false round-trips with
both modes, and changing a mode/profile preserves the switch.

[SidecardPlugin.swift](SidecardPlugin.swift) defines descriptors, thread-bound context, lifetime, intent routing, file/attachment and voice capabilities. Plugins return content while the host owns outer size, suppression and transitions. `openURL`, compose and send notifications are semantic intents; sibling plugins do not call one another by identity. The built-in Conversation display accepts no compose/send intent; reading follow-up routes open the Host-owned detail Moku composer. Availability changes retire an expanded Sidecard before the next Host snapshot. A voice capability exposes a private read-only discussion, not a send action against the source task.

[Composition/NativePlugins.swift](../../Composition/NativePlugins.swift) registers the Codex, Claude, Pi, OpenCode, Report/Tag and Conversation/Browser/Voice modules for macOS. Runtime publishes active Sidecard enablement; desired settings alone do not authorize a native instance. Local plugin state is scoped by thread identity.

Execution reference metadata carries the Harness identity and display name. Report
cards and related execution rows obtain its native logo through the renderer's
execution references capability, preserving the Harness's appearance-specific colors.

[SemanticTagLabel.swift](SemanticTagLabel.swift) validates names and emoji maps using the generated pinned table. [HarnessGitStatus.swift](HarnessGitStatus.swift) supplies typed worktree facts to standard card extensions without turning Git into a Harness-specific feature.
Its `lineStatsError` describes a failed statistics attempt independently of a
stale whole-worktree read. Unknown totals have no numeric value; known zeroes
remain ordinary counts. The host validates paired totals and errors at the wire
boundary before supplying these facts to Harnesses.

Presentation implementations use [PluginUI](../PluginUI/README.md). New plugins implement these boundaries and are composed explicitly rather than adding hidden global discovery.

`SidecardView.composer` optionally supplies a `SidecardComposerRequest` for the
selected activity. Its stable operation ID, localized placeholder, readiness,
submit and cancellation callbacks let the Host lend the resident text composer
without transferring the normal Thread/Moku draft or runtime authority. Only an
available, selected and unsuppressed card publishes a request. Losing selection,
covering or release retires it; callbacks remain fenced to their owning operation
and reading visit. Browser uses this for annotation descriptions; execution
Sidecards continue to own no composer. See the
[annotation input contract](../../../../../design/browser-annotation-resident-input.md).

`ClientWebNavigation.localFileURL` parses absolute local paths and local `file:`
URLs once, retaining literal spaces/Unicode and file-URL query/fragment escapes.
It rejects remote authorities, credentials, ports, network-path references and
NUL paths; relative paths acquire no filesystem base.
`ClientLocalHTMLDocument` admits readable regular `.html`/`.htm` files on a local
volume, resolves symlinks and validates the target extension. It supplies the
canonical URL to native Browser navigation and the system HTML fallback.
Its `readAccessURL` is the containing directory for assets, except that a document
at the filesystem root grants only that file, never `/`. This is a user-click
document capability, independent of Harness
execution permissions; it grants no runtime/command bridge to authored HTML.

`HarnessRenderContext.contentResource` acquires an independently owned content
handle on each call, even for equal scopes. A mounted consumer retains that
handle and releases it when leaving; it cannot revoke another consumer's handle.
Shared execution-disclosure demand belongs within the mounted row. The host
revokes every remaining handle when the conversation surface retires.

Global Harness settings sessions belong to the connected workspace and may be
prefetched before any editor mounts. Editors join the resource's pending read;
unmounting a global editor keeps its typed presentation cached. Source changes
invalidate pending results, while disconnect/reload or scope removal releases
the resource. Thread settings sessions still belong to their mounted editor.

[SidecardAttachmentImport.swift](SidecardAttachmentImport.swift) provides lifetime-bound device-local file/byte staging plus the runtime attachment policy. Browser annotations retain the existing URL-only staging capability. Agent detail input uses the Host-owned Moku composer and its attachment service; Conversation is an execution display.

`SidecardContext.executionReveal` is a visit-scoped detail-send request: its UUID
is stable across admission, and its optional receipt supplies the exact accepted
execution. It does not itself authorize execution or establish running state.
`executionHandoff` retains only the selected terminal execution during the Host's
move into main. Generic Browser sends and compose notifications do not acquire
these presentation requests.

`ApplicationExecutionLink` admits only the internal `mokusei://execution` URL
with exactly one nonblank `threadId` and `executionId` query parameter, without
credentials, ports, path or fragment. It yields an `ApplicationExecutionRef`;
the Host checks public ordinary-thread membership. `HarnessReadingTarget.position`
adds `result` alongside the default `start`, preserving execution identity and
the per-click request ID. Harnesses pass semantic positioning with their public
active-execution fact to the shared reader, alongside their existing private
message-anchor resolution.

`HarnessPluginDescriptor.installationGuide` is an optional plugin-owned official
installation URL. First-run discovery uses it for missing Agents, keeping the
Host independent of Harness names and installation instructions.

`HarnessPlugin.readingPrefetchScopes` supplies optional opaque reading scopes
without constructing a view or interpreting another plugin's content. The outer
Agent route prefetches the manifest and at most the first supplied scope while
its panel travels. Codex chooses its target/latest execution row; other Harnesses
default to manifest-only preparation. Cancellation belongs to the route visit.
Runtime retention owns a live subscription independently of any view or action;
each visible consumer still acquires and retires its own handle.

`HarnessThread.executionTitles` decodes the optional public execution-ID-to-title
map (missing means empty; malformed or empty entries are rejected). Harness
readers pass only the matching execution's title into their conversation rows.
The catalog title remains independent metadata and cannot fill a missing history
entry. This envelope also persists through ordinary offline catalog recovery.

`HarnessThread.mokuInterruptedExecutionID` decodes the optional nonblank
`mokuInterruptedExecutionId` envelope field. Missing provenance remains unknown;
the client preserves it through catalog snapshots, deltas and offline storage
without inspecting private Harness state.

`ApplicationExecutionReferencesUI.execution` supplies a host-owned reader for a
validated ordinary execution reference. The mounted host observes deletion and excludes private Moku conversations, while `NativeHarnessThreadView` owns acquisition/release and the
single-execution presentation. Report plugins never decode Harness timelines.

`HarnessPlugin.executionPreview` projects bounded assistant text and validated
start/end timestamps for the requested execution ID. Each Harness interprets
its own private state; Host/Report never parse another Harness's timeline.
`ApplicationExecutionPresentation.preview` carries that value to the related
list. `ApplicationExecutionPresentation.emoji` uses the same validated generated
Thread metadata as all Harness cards/readers. Emoji is Thread-scoped, not an
execution history field; absent/invalid metadata and deleted Threads yield nil.
The related list uses the reader's 📝 fallback and hides decorative emoji from
accessibility. Titles use the matching `executionTitles` entry (a localized generic
execution label when absent), never the current Thread title. Missing historical
preview data stays absent rather than borrowing the latest execution. Preview
text is capped at 600 characters; a non-running execution with no end time is
shown as unknown duration rather than ticking indefinitely. Super Thread relations
now obtain authoritative exact-execution state/timing from `report.relations`,
separate from current Thread state. Bounded native previews remain exact-ID-only.
