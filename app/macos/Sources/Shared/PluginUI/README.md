# Shared native UI

This target supplies design resources, Harness cards, Markdown reading, conversation layout, composer and forms to the macOS application. AppKit adapts native text, input and viewport behavior within the Swift package.

The shared `NativePalette.thread` dark reading surfaces use a charcoal canvas,
progressively lighter content/interaction/composer fills and warm off-white text.
SwiftUI, TextKit and the panel transition resolve the same adaptive assets;
other readers consuming this palette share its dark tones. Light variants and
Overview/Settings palette definitions retain their existing values. Claude's
Overview workflow cards and Thread settings hints also consume thread surface
and muted colors, so those shared consumers inherit the dark changes. See the
[Notion reference, palette decisions and sprint verification limits](../../../../../design/agent-detail-dark-tone.md).

`nativeReadingEscape` preserves native editor/IME, menu, sheet, popup and WebKit
cancellation before reading navigation. Hosts can supply
`nativeReadingInputCancellation` to fold resident input first when native reading
owns Escape; returning `true` consumes that Escape without navigating the reader.
Pinned Agent-detail input returns `false` so the existing document/Sidecard
cancellation proceeds without folding that editor. Its host-owned editor/Dock
Escape callback closes the detail; generic reader cancellation stays unchanged.
The host's own input surface can use the same fallback after editor focus moves
to its controls. The callback does not bypass viewport/focus or transient-control
ownership checks and defaults to absent outside the host's scene.
`nativeReadingExitCommand` applies the same resident-input priority to SwiftUI's
focused-child exit route (including execution Sidecards and nested history),
using the shared native editor/marked-text/transient-control boundary. It does
not install another global key monitor or replace editor-specific exit actions.
The focusable history sidebar uses this route too: foldable resident input gets
first refusal; otherwise Escape returns to the current document directly.
Its Arrow/Return navigation and document-owned cancellation remain independent.

Dev-only [layout logging](../../../build/layout-logging.md) combines window-wide
AppKit frame/bounds observation and coalesced, budgeted discovery with semantic
SwiftUI geometry hooks in shared
readers, timeline columns/documents, composers and scroll containers. It does not
sample animation presentation frames or read content/accessibility values.
Overview also records bounded, anonymous logical relayout transactions (before, plan and terminal outcome), separate from geometry callbacks. Per-transaction card indices never contain model IDs or hashes. Individual timeline rows have no global geometry hook. IO failure stops collection
and restores native observation flags without remounting focused product controls.

Thread, Report, Git and Moku history panels share
[`NativeReadingPanelCloseButton`](Conversation/NativeReadingPanelCloseButton.swift).
`nativeReadingPanelClose` places the 32pt circular target 14pt from the panel's
top-left edge. Pair it with `nativeReadingPanelViewport`: its default 48pt top
clearance keeps both scrolling content and native scrollers below Close. The
main Agent reader instead clears Close horizontally with its reserved history
rail, allowing 22pt viewport insets at both ends. Report uses 8pt insets on all
sides and `overlaysContent: true` for an opaque canvas backing under Close.
The Report host clips the viewport with a 14pt radius before applying its 8pt
insets, matching the outer panel's 22pt radius. Spacing outside the circle
is not a close target. The button follows reading-palette light/dark colors,
hover/press, disabled and increased-contrast states, with a visible keyboard
focus ring and caller-owned localized help/accessibility labels. Close uses
activation-only focus: pointer clicks do not acquire focus or flash the ring,
while system Keyboard Navigation retains focus indication and Space/Return
activation. Callers keep
their own close callback and Escape/navigation ownership; the button installs
no global keyboard shortcut. Agent Sidecards use the corresponding right-side
launcher as their open/close toggle and have no independent Close icon. Browser
and Voice retain their activity toolbars and media/document actions.

`NativeReadingPageStack` optionally reports whether its retained parent is
participating in presentation and awaits host preparation before a settled-page
return. Opening/reversal remains immediate. Preparation shares the stack's route
generation and cancellation ownership; a late completion cannot close a replacement.
Hosts without these hooks retain the same navigation behavior. Overview uses them
to coalesce hidden display work while retaining native controls and authoritative
state reception. Its opt-in `isolatesParent` surface keeps that state in a
separate native host. Once a panel settles and its live heading owns the identity
ink, it hides the live host without capturing a bitmap. The parent fades fully
out during panel travel, exposing the window's existing ultra-thin material;
no Overview cards remain behind a settled reading panel. Resizing leaves the
hidden card tree's viewport unchanged. Return preparation unhides the same host,
applies the latest environment and viewport, and waits for the existing canvas
receipt before sampling the destination. Return travel fades the refreshed cards
back in. No snapshot allocation or CPU rasterization blocks reader admission.
Nested reading stacks keep their existing parent presentation.
The retained native host consumes the viewport already assigned by the workspace
and disables its own safe-area regions. Applying the titlebar inset a second time
would shorten and clip the Overview canvas below the full-content window's top.

Panel opening freezes Overview display projection immediately. The panel's
position, rounded aperture and closing fade run on Core Animation layers in
[NativeReadingPanelTransition](Conversation/NativeReadingPanelTransition.swift),
with ordinary Agent card readers preloading only after the native animation-start
callback. Their host stays transparent, hit testing and accessibility stay closed,
and reading controls are not registered until arrival. Primary Markdown and
TextKit preparation therefore overlap compositor-owned travel without advancing
text entrance or secondary surfaces. Source-less and non-Agent entries retain
their existing mounting gate. The retained reader has one stable native hosting view after admission;
its environment comes from the enclosing SwiftUI surface and its layout width
stays at the destination width throughout return travel. Reversal samples native
presentation layers, and generation-fenced completion cannot admit or close a
replacement route. Resize, cancellation, reduced motion and inactive scenes
settle through the reading stack's existing ownership. Vertical history and
non-panel navigation retain their original driver. Returning refreshes the
retained Overview before starting a settled panel's close.

The stack publishes `nativeReadingEntranceReady` from that actual completion
boundary and, when present, the existing title/emoji ink handoff. Secondary
layout cannot move the heading destination before the live reader owns it.
`NativeReadingEntranceStage` additionally waits for a newly mounted
folded layout to commit before auxiliary motion is admitted; its queued callback
is invalidated on disable, detach or replacement. This prevents an initially
selected execution Sidecard from first rendering at expanded width. Agent detail
also waits for `NativeReadingContentRevealStatusKey`: only active main contributes
readiness, and unfinished line/footer fades keep the gate closed. Turns wait for
primary admission, then use actual last-line and footer animation completion.
Loaded empty/error states can finish without a text animation; mounted Agent
loading placeholders keep the gate pending even alongside loaded sibling rows
and during their visual grace period. The identity-only reader cannot admit
content. Reduced Motion skips fades but keeps Markdown
readiness, and teardown cancels late completion. See the
[reading choreography](../../../../../design/reading-entrance-choreography.md)
for lifecycle details and sprint verification limits.

Codex reading validates and decodes each changed opaque state on its background
actor before publishing its immutable typed result. Superseded and unmounted
requests cancel delivery. Collapsed execution work also skips native row
construction; errors, final replies, disclosure and canonical content keep their
existing policies. See the [investigation and manual performance evidence](../../../../../design/thread-open-animation-investigation.md)
for measured scope and limits; no tests or CI were run for this change.

`NativeComposerTextInput` accepts an optional native `placeholderIcon` beside its
placeholder string. Both disappear when text is present and are decorative,
pointer-transparent and hidden from accessibility; the plain placeholder string
remains the editor's accessibility label. The icon does not enter draft, paste,
selection or IME state, and does not change native editor identity.
The icon's square seat has an explicit first-text-baseline guide: its center
aligns with the system font's cap-height center on the first placeholder line.
This replaces provider-dependent vector/SF Symbol baseline defaults, preserves
each Harness mark's aspect ratio and artwork, and keeps multiline placeholders
anchored to their first line rather than centering the icon on the whole paragraph.
Hosts can set `placeholderLineLimit` independently of the multiline draft editor.
Moku uses one line with tail truncation and trailing editor clearance; the optional
placeholder icon retains its fixed square seat when the text is compressed.

## Reading placeholders

[NativeReadingPlaceholder](Conversation/NativeReadingPlaceholder.swift) separates
whole-surface loading from inline loading. Host resource admission and Codex's
initial state decode center their placeholder within the available reader
viewport; scoped turn loading stays inside the timeline's existing reading
column. Inline placeholders reserve only their text/padding height, independent
of eventual short or overflowing content. Neither form imposes a fixed width.

Loading text appears after a cancellable 180ms grace period, without animation,
focus changes or pointer interception. Its layout is reserved during the delay,
and it is absent from accessibility until visible. Unmounting cancels the delay
and resets visibility; errors and retry controls appear immediately. The shared
semantic palette and locale follow the reader. This is presentation state only:
content acquisition, decoding, caching and resource release are unchanged.
See the [recording review and validation limits](../../../../../design/reading-placeholder-alignment.md).

Agent execution summaries suppress a group only when every member explicitly
reports no summary content and no positive reasoning usage is reported for that
group. Empty reasoning and completed Hooks without output qualify; tool calls,
other activity kinds, running/failed/cancelled Hooks, interactions and unknown
rows remain admitted. Classification follows content and native identity rather
than position or zero counts. Lightweight Codex/Claude history carries output
presence independently of stripped detail. Full/Moku readers retain the original
disclosures and detail loading. See the [investigation](../../../../../design/empty-execution-summary.md)
for the reported Hook group, asynchronous behavior and sprint validation limits.

## Scrollbars

[NativeScrollView](Design/NativeScrollView.swift) is the opt-in SwiftUI viewport;
`NativeStyledScrollView` is its AppKit counterpart. Both install native mini
`NSScroller` subclasses that suppress only `drawKnobSlot`, including its hover
highlight. The system owns knob colors, hover/tracking, fade timing and
accessibility rather than a custom thumb or gesture. The subclass explicitly
supports overlay scrollers; overriding the entire drawing method would break
AppKit's independent knob fading. AppKit's preferred style preserves Always,
When Scrolling and Automatically based on input device, including live
preference/device changes.
Overlay knobs appear during scrolling and hide afterward, remaining available
during native hover/drag tracking. In AppKit-owned viewports and the scoped
TextEditor/List adapter, a persistent (legacy) system style keeps its scroller
resident so its native gutter stays reserved at every content height:
crossing the overflow threshold neither narrows the viewport nor shifts centered
content or rewraps text. The trackless slot and AppKit's empty knob paint nothing
until scrolling is possible. Accessibility and device preferences take priority
over automatic hiding. No global appearance, swizzling,
window-wide traversal, wheel monitor, preference write or replacement scroll-position model
is involved. Light/dark, Increase Contrast, Reduce Transparency and Reduce Motion
stay on the native rendering path; this component adds no animation.

`NativeScrollView` leaves `autohidesScrollers` with SwiftUI, while still installing
the trackless mini scrollers and following the preferred native style. SwiftUI
must own both indicator visibility and the document-width proposal: forcing a
resident AppKit gutter while its initial document is empty can leave loaded
content measured at full width until the first scroll. In legacy mode its gutter
is allocated when content becomes scrollable, rather than reserved for short
content. Content loading can therefore change the available width; scrolling an
already loaded document must not. Explicit hidden indicators remain SwiftUI-owned.
The AppKit subclass and scoped control adapter retain their resident-gutter policy.

The first-load investigation used a temporary visible window containing the
production wrapper, an initially empty document, delayed message rows and a
centered 680pt reading column. In a fresh 900pt legacy-mode window, forcing
autohiding off left the document at 900pt until the first native wheel scroll,
then narrowed it to 883pt and moved the column from x=110 to x=101.5. The native
clip width stayed 887pt throughout: the scrollbar was already resident. With
SwiftUI retaining autohiding, the loaded document measured 883pt before scrolling
and the column stayed at x=101.5 afterward. A 420pt window retained x=18 and a
process-local When Scrolling override retained x=110 with a 900pt overlay viewport.
An additional local TextField retained focus and its draft across wheel scrolling
and accepted further typing; nested explicitly hidden indicators stayed hidden.
These were isolated manual observations, without Runtime or profile data, not a
full fresh-app Thread Detail, composer/IME, physical-device or live-preference
acceptance run. No tests were added or run for this investigation.

The SwiftUI adapter is a noninteractive background **inside its own content**.
Do not attach it outside a viewport: nested code/table panes must configure their
own scroll view rather than the surrounding timeline. Existing `ScrollPosition`,
`ScrollViewReader`, geometry callbacks, bounce policies and enabled axes remain
at their callers. Each wrapper refreshes its own scroller after layout, since
SwiftUI may install or replace it as content grows. Nested viewports remain
independently scoped. Explicitly hidden navigation/chip indicators stay hidden.

`nativeControlScrollbars()` opts in a SwiftUI `TextEditor` or `List` that owns
its own internal viewport. Apply it directly to that control; an enclosing
`NativeScrollView` cannot style nested editors. Paired background/overlay markers
bound the control's native children even when SwiftUI flattens siblings. Deferred,
coalesced configuration handles mounting and replacement without traversing the
window or configuring adjacent controls. Native text bindings, table selection
and the responder chain stay with SwiftUI/AppKit.

Inventory and integration boundaries:

| Owner | Scrollable surfaces | Integration |
| --- | --- | --- |
| Shared conversation / execution Sidecard | Timeline, activities, Markdown code and tables | SwiftUI wrapper; timeline diagnostics remain timeline-owned |
| Shared composer | Native multiline editor, attachment strip, host file picker | AppKit subclass and control-scoped List adapter; attachment indicators remain hidden |
| Settings and shared selects | Main form, section strip, agent/error detail, native textareas, option and model menus | Wrapper/subclass only; bindings, validation and menu focus unchanged |
| Moku | Note (including short viewport), directory completion, Talk, dispatch details and interaction bodies | Wrapper; completion uses native drag/accessibility instead of its old custom thumb |
| Overview | Tag/filter navigation strips | Wrapper; existing hidden indicators and canvas input routing retained |
| Git | Worktree/file list, diff reader and synchronized horizontal code panes | Wrapper/subclass; line selection and horizontal synchronization remain owned by Git |
| Plugins | Report relations, OpenCode process, Browser annotation list and Voice transcript | Wrapper; Browser comment TextEditor also uses the control-scoped adapter |
| Harness interactions | Codex JSON elicitation, Claude permission/elicitation/reply and OpenCode permission/custom-answer editors | Control-scoped TextEditor adapter; form state, validation and actions stay with each Harness |
| WebKit Browser | External documents, frames and page-owned overflow | WebKit and the page own scrollbar styling |
| Report HTML | App-owned custom-scheme documents, textarea and nested overflow | `NativeWebScrollbarStyle.reportScript`; thin, trackless native controls; external frames remain page-owned |

Report's `reportScript` selects thin WebKit scrollbars with transparent tracks
and foreground-based thumbs in app-owned documents. A custom-scheme ownership
guard excludes external pages even after main-frame navigation; app-owned frames
use the same policy. Existing navigation continues to reject blank/srcdoc URLs.
WebKit retains scrolling,
tracking, fading and system display preferences. The viewport foreground follows
body styling, and nested overflow uses its own text color. Constructed stylesheets
support restrictive CSPs; shadow roots, custom canvas scrollbars and external
frames remain document-owned. The Browser does not inject scrollbar styles into
external pages. The expanded Overview relations list uses `NativeScrollView`;
the collapsed card is clipped and the onboarding illustration does not scroll.

Settings, the general model selector, Thread Detail TOC and Note are parallel
work areas. Changes here are limited to viewport construction and removal of
local style overrides; do not replace their page structure, state or navigation
when integrating. A new TOC/model menu should use the same wrapper or AppKit
subclass and retain its own selection/reveal logic. The baseline includes main's
Note history (#106) and Overview framing (#107).

Run `python3 tools/verification/scrollbars/run.py` from the repository root for
the windowless production AppKit boundary replay. It checks repeated configuration,
document/clip identity, scroller identity after installation, selection and scroll
offsets, native targets/accessibility role, enabled axes, four appearances,
transparent normal/highlighted tracks in both styles, stable gutters while content
crosses the overflow threshold on both axes, empty-knob invisibility and
preference-notification isolation. Mounted, windowless SwiftUI TextEditor/List fixtures check overflowing
controls, nested/sibling isolation, editor bindings, native row/text selection,
offset retention, preference notifications, control replacement and List viewport
width across its own overflow threshold. The existing WebKit fixture exercises the shared styling script, including
CSP, dynamic overflow and color changes; its historical Browser injection scope
does not certify the current Report ownership guard or Browser exclusion. It never
opens a window or changes system preferences. Headless Swift tests use
`MOKUSEI_TEST_HEADLESS=1`; display cases report skips, not passes. These checks
cannot certify rendered WebKit/overlay thumb pixels, hover/fade timing, actual
accessibility preference changes, the complete mounted application, focus/IME
behavior or physical mouse/trackpad feel.
Existing mounted composer, reading, Markdown, Settings, Git, Note and Browser
suites supply hosted graphical coverage; manual visual comparison with the
reference remains unperformed when only headless execution is allowed.

## Reading and execution disclosure

Ordinary Agent Thread opens at the latest content bottom when its execution is
running, including a default execution link and returning from the history TOC.
Completed/history executions keep their existing heading or requested position;
explicit message links keep their message anchor. The four Harness adapters carry
message-target presence independently of asynchronously resolved anchors.
`ThreadConversation` owns this navigation policy; `HarnessMessageTimeline` owns
initial placement and follows content/viewport geometry through scoped row loading,
projection and Markdown layout. Native scrolling or reading scroll controls take
over from automatic following; later content cannot pull an upward reader back.
Returning to the running document or choosing “jump to latest” enables following
again. Explicit reading visits retain position ownership while their anchors
resolve, including when an inline historical execution stops pausing follow.
Generic execution changes cannot supersede that visit. This does not change
reading-stack motion or projection/resource ownership.

Main reading also scopes its default position to the displayed execution. The
first conversation index can move a live execution into its Sidecard after main
has already opened at the live bottom. When that changes the main document to a
completed execution, the timeline releases the old follow state and returns to
the heading unless the user or an explicit reading visit owns the position.
Finishing an execution without changing the displayed document keeps the current
position and final-output following; live Sidecard output retains its own follow
behavior. This correction was reviewed against the reported recording and
checked statically in sprint mode, without new tests or regression runs.

The first reading request is resolved before mounting the page stack. A direct
history/result entry therefore starts on that document without first mounting
current or sliding from it. A never-visited current document is not acquired or
rendered behind that entry; an already mounted current reader remains retained
with its scroll state. Explicit TOC navigation still admits current for the
existing return transition. Result links keep their reply anchor rather than
forcing the document heading, and manual scrolling takes ownership even before
a non-following request's delayed anchor arrives. A new request may locate again.
See the [recording, version and local-log investigation](../../../../../design/thread-opening-entry-admission.md)
for evidence and the sprint verification limits.


The timeline keeps exact scroll geometry in a view-owned observable reference.
Only its small reading-control registration reads that geometry during view
construction. Native offset updates therefore refresh the control descriptor and
stale-handle fencing without rebuilding the document's row tree. Follow, locate,
prepend retention and relative scroll commands still read the latest geometry;
visible-row projection is shared by the document and registration per body pass.
See the [scroll investigation](../../../../../design/thread-scroll-observation.md)
for the measured update counts and the remaining validation limits.

Ordinary Agent Thread detail withholds assistant reply bodies while their native
message status is `streaming`. While an execution is running or waiting for the
user, each settled message renders its complete Markdown; a later streaming reply does not replace the
last settled reply. Once the execution terminates, intermediate ordinary replies
join execution work: hiding work removes them, and showing work includes them
only in the shared summary. The last non-error reply, pending interactions and
independent errors stay readable. A message visit carries its resolved anchor
through current and historical readers and admits that target reply without
revealing sibling work. Native lifecycle, rather than reader focus or footer
timestamps, determines this transition. Failed/cancelled messages retain their
available text. Pi
also releases retained text when its owning execution terminates, because that
Harness can leave a message marked streaming after settlement. OpenCode applies
the gate to reply text parts, including child sessions, without hiding reasoning
or tools in the same native message. Execution status, pending interactions,
reasoning/tool records, composer and backend event delivery retain their own
lifecycles. This policy lives in the four Harness readers, not the shared
Markdown renderer or other conversation surfaces.

[Reading/NativeMarkdownView.swift](Reading/NativeMarkdownView.swift) renders message-level streaming content as literal selectable text only when no reading viewport is known. Mounted Thread timelines supply `nativeReadingPageCapacity`, so [Reading/NativeStreamingPage.swift](Reading/NativeStreamingPage.swift) instead holds the open page back until it closes. Streaming revisions do not enter the ordinary Markdown parser; a settled prefix is parsed at top-level block boundaries and published one page at a time. On settlement, rich rendering resumes; obsolete parsing results cannot replace a newer streaming revision. Completed messages remain rich even while another message in the turn is active.

A streaming page is the visible content height of the owning `HarnessMessageTimeline` (viewport minus its fixed top/bottom insets, in points). Only complete top-level blocks are parsed, so a page break can never fall inside a fenced code block, table, list, blockquote or indented code block; an atomic block that alone exceeds a page is revealed whole. The open page stays invisible until the next settled block would not fit (or its measured height already fills the page), and completion flushes the remainder after reparsing the whole source. The reparse resolves reference definitions and footnotes that point at later chunks; pages rebuild only when that whole-document result differs from the already displayed blocks. Flushes reuse `NativeReadingPageTiming.replacementAnimation` for the vertical page entrance and honor Reduce Motion. A message that is one unsplittable block (for example a single long list or an unfinished paragraph) therefore appears when that block closes or at completion; multiple chunks in one state update coalesce into one flush. Because only closed blocks render, a following timeline's content height and follow scroll change at page flushes, not once per streamed token; the follow, pause-on-user-scroll and jump-to-latest contract is unchanged and settles after each flush.

[Reading/NativeMarkdownParser.swift](Reading/NativeMarkdownParser.swift), [NativeMarkdownText.swift](Reading/NativeMarkdownText.swift) and [NativeMarkdownTypography.swift](Reading/NativeMarkdownTypography.swift) own parsing and native text layout. Inline-code URL links retain link actions and selection; tables derive height from laid-out content. Mermaid fences display source. Native selection uses the active reading selection palette consistently across blocks. Local absolute paths and local `file:` URLs render image syntax and add an inline preview below ordinary file links, while retaining native link actions. Local files bypass attachment resolvers and network loading; the composer ImageIO thumbnail loader decodes off the main actor (2048px maximum edge, 64MiB source limit). Text attachments fit the reading width and a 480pt height while preserving aspect ratio. Missing, unreadable and non-image sources retain their link/alternative text. Remote file hosts and executable URL schemes are rejected; relative paths have no inferred filesystem base. Local rasters live only with mounted Markdown blocks and refresh on remount.

Markdown tables reserve the native mini horizontal-scroller gutter in their
measured content height when the system prefers persistent scrollbars. SwiftUI's
horizontal viewport otherwise measures only the Grid, while AppKit subtracts
the gutter from the visible height and clips the last row. Overlay scrollbars
reserve no space; preference changes update this reservation. Row wrapping,
app zoom and adjacent block spacing continue to use intrinsic content layout.

Absolute local HTML destinations and local `file:` HTML URLs retain the same
native link action throughout paragraphs, headings, lists, quotes, table cells,
reference links and footnotes. Inline code containing one such destination is
clickable like an inline-code HTTP(S) URL, including paths with spaces. Ordinary
unlinked filesystem text and fenced code remain literal. File URL queries and
fragments survive rendering; absolute paths treat `?` and `#` as filename bytes
(use a file URL for navigation suffixes). The shared PluginAPI parser decodes
path escapes once; the Browser/Host validates filesystem eligibility on opening.

Markdown source preprocessing preserves code characters and recognizes footnotes
before entity decoding; escaped syntax stays literal. Labels containing whitespace remain ordinary reference links rather than footnotes. [Reading/NativeMarkdownSourceMap.swift](Reading/NativeMarkdownSourceMap.swift) records each physical line's content start as bundled cmark consumes its quote/list prefix. Inline positions map through the retained raw block lines after reference definitions are removed, so lazy continuations, Setext, tabs and multiline literals share one source mapping rather than fixed column adjustments. BOM removal and NUL replacement retain physical byte provenance for every input line, including nodes without paragraph traces. Table cells also map their whitespace trimming and escaped pipes back through those input coordinates; a read-only parser hook observes each row’s actual container prefix without changing the AST. Paragraph-to-table promotion retains the complete original trace for both header cells and the synthesized preceding paragraph. Bare-URL rewrites stay within the original cell, preserve destination escapes until cmark decodes them, and escape generated pipe syntax so later cells cannot be swallowed. The mapper directly declares the already-bundled cmark 0.9.0 and isolates access to its exposed parser/block state; a cmark upgrade must rerun the source-range matrices and native Markdown replay. Parser cache keys, stored SwiftUI inputs (including message and code-block wrappers), document revisions and rendered text comparisons preserve raw UTF-8 identity, so canonically equivalent Unicode sources cannot substitute URL or copy bytes. Footnote labels use Unicode
case folding and opaque URL-safe destination identities, including literal percent
sequences. Lazy paragraph continuations remain in their note. Bare HTTP(S) URLs
retain Markdown punctuation in their paths. Image alternative text flattens inline
formatting and is shared by native partial and whole-document copies. Whole-table
copies retain empty columns; keyboard navigation clears joined selection in every
block. List marker widths and table inline-code padding participate in actual
layout measurements. Footnote returns reveal references through nested table and
conversation viewports. Run the [Markdown native replay](../../../../../tools/verification/reading-presentation/README.md#markdown-reading-regressions)
for production rendering, selection, copying and navigation fixtures.

`NativeMarkdownView` has an optional applied-document callback for Moku note exposure. It reports the requested document token only after the production parser result is applied, including when two versions produce equal blocks. The callback also reports conservative vertical-coverage eligibility from the production presentation tree: text headings, paragraphs, lists, quotes, rules and footnotes can qualify; code, tables, images and links that may load local previews cannot. Other readers omit the callback. The note host separately measures viewport, window qualification and dwell; a parser result by itself is never reading evidence.

### Note execution capsules

`NativeMarkdownView.executionLinkHarnesses` opts a host into native execution
capsules. `nil` retains ordinary Markdown rendering; an empty map still renders
neutral capsules. The Host supplies only public ordinary-thread brands from its
plugin registry. Brand identities participate in the rendered-block and TextKit
input comparisons, so catalog hydration changes logos without a note revision.
`NativeMarkdownExecutionLink` hosts live clear Liquid Glass in TextKit attachment
seats, with full-title copy descriptions and pointer passthrough for document
selection. Its accessible Button routes through the document-owned current link
action. Attachments remeasure at actual container widths and retire their native
hosts when the corresponding source disappears. Other Markdown surfaces and
ordinary web links retain their existing text behavior.
The attachment seat reserves vertical space around the compact glass capsule;
TextKit includes that space in line layout and pointer targeting, including for
wrapped titles, while the capsule remains aligned with the surrounding baseline.

Repeated native layout/selection notifications retain a capsule's SwiftUI glass
root when attachment, selection, locale and appearance are unchanged; its action
still forwards to the current callback. Width/scale measurements are bounded to
eight entries per text input revision and checked before constructing attributed
content. Probes restore the actual displayed container width, and plain prose
does not become width-dependent merely because its document enables capsules.
See the [Note performance measurements](../../../../../tools/verification/moku-note-performance/README.md)
for the isolated production-control comparison and its visual limitations.


[Conversation/ThreadConversation.swift](Conversation/ThreadConversation.swift) and [ThreadTimeline.swift](Conversation/ThreadTimeline.swift) organize reading from the Harness's public turn index. [ThreadExecutionGroups.swift](Conversation/ThreadExecutionGroups.swift) presents adjacent execution rows under a static summary with reasoning/tool counts and reported reasoning usage. In Agent Thread detail, the reading header's execution visibility control shows only this summary: nested Used tools group titles, Hooks, tool calls, commands, reasoning bodies and failed-tool diagnostics are details and never mount. Agent-only background terminal/task sections likewise show static counts/status rather than commands or descriptions, and hide with work; task failure is not a standalone Harness error. Summary-only historical groups do not acquire the scoped loader in [ThreadDeferredExecution.swift](Conversation/ThreadDeferredExecution.swift). Other conversation surfaces retain full member rows and scoped historical demand while visible. Execution membership takes precedence over attention styling, so a tool failure cannot escape the visibility group. Standalone errors and pending interactions keep their own timeline rows; a visible nonmember splitting a native run receives distinct summary identities. The summary itself has no disclosure arrow, hover treatment, keyboard focus or accessibility/reading action. Individual activity disclosures on other conversation surfaces retain their existing behavior.

[ThreadDetailFrame.swift](Conversation/ThreadDetailFrame.swift) and shared typography retain reading insets and the centered column. [NativeReadingPageStack.swift](Conversation/NativeReadingPageStack.swift) owns retained page transitions, with host navigation described [here](../../Host/WindowNavigation/README.md).

[ThreadHistorySidebar.swift](Conversation/ThreadHistorySidebar.swift) presents the
conversation's turn index as a left-hand TOC. The selected mark is longer and
brighter; hover or explicit keyboard navigation reveals a bounded prompt/answer preview.
Restoring focus after Back does not reopen the preview. The mark and preview share
a cancellable 100ms pointer handoff, including the gap between them; leaving both,
unmounting or deactivating the scene retires pointer previews. The
viewport-bounded, independently scrollable index includes inherited history and
the current turn, without mounting historical bodies or parsing every answer.
The shared `NativeScrollView` retains native viewport behavior with hidden TOC
indicators. Up/Down and Home/End move focus; Return/Space activates the focused
entry. One stable keyboard
responder survives entry recycling, and Escape retains the document Back action.
Accessible names include the ordinal and prompt, and the selected/current states
are exposed separately.
Selecting history uses the existing scoped document without a dedicated upper-left
Back button. Escape and the history close action restore the retained current scroll
position for completed or non-Agent reading; returning to a running Agent
execution resumes at the latest content bottom. TOC selection remains available.
This shared behavior applies to Codex, Claude, Pi and OpenCode, including
unavailable history documents. Thread history
switches vertically according to TOC order:
earlier targets enter from above, later targets from below, including history-to-history
replacement and return to the current document. Both pages travel one viewport
height with the same curve, meeting edge to edge on one plane; this vertical
path has no dimming, blur, rounded page corners or shadow. The retained current
document keeps its enabled layout during travel and return preparation, so its
native scrollbar gutter cannot disappear and recenter the column. Only after it
is offscreen does its keyboard input gate disable it; hit testing and accessibility
remain gated throughout the history visit. History-to-history replacement never
reenables the hidden current document: its input gate distinguishes opening/return
from replacement even though both publish active motion. Opening and return progress
advances frame by frame instead of through an implicit animation, so cancellation
settles the pages immediately and a replacement begun afterwards starts from the
settled pose rather than a displaced one. Departing history stays mounted only
for its transition; cancellation fences obsolete completion. Other page
stacks retain their default horizontal direction. Reduce Motion settles transitions
without travel, including a return already in progress. New turns do not replace
an open historical execution;
removed destinations show the unavailable document and retain return navigation.
Execution sidecards keep their single-execution presentation. They omit the
decorative emoji and visible document title, use a compact 12pt timeline top inset,
and retain the resolved author, messages and execution actions. Full reading and
history pages retain their headings and standard insets.

The Sidecard-to-main handoff uses `NativeReadingPageTiming.replacementAnimation`.
`NativeReadingContentHandoff` scopes a readiness callback to the exact execution;
`ThreadConversation` forwards it only through that row. Mounted production content
and readable errors acknowledge readiness with `nativeReadingContentReady()`;
placeholders do not. The retained source covers data acquisition and decoder
loading at landing. This signal does not change reading destinations, scroll
following, data ownership or keyboard/accessibility focus.

A horizontal return requested during opening starts from the current AppKit
viewport geometry when matching native anchors are available. The anchors belong
to this stack's root and outer front viewport, outside the replaceable history
identity. They draw nothing, accept no input or accessibility focus, hold only
weak ownership links, and do not force layout or observe frames continuously.
The close action first cancels the old generation, validates the same identity,
direction, window and viewport extent, then synchronously installs the measured
progress without animation. The existing preparation, curve, duration and final
navigation callback remain in place. Detached, mismatched or invalid geometry
keeps the previous model-based fallback. Vertical/history replacement, cancellation
and settled-page returns do not use this correction. This boundary accounts for
a model value being ahead of committed native geometry; it does not treat AppKit
bounds as proof of WindowServer pixels or assert that such lag caused a specific
historical failure. Headless geometry tests cover both horizontal directions,
nonzero bounds origins, stale metadata, invalid extents and weak ownership;
the retained-Overview native replay keeps its original midpoint, 100ms return
direction, latest-content and parent-retention assertions. Before closing, that
replay synchronously requires the current two anchors to share one owner, produce
a valid sample and agree with the already-qualified front within the original
one-point tolerance. It records the native frames, progress and sampling times
without forcing layout; a model-fallback-only run cannot certify this path.

An external result request is the host route's entry document, so its Back and
Escape use that route's return action. It gains an internal history return only
after explicit TOC navigation. Each mounted row owns an independent content
handle, even when the retained current document and result render the same row;
closing one cannot revoke the other's content.

[ThreadReadingHeader.swift](Conversation/ThreadReadingHeader.swift) places the
mounted turn's resolved author under the title, beside the execution visibility
control. Agent detail has no user-message visibility toggle, including historical
and execution-card visits. Harness readers explicitly admit assistant replies and
execution records, plus errors (including error-level notices); general warnings
and input messages do not become work rows. Failed assistant messages and independent
error diagnostics stay visible when work is collapsed. Failed tools and reasoning
remain work, sharing visibility with successful execution records. Deferred reading
projections may retain failure payloads, but their presence does not authorize mounting
tool rows in Agent detail, even while work summaries are visible. Settled ordinary
assistant text stays readable while its execution is running/waiting. After
termination only the last non-error reply and an explicitly targeted message
remain ordinary content; intermediate replies join summary-only execution work.
Lightweight Pi/OpenCode turn projections retain interim replies for explicit
message visits without a detail lease. A targeted OpenCode child reply retains
all its text parts without exposing sibling replies or tools. OpenCode child sessions group their
execution rows into the same summaries and expose independent errors without
exposing sibling tools. An OpenCode assistant failure with no reply text
retains an independent failure-status message; a failed tool alone cannot create it.
The same policy applies to live, completed, loaded
historical and inherited content across the four Harnesses.
Empty filtered turns retain their execution status and result anchor; filtering
happens before grouping and rendering, so hidden events create no row gaps or scroll destinations. The
timeline's existing follow/pause, geometry-driven growth and jump-to-latest
behavior remains unchanged. Historical headings, previews and accessibility
labels use each row's execution title. The four Harnesses resolve it from the public `executionTitles`
map by exact execution identity. Missing historical names use the row's execution
timestamp; neither a raw prompt nor the current catalog title is substituted.
This also applies when main retains an older execution while the newest one
occupies a Sidecard. Thread title/emoji remain catalog metadata. Each Harness
entry sets `threadAgentDetail` from the public thread's Moku/current-history identity; Moku conversations keep their original
input visibility controls, prompts and notices. No stored history or other
surface is filtered.
Narrow widths wrap the control and truncate the visible
author while preserving its complete accessible label, tooltip and text selection.
For the selected running execution, work stays visible and its visibility control
is absent; completion restores the previous visibility behavior. Historical and
result visits compare their own execution identity with the running execution.
The author comes from the actual Harness-rendered body, including runtime model
overrides; manifests cannot invent it. Completion time, duration and usage remain
in the footer. Inherited transcripts containing several turns retain each turn's
author locally. The [sidebar replay](../../../../../tools/verification/reading-presentation/README.md#thread-history-sidebar)
covers mounted navigation, author updates, long indices and responsive layout.

Remote Markdown images use URLSession HTTP caching and revalidation, with no process-wide URL-only body cache. New document loads therefore honor `Cache-Control: no-store`; mounted images retain their current raster. The streamed 24 MiB body limit and decoded pixel limit remain enforced.

## Cards, composer and forms

Shared Harness card components keep task identity, usage, plan and extension layout consistent.
The identity title uses one measured line in every state, including while
running and before the first reply. Long titles truncate at the tail; the full
current title remains in help and the accessibility label. One line stays
reserved under vertical compression, with no second-line title space. A generated
title replacing a prompt cannot change the title seat's height. Card footprints,
body line limits and independent state/model/runtime rows retain their existing
contracts; the excerpt can use the height released by the former second line.
`HarnessThreadCard` and the Overview semantic boundary supply
`threadCardUsesFlatMaterials`: terminal badges and provider badges without an
emoji use static palette fills, and the in-progress plan row uses the accent-soft
surface without a glass container or effect. The 44pt emoji badge uses a static
opaque palette fill with no added border: adaptive accent-soft green when
completed, neutral surface-strong otherwise, including under Reduce Transparency.
It contains no Liquid Glass effect, avoiding per-card spatial glass updates when
panning Overview. Overview card shells remain neutral after completion. The emoji
stays 21pt, with the existing terminal mark preserving a non-color status cue.
The badge is status content, with an
accessible label and tooltip, and has no Send button, hover swap, focus stop or
message callback. Card activation stays with the surrounding host. Empty plans
render no section.
The shared controls keep their original materials outside a card; this internal
renderer policy is not a preference and does not identify plugins by name.
Completion drawing and plan geometry remain unchanged. Loading-cloud
palette is supplied by the Harness rather than selected by identity inside the renderer.

The Git extension renders signed numeric line counts only when both totals are
known. A single neutral label explains unknown, limit, timeout or unavailable
statistics; a separate stale label identifies retained observations. These states
retain the file count, branch and diff action without changing extension order.

For standard cards, equally ranked layouts favor Todo's upper row before the
structural-key tie break, independently of Git visibility. With Todo and Git
in the right column of a two-column card, newly appearing derived work or a
permission prompt takes the lower-left cell. Todo and Git retain their cells
through content updates and removal, without storing presentation history.
Size contracts and geometry ranking still take precedence; a tall question or
a one-column viewport can require a different footprint.

Ordinary threads proven by their Harness overview projection to have no inherited
history and at most one execution show a compact two-line initial-response body
until an eligible agent excerpt exists. Public execution facts take precedence
over pending input; absent execution facts remain neutral. Prompt/title/error
fallbacks remain available to search and later executions, but cannot become a
first-response body. Plans, tools and real interaction controls retain their
existing placement and eligibility. The local body suppresses the automatic top
status label without changing the global status contract or card structure key.

Only the submitting dot pulses (opacity only, 2.4 seconds per cycle); viewport,
window and host animation gates pause it. Reduce Motion disables this pulse and
the initial card's cloud animation driver, preserving the host's existing pause.
A mounted initial body gives way immediately to real content with a single 120ms
opacity entrance; remounts and later excerpt revisions keep the existing policy.
Run `python3 tools/verification/reading-presentation/run.py --initial-response`
for actual Go projections consumed by the native production card replay.

Composer state and submitted revision belong to the workspace. Attachment upload, file selection and send receipts are shared by the Dock and conversation surfaces. The Host’s `NativeMokuComposerInput` composes the shared text input, attachment chips and host file picker for both Dock and history; PluginUI owns those primitives and draft persistence. Harness and Moku interaction owners compose `InteractionQuestionField` with their own validation, submission and cancellation controls, sending through injected actions rather than bypassing Runtime admission.

Attachment paste shortcuts bind to the exact mounted native composer through a
shared editor identity. Common window ancestry and overlapping geometry cannot
authorize a retained/covered composer to paste into its draft. Provider decoding
and staging keep the draft captured at paste admission. See the
[attachment ownership investigation](../../../../../design/thread-attachment-ownership.md)
for the recording evidence and this sprint's static-only verification limits.

[Forms/PublicInteractionQuestionnaire.swift](Forms/PublicInteractionQuestionnaire.swift)
projects public form metadata consistently for the Dock and Reader fallback.
Visible defaults populate the editor; optional absence remains valid. Hidden
defaults participate in conditions without becoming steps, and inactive drafts
stay local. Core retains schema validation and native answer conversion.

Accepted sends consume persisted attachments by chip and staged-file identity even when a successor has advanced the draft revision. Text and directory consumption retain their revision guard. Live successor drafts lose only the accepted chips; pending imports, previews and newer input remain untouched. Repeated consumption is a no-op, and readding the same file with a new identity is independent of the old receipt.

Native text bindings compare UTF-16 code units so canonically equivalent Unicode replacements remain real draft edits.

`NativeComposerTextInput` optionally emphasizes its insertion mark through
[NativeComposerCaret](Composer/NativeComposerCaret.swift). Moku uses a
rounded caret, sized to 25/24 of the text size plus one point, with its center
one point below AppKit's actual `drawInsertionPoint` rectangle. The top edge
sits half a point lower and the lower end reaches the descender without moving
glyphs. View coordinates are converted through AppKit to the backing layer's
coordinates before placement, so a flipped or scaled text view does not
displace the mark. The opt-in presentation always uses a 2.6-point white core
with a warm-yellow upper halo and cool-blue lower halo. Moku is its production
caller and supplies a fixed dark surface; ordinary composers retain their native
caret and appearance. Empty emphasized inputs leave three points between the
insertion origin and placeholder text.
The halo preserves the approved study’s blurred 16-point warm and 14-point cool
ellipses plus a 4.6-point gradient fringe. Halo widths and blur radii scale from
the study’s 25-point core to the editor’s actual caret height. The transparent glow image is rendered
once per caret height/backing scale and its opacity is animated by Core Animation;
no per-frame SwiftUI rendering or timer is needed. Emphasized editors place their
existing padding inside the native text viewport, preserving glyph positions while
leaving room for the glow before native scroll clipping.
White ink breathes at 20–100% opacity, while both halos fade fully, independently
of the native editor's inherited system appearance.
Core Animation breathes over 2.4 seconds; native blink callbacks do not hide it
or restart the cycle. Same-line movement interpolates over 120ms from the current
presentation; repainting an unchanged rectangle does not restart movement.

Marked text uses the native caret, and line changes bypass interpolation. Selection,
loss of focus, hidden windows and detachment release the layer and its animations.
Reduce Motion keeps the mark steady and makes movement immediate.
Text, scroll clipping, selection and input-method ownership remain native.

Clipboard file/image paste reserves the draft synchronously before any item-provider decoding. The same draft-owned preparation lasts through attachment validation and staging, including oversized batches; Return and toolbar sends remain blocked until that operation resolves. Retired preparation cannot mutate a cleared or disposed draft. Clipboard TIFF preparation precedes attachment admission. Invalid TIFF does not
consume a slot or fall through to generic image-file import; accompanying text
remains available. Every published or persisted draft stays within the 20-file
limit, including while policy discovery, image preparation or staging is pending.
The draft and send button reject submission during the entire import. A successful
clear retires the import active when clearing began, including chips published
before the clear receipt arrives. Later imports and edits survive; obsolete
results are discarded without changing the new import's status or error.

Settings Harness editors share the native select, row/group, defaults toggle and
CLI status components. CLI status accepts an optional action in the shared notice
row so a Harness can expose refresh without building a separate status layout.
`nativeSettingsFormPage` scopes the system popup, rounded fields, switches,
popover help and bezel-bordered NSTextView presentation to Settings. Other
surfaces keep their existing control presentation. The adapters preserve field
activation, native composition/Undo and semantic interaction registrations;
Harnesses remain responsible for available options and dependent selections.

## Motion and materials

The timeline’s “Jump to latest” button uses the same native regular interactive
Liquid Glass as other floating actions, retaining its six-point rounded shape
and existing hit area. The package requires macOS 26, so no older-system fallback
is needed. SwiftUI owns light/dark appearance and accessibility material
adaptation; the button keeps its localized label, native button semantics and
`jumpLatest` reading action, with no change to following or scroll behavior.

[Thread-card numbers](Cards/ThreadCardMetrics.swift) retain positional cells from
right to left while usage changes. Changed digits enter from above and retire
below over 260ms, for both increasing and decreasing totals; clocks retain their
180ms opacity transition. Initial values mount settled, unchanged glyphs stay
still, and added/removed positions follow the formatted width (including compact
units). Retained positions change only glyph identity; card and usage-part
identity stay stable.
SwiftUI owns outgoing glyph lifetimes, including interrupted updates. The text
raster tier suppresses animation only when its scale changes; it must not clear
unrelated glyph-motion transactions. This number path retains the existing
always-animate policy even with system Reduce Motion enabled.

The native overview retains offscreen cards and the overview behind a reading
page. `ThreadCardAnimationVisibility` reports their actual viewport/page visibility
independently of the cloud-animation switch. A running duration suspends its
one-second task while that visibility is false or the scene is in the background;
on return it immediately samples wall time. Completed durations stay fixed.
Reduce Motion and disabled cloud effects do not stop a visible duration. Outside
the overview, omitting the visibility environment keeps the ordinary visible
behavior; an inactive but still visible window can continue showing elapsed time.
Derived-work scans, permission attention and running-tool spinners pause for
hidden/background cards, disabled host animations or Reduce Motion. Pausing does
not unmount the card or replace its controls, and restoring visibility resumes
the existing presentation.

Titles and excerpts use the same viewport/page and background visibility gate.
Hidden excerpts retain only their latest input and stop parsing, hold timers and
reveal masks; returning installs the latest preview directly, without replaying
hidden output. Their accessibility label still receives the latest authoritative,
bounded raw excerpt, including first content that replaces loading while hidden.
That semantic label does not report visual processing progress; the rendered
text remains frozen until return. Visible excerpts keep their 600-character
windows and 800ms hold policy. Their source buffer is not observed by SwiftUI:
only changed display or hold-schedule facts are published. A proven append beyond a full window reuses its
parsed preview; partial windows, rewrites, message replacement and transport-window
shifts keep the ordinary preview path. Each resumed buffer has a new session so
an obsolete reveal or hold cannot install a prior presentation.

The 280ms ink reveal uses the built-in offset effect to translate its two
gradient masks. The mask view itself does not interpolate progress, removing
that cause of per-frame body evaluation. Buffer advancement, reveal
ownership, disabled-animation resets and the 800ms hold remain leaf-owned.
Each new reveal key replaces only its two stateless visual layers, retiring
the previous offset animation's presentation before the incoming mask starts
at zero. The excerpt owner, buffer and tasks remain mounted; appends within
the same window and local width changes retain the current visual identity.

One title transition consumes the latest pending value at each completed beat;
new titles do not cancel its wait, so sustained updates cannot starve display.
Hiding, backgrounding or detaching cancels that owner and settles the latest title.
Cancelling an active transition replaces only its stateless animated text leaf,
so an in-flight fade-in is retired even when its model phase is already settled;
the transition owner and card keep their identity.
Reduce Motion makes both text effects immediate while visible excerpt windows
continue advancing. Disabling cloud effects does not freeze text content. The
mounted `SwiftUIOverviewInteractionTests` replay exercises retained visibility,
streaming windows, rapid title updates and cancellation without replacing cards.
The title cancellation method runs once in the mandatory
`reading-presentation/run.py --tag-glass-captures` native AppKit entry point;
the CI manifest assigns it there instead of ordinary Swift execution. It arms
the existing continuous WindowServer capture before a blank NBSP title changes
to visible text. Only a current partial incoming frame admits cancellation;
the first replacement frame and every later complete frame must match the
settled reference from that same stream. AX delivery and `cacheDisplay` are not
used to identify the moving frame. After the stream stops, PNGs and
frame/cancellation timestamps go to the launcher's
`MOKUSEI_READING_MOTION_ARTIFACTS/overview-text-motion` directory. The native
launcher exports it under
`.scratch/reading-presentation/NativeOverviewTagGlassTests/overview-text-motion`
for the hosted capture artifact; staged source paths do not determine that root.
The internal `threadCardTextReduceMotionOverride` environment entry lets these
native replays change the text policy locally. It is optional and defaults to
`nil`; titles and excerpts resolve it before the system accessibility value.
Ordinary application hosts leave it unset and continue following macOS Reduce
Motion. The override does not change clocks, other effects or system preferences.

There is no global Reduce Motion policy applied to every animation. The current [Moku Dock](../../Host/MokuScene/NativeMokuDock.swift) disables its surface/eye expansion animation when that preference is enabled; [Overview chrome](../../Host/Overview/NativeOverviewChrome.swift) separately handles tag/control transitions. Other animation paths follow their own implementation. Do not infer support or removal from an old blanket statement.

Window visibility, detachment, cancellation and explicit pause are separate lifecycle controls. Reduce Transparency fallbacks, contrast and accessibility labels are independently owned by the relevant views. [NativeCloudLoading.swift](Design/NativeCloudLoading.swift) and [NativeCloudField.swift](Design/NativeCloudField.swift) share the loading field and pause at zero visibility/intensity. [NativeVoiceCloud.swift](Design/NativeVoiceCloud.swift) consumes bounded voice visualization state without starting capture.

### Native Overview decorations

`threadCardNativeDecorationsEnabled` defaults to false; only the production
Overview card closure opts in. Its cloud uses
[NativeOverviewCloudView](Design/NativeOverviewCloudView.swift), a stable native
view with its own display link and transparent Metal layer, instead of a SwiftUI
timeline or nested hosting graph. The existing seeded, point-space
`NativeCloudField` and the shader's `cloudField` function serve both renderers.
Palette colors resolve from the current SwiftUI environment into premultiplied
linear components; the native drawable declares the same linear working space.

The native view retains its seed and epoch across running, palette and visibility
updates. It interpolates light intensity over 0.4 seconds, including reversals,
without publishing per-frame SwiftUI state; fading final layer opacity would not
preserve the field's additive energy. Geometry and semantic updates remain inputs
from the surrounding card. Inactive completed views do not request drawables;
bounded rendering work runs off the UI thread and removal retires its driver.
The existing shared SwiftUI renderer remains the capability fallback and the
renderer for other cloud consumers.

[NativeCardScan](Design/NativeCardScan.swift) moves the existing gradient through
Core Animation's 3.4-second linear cycle. Pausing retains its displayed position;
resuming aligns to the current wall-clock phase. It needs no application
per-frame callback. The existing scene, visibility and Reduce Motion gates stay
in the card, while native views exclude themselves from input and accessibility.

Acceptance compares the complete enabled Overview scene on a fixed target Mac.
The native path's submit counts and scan presentation positions replace the old
Timeline counters; neither establishes display FPS. Native WindowServer frames
must cover cloud color, static card surfaces, rounded clipping, camera transforms, exit
opacity and interrupted intensity fades. AppKit self-rendering and model values
alone cannot certify that composition. The native path is a performance
candidate until that evidence and a repeatable process-CPU benefit are recorded.

Fonts, icon licenses and attribution live under [Resources](Resources/). Metal assets are compiled through the package's build plugin. Tests under `app/macos/Tests` and [functional replays](../../../../../tools/verification/README.md) exercise native components; macOS window tests require an actual graphical session.

## Semantic Settings controls

[Forms/NativeSettingsInteractions.swift](Forms/NativeSettingsInteractions.swift)
provides a mounted-control registry, environment scope and owner leases. Explicit
field IDs opt controls into code-driven interaction. Selects and toggles call the
same bindings/change context as the UI; native textareas use NSTextInputClient and
existing delegates. A render refresh invalidates old handles after each action;
disabled and detached controls reject commands. The registry owns no settings
JSON mutation or persistence. Secret inputs remain outside this surface.

[Forms/NativeSettingsTextEditing.swift](Forms/NativeSettingsTextEditing.swift)
owns per-page text-composition tracking independently of automation. Shared and
Host textareas report their real NSTextInputClient lifecycle before editing
callbacks; single-line fields use notifications scoped to the page's window.
Each editor owns its composition entry, so ending or detaching one editor cannot
release another editor's save/close protection.

## Semantic reading controls

[Conversation/NativeReadingInteractions.swift](Conversation/NativeReadingInteractions.swift)
registers controls from the mounted conversation, with window-visit and owner
leases. Current and historical documents have separate scopes; hidden retained
pages remove their registrations. Actions invoke the original history, visibility,
load-earlier, jump-latest and disclosure callbacks. Timeline scroll commands use
its actual `ScrollPosition`, so normal geometry and navigation-chrome updates
remain the observation source. IDs encode opaque row identities, while handles
also fence descriptor changes and the next SwiftUI render after an operation.

Reading snapshots report the selected history destination, visible row window,
scroll geometry and disclosure values. Codex lazy rows and shared deferred
execution groups expose their actual resource loading/error/ready state; mounted
turns expose the rendered row count. The registry never writes Harness state or
submits work. It does not claim composer, sidecard, Git reader, link or media
coverage. [The reading runner](../../../../../tools/native-interaction/README.md)
uses these observations for production-app chaos and replay.

Timeline offsets normalize `contentOffset.y` by `contentInsets.top` before
feeding `ScrollPosition`, retained history positions or relative scroll commands.
Snapshots keep the raw offset and inset alongside the normalized position so
replays can detect coordinate drift instead of accepting a finite but wrong value.

Execution-result visits use the existing nested reader for current as well as
historical executions, so streaming, completion and a successor never replace
the referenced execution. Each Harness's typed detail rows supply visible
content/process semantics and mark final reply rows separately from reviews or
status messages. Once a body is loaded, its final reply (from its first text part,
or latest visible row/status when absent) mounts the result anchor; manifests do not claim
a content location. Running result visits enable the existing output following.
Upward user scrolling stops it immediately, and Jump to latest restores it.
Conversation timelines allow Jump to latest only while their execution is running
(including waiting for user input). Completed executions hide the button and its
reading action immediately, even when the scroll position has not changed or a
successor is running. This eligibility is separate from output following so final
content layout and result-anchor positioning keep their existing behavior.
Internal execution URLs are admitted by the shared Markdown parser but dispatched
only through an explicitly supplied typed execution callback, currently the Moku
note. They never fall through to external navigation.

Timeline anchors retain document coordinates through nested rows. If a requested
position is initially clamped because Markdown has not finished layout, content
growth retries that location until it is reachable or the user scrolls.

## Model and reasoning selection

[NativeModelSelector](Forms/NativeModelSelector.swift) uses the shared system
`NSPopUpButton` for models and reasoning in Settings (`nativeSettingsFormPage`)
and onboarding/role panels (`nativeSettingsCompactPresentation`). Default and
reset values remain explicit menu options; no slider or nested model menu is
mounted in those forms. AppKit owns menu rendering, focus, keyboard navigation,
cancellation and accessibility. The shared adapter preserves opaque option IDs,
disabled rows, row-label activation and discrete-change interaction registration.
`NativeSettingsControlsReplayTests` mounts the production standard/model/reasoning
selects in both environments and checks real AppKit actions and bindings.

Embedded Thread editors retain the capsule and popover for Harness model choices.
The model list scrolls, marks the current choice, preserves disabled rows and supports arrows, Home/End, Page Up/Down,
type-ahead, Enter, Escape and Tab. The reasoning presentation shows a discrete
purple slider in the Harness's supplied option order. A single choice remains a
button; an unselected/default value does not paint a falsely selected slider knob.
An enabled empty-ID option supplies the reset action; the component never invents
a model default. An optional `ModelLink` opens the model list in the same popover.

Callers retain exact `JSONText` IDs, capability discovery, custom identifiers,
model-dependent draft updates, default mapping and persistence. Codex, Claude,
Pi's catalog-backed forms and OpenCode use this control; Pi's free-text native
configuration stays editable, and OpenCode variants use the list presentation
because variant names do not imply an intensity order. Other form controls are
independent. Existing Settings interaction IDs and discrete-change admission are
preserved. AppKit owns popover dismissal, native slider actions and accessibility;
capability changes, detachment and parent scrolling retire open popovers.
The anchor and content implement `NativeSettingsEscapeCancelling` so a document-level
Escape monitor can follow the responder chain and cancel the popover before
leaving the page, even when AppKit
addresses the key event to the anchor window.

Current Settings pages and compact configuration use `NativeSettingsSelect`.
The direct embedded-popover/slider fixtures were removed because they exercised
the former selector presentation rather than those production entry points.
Settings control, Harness-form and full-page Settings replays retain coverage of
current selection values, admission and persistence. The embedded component's
code is not changed by this test cleanup.

## Compact configuration presentation

`nativeSettingsCompactPresentation` selects the presentation shared by onboarding
and Settings role panels for existing groups
and background-role configuration. `NativeSettingsReadiness` reports optional
readiness leases from mounted editors: no reporter is unknown; all reporters
must be ready. Each step owns its registry and unmounting removes the editor lease. Harness plugins report incomplete local model-dependent input, while the
Host separately reports resource availability. The parent consumes the current
step's readiness leases and rejects callbacks from departing pages. Settings and
onboarding share native field bindings, catalogs and persistence.

## Reading-panel presentation

The shared reading stack can present Agent, Report, Git and Moku history routes
as a bounded panel, using a source card frame where available. It retains the same route identity, explicit progress clock,
close/cancel lifecycle and reduced-motion settling as page navigation. Panel
content remains reader-owned; Agent title/emoji can use the window-local identity
bridge described below while its outer frame expands. The final aperture admits the host's independent toolbar
outside the panel. The front layout includes a 76pt trailing toolbar seat so
native pointer input reaches those buttons; their labels expose a complete
42pt circular hit region. Other application pages and vertical history transitions
keep their existing presentation. `NativeReadingPanelGeometry` is the shared
viewport/margin contract for production and the standalone native fixture.

`nativeReadingPanelViewport()` reserves an inner frame of 8pt horizontally,
48pt above and 22pt below by default for Git, Moku history and execution-card
reading panels. Report panels opt into
`topInset: 8, balancedVerticalInsets: true`, reserving 8pt at both ends. The main Agent Thread
panel uses `topInset: 22`, matching its bottom viewport clearance. Its reserved
48pt leading history rail separates the document and its scroller horizontally
from Close; the rail itself retains 64pt of vertical padding. `ThreadConversation`
consumes that rail reservation before rendering nested rows. Top-level loading
and Harness error views use `nativeThreadRailFallback()`
to reserve the same 48pt when no conversation layout is present; nested status
views do not add it again. This also keeps heading-only loading aligned with
the preparation reader without changing viewport height during admission.
Current and historical Agent documents use 12pt of scrollable padding at each end, without
additional vertical padding around the conversation viewport. This keeps the
Close clearance while expanding the readable area at every window width;
timeline page capacity uses the same document padding. The sibling Moku input
keeps its existing host layout. The entire viewport
sits inside this frame, so persistent and
overlay indicators, their hit regions and both scroll limits clear the rounded
edge. The default top clears Close's complete 14pt inset + 32pt hit region,
including when an overlay scroller expands on hover. The main Agent reader's
horizontal clearance supplies that separation with the smaller top inset.
Close remains anchored to the outer
panel. The frame reduces available
content width by only 16pt; native gutter ownership remains as described above.
Report uses its compact host inset without rewriting document layout, overflow or
external webpage/frame styles. Panel chrome uses the application canvas color;
an authored Report background remains inside its viewport.
The inset belongs to the reading card: Moku history's separate input capsule
keeps its own layout and dark appearance. Nonpanel application pages and Browser
Sidecards keep their existing frames; no DOM style or scroll-offset translation
is added. Readers derive their available width/height from the inset viewport.

### Thread document spacing

`HarnessMessageTimeline` uses one vertical document inset for both ends, including
history/unavailable pages and execution presentations. The inset selection uses
explicit `contentTopInset` (12pt for Agent detail and execution), otherwise
94pt under reading navigation, or 24/28/44pt for widths >=1024 / <=540 / between.
Despite its name, the explicit top override now applies to both document edges.
The streaming Markdown page capacity subtracts this inset twice from the current
viewport height; resize, sidebar changes and content growth use the same layout
proposal rather than a cached height.

Measure spacing from the **layout bounds**, not emoji/font ink: at scroll start,
from the viewport top to the first document element (normally the heading emoji);
at scroll end, from the final element (including completion/status/usage) to the
viewport bottom. Zero-height scroll anchors add no trailing pixel. The final
turn row has no trailing inter-row gap, including while active; footer separation
belongs inside the document. The cat empty state's own vertical inset is 48pt
on both sides. Other supplied empty/error/loading views keep their own content
layout and receive the same outer document inset.

The main Agent panel has fixed viewport chrome of 22pt above and below, with
no additional page-stack inset around its main conversation. Together with the
12pt document inset, this gives 34pt from either outer panel edge to the
corresponding document boundary at its scroll limit. The previous 48/22pt shell
left 26pt of extra space above the viewport even after `9b835d0` made document
padding symmetric. Title/emoji and author spacing belong inside the document;
they are not the source of this fixed viewport imbalance. Close stays at its
14pt panel inset, separate from the document's reserved leading rail throughout
scrolling, history navigation, resizing and Sidecard layout changes.
Short documents remain top aligned;
unused viewport height below them is not padding and is not forcibly filled or
centered. At an explicit result/message visit the targeted scroll position can
start mid-document; these distances describe the document's two scroll limits.

This spacing change leaves placeholder delay, content acquisition and cache
ownership unchanged. The upper-left reading close button retains its fixed
panel position. The lightweight opening heading and live reader share the main
Agent's 22/22pt viewport, preserving measured title/emoji handoff geometry.
Content-reveal readiness, Moku input/Sidecard admission and their existing
three-stage timing remain unchanged. Report uses the balanced viewport argument
with an 8pt top inset; execution-card viewports use the default 48/22pt chrome.
The execution card's separate page-stack spacing is unchanged.
Git/Moku viewport defaults are unchanged.

Sprint verification for this viewport adjustment is source/layout review,
application product build, lint and documentation/diff checks. No tests or
replays are created or run, and no CI, push or PR is triggered. The supplied
screenshot was inspected; the changed layout has not been viewed in a running
application, so rendered geometry and interaction/animation behavior are not
claimed as observed acceptance.

Report balances the **card-to-WebKit viewport** distance at 8pt on each end,
including both document scroll limits. Its webpage background begins and ends
at these viewport boundaries, and WebKit's scrollbar stays inside that viewport;
no overlay masks or indicator-hiding rules are added. Short reports retain
WebKit's normal document/viewport sizing. Window resize and theme changes do not
introduce another inset. The webpage's own padding, the existing HTML safe-area
contract (including the 60pt panel top clearance), CSS, zoom and authored
backgrounds remain independent and unchanged: the first and last text glyphs
need not be equidistant from the card edge. Close overlays the upper-left
document with an opaque canvas backing; its
32pt circular hit region and 14pt placement remain unchanged. Only that target
intercepts document input; the backing adds no hit area. The existing panel
clip and inset contain the viewport at its rounded edges without adding a mask
over the document or its scrollbar. This reduces the dark shell padding shown
in the supplied screenshot without rewriting its report.

Sprint verification for this Report adjustment is limited to Swift parsing,
source/layout review and documentation/diff checks. No tests, replays, product
build or rendered interaction checks are run; no CI, push or PR is triggered.

Hosts interrupting motion for recovery can request `cancelAll(finishingClose: true)`
to complete an accepted return for its current visit. Default cancellation still
preserves the page, and recovery never revives a previously cancelled return.

`nativeReadingEscape` shares the conversation reader’s native viewport-scoped
Escape owner with Git panels. It rejects events owned by editing/IME, menus or
sibling surfaces. HTML panels keep their isolated trusted DOM key boundary.

The shared stack's optional `onPanelOutsideClick` installs a separate native
backdrop beneath the front controls, outside the panel rectangle. It consumes a
completed blank-margin click without forwarding it to Overview; panel whitespace
and Sidecard dividers are excluded. Motion and covering interactions disable the
callback. Hosts supply the existing route Close action, preserving application
return ownership. Native sheets/popovers keep priority over backdrop dismissal.
Panel chrome can use `nativeReadingEscape` alongside HTML: the native fallback
leaves a WebKit responder to its trusted DOM handler and respects inherited
disabled state, native sheets and visible child windows.

Thread opening starts data-only prefetch outside the deferred front. Ordinary
Agent card entries then preload the primary reader after native animation-start
delivery, while drawing and secondary admission wait for arrival. Codex reuses
successfully admitted immutable state by complete opaque input, with a bounded
actor cache; new input cannot select an older revision. Read-only Markdown
TextKit views disable Writing Tools while retaining native selection, copy and
links. No reader/view or scroll state is cached. See the
[loading investigation](../../../../../design/thread-loading-performance-cache.md)
for paired observations, variability and manual coverage limits.


### Agent Thread admission and motion

Agent Overview cards register window-local title/emoji anchors through
`NativeThreadIdentityRegistry`. An ordinary card-open copies their text and
geometry into one route visit. Before travel, the workspace prepares its sidecard
geometry and a row-free `ThreadConversation` using the same heading layout.
The main Agent reader reserves its 48pt history rail across loading. Its bounded
reading column remains centered in the available reading viewport, with the
existing responsive insets. A real sidecard open/close resizes that viewport and
recenters the entire column normally; it does not start another identity flight.
Do not lock the reading origin to the panel's left edge to prevent this reflow:
that breaks wide-window composition. Loading and loaded headings use the same
layout at a given viewport size.
The primary Harness reader may preload after native travel begins; sidecard
bodies remain deferred until arrival. The compositor animates
native title/emoji ink to that measured destination with the panel's own curve
and duration. The flight rasterizes the same SwiftUI heading leaves at their
measured destination size and in the reader's environment. This preserves native
font fallback, glyph baselines, tracking and two-line truncation at handoff;
matching layout anchors alone does not align `CATextLayer` ink with SwiftUI `Text`.
Opening waits for both native heading anchors, coalesces their publication, then
resolves the current native layout before freezing their actual geometry; it does
not use a trailing 48ms debounce. The panel's real completion and visible host,
not an independent duration timer, admit the title handoff. Loaded content only takes ownership at that position; there is no
post-opening title animation or data-loading timeout. The bridge never retains
card/reader/plugin instances; replacement, close and reduced motion retire its layers. Direct result
navigation and entries without a visible source card retain their ordinary entry.
See the [recording analysis and sprint verification limits](../../../../../design/emoji-title-transition-handoff.md).

Agent closing keeps the 420ms native panel return. The complete reader fades
over the first 80%; scaling and shell travel reach the source card at 86%.
The shell stays opaque until arrival, then crossfades to the refreshed Overview
through the final 14%. This final handoff owns transition completion so the
carrier cannot disappear before reaching the card. Closing has no independent title/emoji travel. Report, Git and nested
history keep their existing motion policies. The panel Close appears only after
reader admission and fades before return; its position and hit region remain
owned by the production upper-left control.

The main Agent workspace opts into `nativeThreadContentReveal`. Scoped loading
uses the shared `NativeThreadLoadingSkeleton` after the existing 180ms grace
period. Real Markdown parse completion (independent of optional document tokens)
and native text attachment admit the first execution entrance. TextKit drawing
is gated before first paint, then line masks and visibility commit together.
Completed executions reveal top-down; active executions reveal bottom-up after
normal follow positioning. The completion footer joins the same native mask
ordering as the last row, starting one beat after the preceding line rather
than waiting for its fade to end.
Execution-process summaries join this same ordering as whole rows, including
their icon and wrapped text. Their SwiftUI layout and accessibility stay intact;
an inner native host gates first paint until the shared mask is installed.
Summary count/usage changes or width changes release the entrance masks, while
summaries admitted after the entrance appear immediately without restarting it.
When a completed execution moves from its retained sidecard into the main
reader, the destination skips this entrance: the handoff already presents the
content and must not expose a second blank/reveal cycle. Content readiness still
acknowledges the destination before the retained sidecard fades away.

Each mounted execution owns weak text/summary registrations, masks and cancellation;
there is no window-wide text scan. Live text changes, actual width changes,
Reduce Motion and disappearance retire masks and restore drawing. Streaming
page admission and user scroll ownership remain unchanged. The entrance is
sped up by a factor of 1.32 (a further 20% over 1.1): the original 45ms line
beat, 600ms stagger cap and 280ms line/footer fade are each divided by 1.32
(approximately 34.1ms, 454.5ms and 212.1ms for either fade). Line ordering,
ease-out curves and completion-driven entrance admission stay unchanged, as do
Markdown/layout readiness waits, loading skeletons and panel/identity motion.
Later disclosures and stream updates do not restart an execution entrance. Other Markdown consumers
leave the presentation scope disabled.

Run the [production fixture](../../../../../demos/thread-panel-transition/README.md)
with `--production --verify`; it uses these production components with deterministic
loaded/running data and checks source capture, measured handoff, first-paint
protection, line direction, footer and mask cleanup, normal close and interrupted
opening. Full-workspace navigation remains covered by the existing native reading
and Moku landing integration replays.

Initial conversation admission uses an inline loading placeholder until its entry
request is consumed. It must not use the surface placeholder: with an identity
visit, that placeholder builds `NativeThreadOpeningContent`, itself a conversation,
causing recursive mounting before the initial `onChange` can run. The outer
surface retains title/emoji loading presentation; the internal admission gate
remains a leaf. The production thread-panel fixture above exercises this path.

Panel diagnostics use existing `reading.prepare` and `reading.transition` spans
with `panel: 1` and `closing: 0/1`. Preparation covers native configuration through
animation installation; transition covers installation through delegate completion.
`reading.prepare` events with `anchorsReady: 1` and `layoutReady: 1` separate
anchor publication from native layout resolution and subsequent ink construction.
A `reading.transition` event with `started: 1` marks the native start callback.
These are process observations, not display-frame timestamps.

### Width-driven Markdown layout

`NativeMarkdownColumn` measures document/list blocks at the supplied reading
width with unconstrained height. It retains at most four width proposals in
SwiftUI's layout cache, clearing them when the layout/subviews change; measurement
and placement share those results. List markers, quote rules and footnote numbers
use a fixed leading slot, so horizontal flexibility negotiation no longer probes
their paragraph at one-point width. SwiftUI owns right-to-left mirroring.

Once admitted, all blocks and native text views remain mounted. Whole-document selection/copy,
footnote navigation, media loading and scroll ownership retain their existing
lifetimes. The native Markdown replay includes actual text growth/shrink and
window resize, both writing directions, table copy/geometry and footnote return;
the local-image and execution-link replays cover asynchronous media and streaming
admission. This optimization does not use viewport virtualization or stale
cross-document height caches.

### Paced initial Agent text

An Agent execution's first non-streamed Markdown document admits small batches
of top-level blocks between main-loop turns, budgeted by estimated native text
leaves. Tables and lists remain atomic. The document-ready/coverage acknowledgement
is published only after all blocks have been admitted; the existing reveal scope
protects first paint. A newer revision interrupts the old batches, including an
empty replacement, and disappearance cancels the worker. Already displayed content
and streaming pages retain their ordinary update path. Animation durations are
unchanged. Reveal registration dictionaries, masks and tasks are imperative
bookkeeping outside SwiftUI observation; visible completion remains observable.

There is no additional cross-visit attributed-string or native-view cache.
Existing immutable parse/content caches and layout-local measurements retain their
own lifetimes; every reader owns fresh native text, callbacks and selection.

Report uses `NativeReadingAuxiliaryBackKey` to offer its selected execution's
Back action to the outer reading workspace. The preference carries a stable
identity and a main-actor callback; equality ignores closure allocation so
ordinary redraws cannot republish a fresh navigation action. Removing selection
removes the preference. The Host keeps Close and browser-first cancellation.
