# Shared native UI

This target supplies design resources, Harness cards, Markdown reading, conversation layout, composer and forms to the macOS application. AppKit adapts native text, input and viewport behavior within the Swift package.

`NativeGeometry.overviewCard` defines the 320×196pt logical 1×1 cell shared by
Harness card ideal sizes and the Host Overview grid. Larger footprints add cells
with the 16pt gap;
typography, icons and corner radii retain their own metrics.

The timeline's floating Jump to latest control uses a 42pt circular interactive
regular glass target, matching the Sidecard launcher. Its bottom inset, navigation
action and localized accessibility label remain owned by the timeline.

Reading author labels use the validated owning Harness's native logo and name
from the host environment, independently of the recorded model and effort.
Without that identity they retain the text-only fallback. The shared label is
used in reading headers and turn footers, and exposes the Harness name to
accessibility while keeping the logo decorative.

During vertical history entry and return, the retained current document resolves
its title, author and running-work presentation from its own document row.
The TOC selection belongs to navigation/input routing; it cannot retarget that
document's header while its body is still visible. Each history document keeps
its own exact-execution heading and mounted-turn author preference. Pending
history content retains its normal loading state without borrowing another
execution's author. See the [reading contract](../../../../../design/reading.md).

`nativeRegularCardGlass` supplies native regular glass with a system Material
fallback and an opaque palette fill under Reduce Transparency. Super Thread
collections opt into it for their full backdrop and emoji badge; the badge keeps
the shared 44pt diameter and top 12 / trailing 17 seat. Other card badges retain
their flat-material policy. Apply the backdrop separately from ink masks so a
page reveal does not cut the collection's continuous material surface.

`nativeCollectionPanelHost` gives a canvas collection a workspace-sized reading
surface without creating a route or a native child window. Its environment
presentation owns one UUID-scoped visit, uses native source/viewport anchors to
convert camera geometry, and delegates travel, resize settling,
blank-margin dismissal and Escape arbitration to the existing reading stack.
Explicit Close refreshes the carousel source frame. The grid is the retained parent of a
member reader. Its activated card supplies the source and return frame for the
workspace’s shared Report transition. Back reveals the same grid and resumes
its controls. Report panel travel settles directly under Reduce Motion.
Callers refresh the
contents when member facts change and retain their own selection, playback and
data lifetimes.
The collection parent remains mounted for those updates while drawing, input and
accessibility are suppressed. The shared compositor's auxiliary lane stays
outside the collection's Liquid Glass panel. Close floats over the panel and
stays fixed while the member grid scrolls. The collection hosts its SwiftUI
content in window points and applies workspace zoom inside that host so input
and accessibility frames follow the displayed controls.
Blank-margin dismissal ignores nonfocusable system child accessories such as the
window-sharing indicator. Visible focusable child windows, sheets, modal windows
and the press forwarded while closing an NSPopover still block dismissal.

Settings role editors can opt into `NativeSettingsEditorDrafts` and
`NativeSettingsEditorState` to retain incomplete plugin input across unmounts.
Storage is local to the Settings visit and interaction scope; complete values still
leave the plugin through its typed change callback. Entries can report incomplete
choices to the Host's close gate. Without that environment, the wrapper retains
ordinary view-local state, preserving other settings and onboarding behavior.

Moku's eye character is drawn by the Host's vector renderer. The sphere-specific
Moku Map uses no sphere PNG loader or Harness gradient palette;
application icon resources remain independent.

Adaptive color assets in `Resources/Palette.xcassets` match the normalized
production `pair(light, dark)` requests. `CloudMetalCompiler` checks literal
requests before compiling the palette with actool; `NativePalette.pair` is the
asset-name constructor. Direct native RGB colors do not require palette assets.

`NativeReportExecutionInputKey` carries the expanded Report execution's exact
reference, content/landing readiness and destination frame to its Host shell. It is absent in list, folded,
Browser and suppressed states. The Host converts that geometry through the same
passive native marker as Agent Sidecards and owns the composer and send routing.

`ThreadConversationInputTargetKey` publishes the main reader's actual selection,
entry request and motion readiness. Ordinary current documents follow latest;
explicit TOC/history/result visits retain their exact execution, including an
entry temporarily excluded into the active Sidecard. Row-only renders and
execution Sidecards do not publish another input owner. Unavailable or aggregate
history without an execution identity cannot silently become current input.

The resident Dock and Moku history capture the submitted draft and its route
together. The shared draft persists each pending send under its initial
command ID. Settlement writes the editable successor and its cleanup marker
before the Host acknowledges the retained receipt. A reopened owner can
retry that acknowledgement without sending the successor. The optional
`didConsume` observer reports completed consumption to callers such as the
receipt replay.

`NativeComposerTextInput` keeps an unconsumed focus request pending while the
editor is unavailable or focus is suspended. Eligibility changes retry that
intent once; already consumed requests do not reacquire focus on passive
availability changes. Hosts can turn off automatic initial focus and supply
explicit requests independently of native click/Tab eligibility. See the
[execution focus contract](../../../../../design/composer.md).

The shared `NativePalette.thread` dark reading surfaces use a charcoal canvas,
progressively lighter content/interaction/composer fills and warm off-white text.
SwiftUI, TextKit and the panel transition resolve the same adaptive assets;
other readers consuming this palette share its dark tones. Light variants and
Overview/Settings palette definitions retain their existing values. Claude's
Overview workflow cards and Thread settings hints also consume thread surface
and muted colors, so those shared consumers use the same dark values. See the
[shared reading palette](../../../../../design/reading.md).

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

Thread, Report and Moku history panels share
[`NativeReadingPanelCloseButton`](Conversation/NativeReadingPanelCloseButton.swift).
`nativeReadingPanelClose` places the 32pt circular target 14pt from the panel's
top-left edge. Pair it with `nativeReadingPanelViewport`: its default 48pt top
clearance keeps both scrolling content and native scrollers below Close. The
main Agent reader instead clears Close horizontally with its reserved history
rail, allowing 22pt viewport insets at both ends. Report uses 8pt insets on all
sides and `overlaysContent: true` for an opaque canvas backing under Close.
The Report host clips the viewport with a 14pt radius before applying its 8pt
insets, matching the outer panel's 22pt radius. Spacing outside the circle
is not a close target. The button uses the same native interactive regular
Liquid Glass as the Sidecard launchers, directly on the package's macOS 26 minimum;
no older-system material fallback is needed. It retains reading-palette icon and
pressed tint colors, disabled and increased-contrast states, with a visible keyboard
focus ring and caller-owned localized help/accessibility labels. Close uses
activation-only focus: pointer clicks do not acquire focus or flash the ring,
while system Keyboard Navigation retains focus indication and Space/Return
activation. Callers keep
their own close callback and Escape/navigation ownership; the button installs
no global keyboard shortcut. Agent Sidecards use the corresponding right-side
launcher as their open/close toggle and have no independent Close icon. Browser retains their activity toolbars and media/document actions.

`NativeReadingPageStack` optionally reports whether its retained parent is
participating in presentation and awaits host preparation before a settled-page
return. Opening/reversal remains immediate. Preparation shares the stack's route
generation and cancellation ownership; a late completion cannot close a replacement. Hosts without these hooks retain the same navigation behavior. Overview uses them
to coalesce hidden display work while retaining native controls and authoritative
state reception. Its opt-in `isolatesParent` surface keeps that state in a
separate native host. Once a panel settles and its live heading owns the identity
ink, it hides the live host without capturing a bitmap. The parent fades fully
out during panel travel, exposing the window's existing ultra-thin material;
no Overview cards remain behind a settled reading panel. Resizing leaves the
hidden card tree's viewport unchanged. Return preparation unhides the same host,
applies the latest environment and viewport, and waits for the existing canvas
receipt before sampling the destination. Return travel fades the refreshed cards
back in. No snapshot allocation or CPU rasterization blocks reader admission. Freezing closes native hit testing, accessibility and viewport updates immediately;
the already-transparent parent's native hide is coalesced onto the next main-queue
turn. Hiding a focused host inside `updateNSView` makes AppKit traverse key views
and re-enter the SwiftUI geometry graph still being updated. Returning or retiring
the host invalidates that pending hide. Nested reading stacks keep their existing parent presentation. The retained native host consumes the viewport already assigned by the workspace
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
replacement route. Resize, cancellation and inactive scenes
settle through the reading stack's existing ownership. Vertical history keeps
its identity animation and completion timer; non-panel navigation samples its
shared progress on display callbacks. Returning refreshes the retained Overview
before starting a settled panel's close.

The stack publishes `nativeReadingEntranceReady` from that actual completion
boundary and, when present, the existing title/emoji ink handoff. An execution
selected during preparation reserves its column in the main document. The
full-width shell and folded aperture commit before auxiliary motion begins.
`NativeReadingEntranceStage` invalidates its queued callback on disable,
detach or replacement. Agent detail
also waits for `NativeReadingContentStatusKey`: only the active main document
contributes readiness, and pending Markdown parsing or loading placeholders
keep the gate closed. Loaded empty/error states can finish without Markdown.
Agent loading placeholders keep the gate pending even alongside loaded sibling
rows and during their visual grace period. The identity-only reader cannot
admit content. Agent main readers fade only their first readable timeline body in with the
same 200ms ease-out opacity timing as Report referenced readers. Admission
waits for arrival and content readiness for both running and completed executions;
loading remains visible while data prepares. Readiness is latched once per
reader visit, so streaming, retries and history changes do not replay the fade.
The timeline toolbar (including title, emoji and header controls), history rail
and scroll container stay visible; the title/emoji handoff never fades again.
The transparent preparation frame excludes hit testing and accessibility.
The fade changes only opacity and preserves layout and scroll ownership. Inactive scenes settle the fade
immediately while preserving readiness rules. See the
[reading choreography](../../../../../design/reading.md)
for lifecycle and readiness details.

`ThreadDeferredExecutionContent` keeps the same mounted row when an active
response becomes a completed `deferred-execution` envelope. Only its content,
presence facts and execution-detail loader change; the reader's decode state,
Markdown tree and native text selection survive settlement. Deferred groups
still own separate detail leases, and malformed envelopes remain rejected.
The [Markdown ownership contract](../../../../../design/markdown.md) describes
the stable render site. No settlement correctness replay is configured here.

Codex reading validates and decodes each changed opaque state on its background
actor before publishing its immutable typed result. Superseded and unmounted
requests cancel delivery. Collapsed execution work also skips native row
construction; errors, final replies, disclosure and canonical content keep their
existing policies.

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
See the [recording review and validation limits](../../../../../design/reading.md).

The Agent reader hides its work visibility control when the mounted execution
content reports no displayable work. Missing reports during scoped loading remain
unknown, and later content updates can restore the control. Summary admission
and background terminal/task presence determine availability independently of the
current work toggle; other conversation readers retain their controls.

Agent execution summaries suppress a group only when every member explicitly
reports no summary content and no positive reasoning usage is reported for that
group. Empty reasoning and completed Hooks without output qualify; tool calls,
other activity kinds, running/failed/cancelled Hooks, interactions and unknown
rows remain admitted. Classification follows content and native identity rather
than position or zero counts. Lightweight Codex/Claude history carries output
presence independently of stripped detail. Full/Moku readers retain the original
disclosures and detail loading. See the [contract](../../../../../design/reading.md)
for the current execution-summary admission rules.

Execution summaries label execution-scoped reported reasoning usage as “总共思考
N tokens” (“N reasoning tokens in total”). Running executions show only usage
already reported by model calls, not an estimate of the unfinished call. Each
provider owns accumulation: Codex persists finalized counts keyed by response
ID from execution admission onward (never sums `tokenUsage.last` or session-wide
`tokenUsage.total` snapshots); Pi uses its existing `executionUsage` aggregate,
including lightweight history; Claude uses its per-message replacement-map
aggregate; OpenCode sums its current per-message usage and separate compaction
usage once, including compact projections. Codex, Pi and Claude suppress the count when a reported usage sample lacks
reasoning. OpenCode admits native usage only with an explicit reasoning metric;
its Go wire format omits a known zero (`omitempty`), so absence within an admitted
usage object means zero, while absence of the usage object remains unknown. Empty Codex
sample maps and executions without a trustworthy cumulative source also omit
it; historical/pre-change Codex last-call usage is not relabeled or reconstructed.
Counts survive persisted history/fork projections when the cumulative data is
present. An explicitly reported zero remains zero.

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
is involved. Light/dark, Increase Contrast and Reduce Transparency
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

No native scrollbar correctness suite or windowless styling replay is
configured in this source tree. The resident AppKit gutter and SwiftUI-owned
indicator/width policies above are implemented boundaries, not passing GUI
evidence. Content readiness requires actual native document/viewport geometry.



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
| Shared conversation / execution Sidecard | Timeline, activities, Markdown code and tables | SwiftUI wrapper; the timeline owns scroll position, follow behavior and cursor deferral |
| Shared composer | Native multiline editor, attachment strip, host file picker | AppKit subclass and control-scoped List adapter; attachment indicators remain hidden |
| Settings and shared selects | Main form, section strip, agent/error detail, native textareas, option and model menus | Wrapper/subclass only; bindings, validation and menu focus unchanged |
| Moku | Note (including short viewport), directory completion, Talk and interaction bodies | Wrapper; completion uses native drag/accessibility instead of its old custom thumb |
| Overview | Tag/filter navigation strips | Wrapper; existing hidden indicators and canvas input routing retained |
| Git | Worktree/file list, diff reader and synchronized horizontal code panes | Wrapper/subclass; line selection and horizontal synchronization remain owned by Git |
| Plugins | Report relations, OpenCode process, Browser annotation list | Wrapper; Browser comment TextEditor also uses the control-scoped adapter |
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
again. The explicit jump animates to the bottom;
ordinary following and initial positioning remain immediate. Growth during a jump
is resolved at its end: the animation uses a fixed offset before restoring the
bottom edge anchor. A new manual scroll takes ownership; hiding the reader invalidates the old completion. Explicit reading visits retain position ownership while their anchors
resolve, including when an inline historical execution stops pausing follow.
Generic execution changes cannot supersede that visit. This does not change
reading-stack motion or projection/resource ownership.

Main reading also scopes its default position to the displayed execution. The
first conversation index can move a live execution into its Sidecard after main
has already opened at the live bottom. When that changes the main document to a
completed execution, the timeline releases the old follow state and returns to
the heading unless the user or an explicit reading visit owns the position. Finishing an execution without changing the displayed document keeps the current
position and final-output following; live Sidecard output retains its own follow
behavior.

The first reading request is resolved before mounting the page stack. A direct
history/result entry therefore starts on that document without first mounting
current or sliding from it. A never-visited current document is not acquired or
rendered behind that entry; an already mounted current reader remains retained
with its scroll state. Explicit TOC navigation still admits current for the
existing return transition. Result links keep their reply anchor rather than
forcing the document heading, and manual scrolling takes ownership even before
a non-following request's delayed anchor arrives. A new request may locate again.
See the [reading ownership contract](../../../../../design/reading.md)
for the implemented ownership boundaries.

The timeline keeps exact scroll geometry in a view-owned observable reference.
Only its small reading-control registration reads that geometry during view
construction. Native offset updates therefore refresh the control descriptor and
stale-handle fencing without rebuilding the document's row tree. Follow, locate,
prepend retention and relative scroll commands still read the latest geometry;
visible-row projection is shared by the document and registration per body pass.
See the [scroll contract](../../../../../design/reading.md)
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

The following streaming renderer capability is separate from Agent Thread reply
admission. Ordinary Agent main and Execution Sidecard readers withhold unfinished
assistant bodies before rendering, so they show neither token-by-token text nor
streamed pages. Their running-execution updates display newly completed messages.

[Reading/NativeMarkdownView.swift](Reading/NativeMarkdownView.swift) renders message-level streaming content as literal selectable text only when no reading viewport is known. For callers that admit streaming content and supply `nativeReadingPageCapacity`, [Reading/NativeStreamingPage.swift](Reading/NativeStreamingPage.swift) instead holds the open page back until it closes. Streaming revisions do not enter the ordinary Markdown parser; a settled prefix is parsed at top-level block boundaries and published one page at a time. On settlement, rich rendering resumes; obsolete parsing results cannot replace a newer streaming revision. Completed messages remain rich even while another message in the turn is active.

A streaming page is the visible content height of the owning `HarnessMessageTimeline` (viewport minus its fixed top/bottom insets, in points). Only complete top-level blocks are parsed, so a page break can never fall inside a fenced code block, table, list, blockquote or indented code block; an atomic block that alone exceeds a page is revealed whole. The open page stays invisible until the next settled block would not fit (or its measured height already fills the page), and completion flushes the remainder after reparsing the whole source. The reparse resolves reference definitions and footnotes that point at later chunks; pages rebuild only when that whole-document result differs from the already displayed blocks. Flushes reuse `NativeReadingPageTiming.replacementAnimation` for the vertical page entrance. A message that is one unsplittable block (for example a single long list or an unfinished paragraph) therefore appears when that block closes or at completion; multiple chunks in one state update coalesce into one flush. Because only closed blocks render, a following timeline's content height and follow scroll change at page flushes, not once per streamed token; the follow, pause-on-user-scroll and jump-to-latest contract is unchanged and settles after each flush.

[Reading/NativeMarkdownParser.swift](Reading/NativeMarkdownParser.swift), [NativeMarkdownText.swift](Reading/NativeMarkdownText.swift) and [NativeMarkdownTypography.swift](Reading/NativeMarkdownTypography.swift) own parsing and native text layout. Inline-code URL links retain link actions and selection; tables derive height from laid-out content. Mermaid fences display source. Native selection follows the active text view and the system window/application focus. Local absolute paths and local `file:` URLs render image syntax and add an inline preview below ordinary file links, while retaining native link actions. Local files bypass attachment resolvers and network loading; the composer ImageIO thumbnail loader decodes off the main actor (2048px maximum edge, 64MiB source limit). Text attachments fit the reading width and a 480pt height while preserving aspect ratio. Missing, unreadable and non-image sources retain their link/alternative text. Remote file hosts and executable URL schemes are rejected; relative paths have no inferred filesystem base. Local rasters live only with mounted Markdown blocks and refresh on remount.

Markdown tables reserve the native mini horizontal-scroller gutter in their
measured content height when the system prefers persistent scrollbars. SwiftUI's
horizontal viewport otherwise measures only the Grid, while AppKit subtracts
the gutter from the visible height and clips the last row. Overlay scrollbars
reserve no space; preference changes update this reservation. Row wrapping,
app zoom and adjacent block spacing continue to use intrinsic content layout.

Fenced and indented code retain their source lines without soft wrapping.
[`NativeMarkdownCodeViewport`](Reading/NativeMarkdownCodeViewport.swift) owns
the TextKit document's natural width and its AppKit horizontal viewport together,
so long lines remain reachable without widening the reading column, including
inside lists. It uses the shared native trackless scroller and reserves the
persistent mini gutter in its measured height; overlay scrollers consume no
space. Vertical wheel input continues to the reader, while horizontal and
Shift-wheel input belong to the code viewport. Selection retains source
characters and the block's Copy Code action retains the complete original
source, including its terminal newline. Inline code keeps its existing wrapping
and padding policy. See the [code viewport contract](../../../../../design/markdown.md)
for headless evidence and verification limits.

Absolute local HTML destinations and local `file:` HTML URLs retain the same
native link action throughout paragraphs, headings, lists, quotes, table cells,
reference links and footnotes. Inline code containing one such destination is
clickable like an inline-code HTTP(S) URL, including paths with spaces. Ordinary
unlinked filesystem text and fenced code remain literal. File URL queries and
fragments survive rendering; absolute paths treat `?` and `#` as filename bytes
(use a file URL for navigation suffixes). The shared PluginAPI parser decodes
path escapes once; the Browser/Host validates filesystem eligibility on opening.

Markdown source preprocessing preserves code characters and recognizes footnotes
before entity decoding; escaped syntax stays literal. Labels containing whitespace remain ordinary reference links rather than footnotes. [Reading/NativeMarkdownSourceMap.swift](Reading/NativeMarkdownSourceMap.swift) records each physical line's content start as bundled cmark consumes its quote/list prefix. Inline positions map through the retained raw block lines after reference definitions are removed, so lazy continuations, Setext, tabs and multiline literals share one source mapping rather than fixed column adjustments. BOM removal and NUL replacement retain physical byte provenance for every input line, including nodes without paragraph traces. Table cells also map their whitespace trimming and escaped pipes back through those input coordinates; a read-only parser hook observes each row’s actual container prefix without changing the AST. Paragraph-to-table promotion retains the complete original trace for both header cells and the synthesized preceding paragraph. Bare-URL rewrites stay within the original cell, preserve destination escapes until cmark decodes them, and escape generated pipe syntax so later cells cannot be swallowed. The mapper directly declares the already-bundled cmark 0.9.0 and isolates access to its exposed parser/block state; cmark source positions are an explicit parser/renderer boundary; no source-range matrix or native Markdown replay is configured here. Parser cache keys, stored SwiftUI inputs (including message and code-block wrappers), document revisions and rendered text comparisons preserve raw UTF-8 identity, so canonically equivalent Unicode sources cannot substitute URL or copy bytes. Footnote labels use Unicode
case folding and opaque URL-safe destination identities, including literal percent
sequences. Lazy paragraph continuations remain in their note. Bare HTTP(S) URLs
retain Markdown punctuation in their paths. Image alternative text flattens inline
formatting and is preserved by native partial copies. Selection, Select All and
copy belong to the active paragraph, code block or table cell; dragging does not
join selections across blocks. The document context menu's Copy Markdown action
still copies the complete source. List marker widths and table inline-code padding participate in actual
layout measurements. Inline code keeps its 5pt edge padding with the adjacent
code text at word breaks; long code still wraps using native TextKit rules. Its 3pt rounded background is painted separately for each visual line segment,
bounded by the actual code glyphs rather than selection rectangles extending to
the line edge. Padding-only fragments in extremely narrow containers paint no
background. Characters, link attributes and native selection remain in the text
storage, and Copy continues to omit the synthetic padding cells. Footnote returns reveal references through nested table and
conversation viewports.

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
action. The action carries the activated capsule’s visible window rectangle
for the reading panel. Attachments remeasure at actual container widths and retire their native
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

[Conversation/ThreadConversation.swift](Conversation/ThreadConversation.swift) and [ThreadTimeline.swift](Conversation/ThreadTimeline.swift) organize reading from the Harness's public turn index. [ThreadExecutionGroups.swift](Conversation/ThreadExecutionGroups.swift) presents adjacent execution rows under a summary with reasoning/tool counts and reported reasoning usage. Only the latest process summary in the latest running Agent execution carries a left-to-right text highlight, and only while it is also the final message-stream group. Harnesses classify the native tail before withholding streaming replies; a later assistant reply stops the sweep immediately, including before its text is mounted. OpenCode checks the last native part because replies, reasoning and tools can share a message. The 64pt band uses opaque strong reading ink with a broad center and soft edges. Only while motion is admitted, its text base uses 55% muted ink so both sides of the band visibly recede; the wrench keeps normal ink. Inactive scenes and pending entrance restore normal static ink. Colors follow the light/dark palette; earlier groups, history, completed/interrupted/failed executions and waiting-for-user states stay static. Harnesses supply execution-running state separately from reader activity. The decorative leaf uses the shared frame cadence, pauses outside the active scene or before reading admission; it adds no accessibility content or hit target. The highlight travels at roughly 180pt/s with a short gap between passes, without animating the wrench or changing text layout. In Agent Thread detail, the reading header's execution visibility control shows only this summary: nested Used tools group titles, Hooks, tool calls, commands, reasoning bodies and failed-tool diagnostics are details and never mount. Agent-only background terminal/task sections likewise show static counts/status rather than commands or descriptions, and hide with work; task failure is not a standalone Harness error. Summary-only historical groups do not acquire the scoped loader in [ThreadDeferredExecution.swift](Conversation/ThreadDeferredExecution.swift). Other conversation surfaces retain full member rows and scoped historical demand while visible. Execution membership takes precedence over attention styling, so a tool failure cannot escape the visibility group. Standalone errors and pending interactions keep their own timeline rows; a visible nonmember splitting a native run receives distinct summary identities. The summary itself has no disclosure arrow, hover treatment, keyboard focus or accessibility/reading action. Individual activity disclosures on other conversation surfaces retain their existing behavior.

Pending connection/status text in an otherwise empty active execution reuses
the summary's `ThreadLoadingTextStyle`, including its 64pt band, 180pt/s travel,
250ms gap and motion/entrance gates. All Harnesses use the shared turn renderer;
settled, failed, interrupted and waiting states remain static. Real content
replaces the pending label and removes its animation without changing admission.

[ThreadSteerMessage.swift](Conversation/ThreadSteerMessage.swift) presents explicit
ordinary follow-ups in Agent detail as one line of literal text and one line of
recorded message time. It has no author/sequence heading, receipt state or status
icon. Missing time is not replaced by the execution timestamp. Text that does not
fit the actual reading width can expand; attachment/annotation detail reuses the
Harness's existing user-message renderer only after expansion. Expansion uses
the ordinary explicit animation without consulting system motion preferences.
`.steer` rows render only while their execution is running and become invisible
once it is no longer running
(completed, failed, interrupted or waiting for input), even though the model, wire
fields and retained input remain. Read-only inherited transcripts that reuse this
row style without an owning execution retain their input. They stay independent of
user-input/work visibility and split execution summaries in their native order
while running, without creating an execution or moving the input target.
Codex uses non-internal `follow-up` messages; Claude uses non-internal prompt
indices after zero within an exact turn. Pi/OpenCode use persisted ordinary-input
`followUp` identity, owned by their send boundary. Unknown native/imported input
identity and OpenCode child-session input stay hidden; Claude's unscoped inherited
transcript has no per-execution prompt index and is not guessed into follow-ups.
The normal composer retains ownership of pending/error/unknown command receipts.

[ThreadDetailFrame.swift](Conversation/ThreadDetailFrame.swift) and shared typography retain reading insets and the centered column. [NativeReadingPageStack.swift](Conversation/NativeReadingPageStack.swift) owns retained page transitions, with host navigation described [here](../../Host/WindowNavigation/README.md).

[ThreadHistorySidebar.swift](Conversation/ThreadHistorySidebar.swift) presents the
conversation's turn index as horizontal marks centered vertically at the leading
edge. An ordinary single turn has no marks. Multiple entries, inherited history
or a history visit expose the index. The selected mark measures 26×2pt in strong
ink, and the remaining marks measure 16×1.5pt in muted ink. Their centers are
24pt apart. Hover or explicit keyboard navigation emphasizes an entry and reveals
its bounded title and answer preview.
The answer wraps naturally to at most three lines, with the title and timestamp
remaining visible; shorter answers do not reserve unused lines.
Restoring focus after Back does not reopen the preview. The mark and preview share
a cancellable 100ms pointer handoff, including the gap between them; leaving both,
unmounting or deactivating the scene retires pointer previews. The
viewport-bounded, independently scrollable index includes inherited history and
the current turn, without mounting historical bodies or parsing every answer.
Codex previews select the exact execution's last nonempty settled, non-error
assistant reply, matching the Agent reader, before clipping the excerpt. A
complete message does not require a completed execution: running/waiting turns
retain their latest settled reply, and failed/interrupted turns retain their
last readable reply. With no eligible reply the answer excerpt stays empty;
neither streaming/error text nor another execution supplies a fallback.
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
stacks retain their default horizontal direction. New turns do not replace
an open historical execution;
removed destinations show the unavailable document and retain return navigation.
Super Thread's related execution uses the full conversation manifest and the
shared history rail. The selected row owns the body and the composer while the
report stays mounted. Ordinary Agent execution sidecards keep their
single-execution presentation. They omit the
decorative emoji and visible document title, use a compact 12pt timeline top inset,
and retain the resolved author, messages and execution actions. Full reading and
history pages retain their headings and standard insets after execution ends.
Active ordinary Agent executions (including waiting for input) omit the visible
title and emoji in current/history readers too; author and messages remain.
Heading admission matches the selected execution ID against catalog activity and
also reads that execution's Harness-projected `isActive` state. Either active
source keeps the heading absent until both settle; a newer execution's activity
cannot suppress a completed historical heading. A Report reader with no selected
manifest row yet keeps the heading absent during startup. Report's retained
reference reader observes `catalog.threads`; the `thread(id)` lookup cache is not
observable and cannot drive its envelope updates.
The footer stays absent while either catalog activity or the scoped Harness
content still reports execution running, since these subscriptions can update
independently.

The Sidecard-to-main handoff first uses `NativeSidecardTiming.foldAnimation` to
fold the Sidecard back to its launcher while widening the main panel. After fold
completion and content readiness, `NativeReadingPageTiming` supplies the compositor
curve for the downward scroll to the latest execution. No absorption motion remains.
`NativeReadingContentHandoff` scopes a readiness callback to the exact execution;
`ThreadConversation` forwards it only through that row. Mounted production content
and readable errors acknowledge readiness with `nativeReadingContentReady()`;
placeholders do not. During handoff, `NativeReadingContentPreparation` additionally
waits for Markdown parsing and the content owner's `nativeReadingExecutionReady`
terminal state. Codex, Claude, Pi and OpenCode provide that state from their admitted
opaque content, independently of catalog completion. Running cached data cannot
release the handoff. Readable errors remain an alternate landing destination.
The Host retains the actual outgoing reader through preparation and travel, then
keeps the same incoming native host. This signal does not change reading destinations, scroll
following, data ownership or keyboard/accessibility focus.

A horizontal return requested during opening starts from the current AppKit
viewport geometry when matching native anchors are available. The anchors belong
to this stack's root and outer front viewport, outside the replaceable history
identity. They draw nothing, accept no input or accessibility focus, hold only
weak ownership links, and do not force layout or observe frames continuously. The close action first cancels the old generation, validates the same identity,
direction, window and viewport extent, then synchronously installs the measured
progress without animation. The existing preparation, curve, duration and final
navigation callback remain in place. Detached, mismatched or invalid geometry
keeps the previous model-based fallback. Vertical/history replacement, cancellation
and settled-page returns do not use this correction. This boundary accounts for
a model value being ahead of committed native geometry; it does not treat AppKit
bounds as proof of WindowServer pixels or assert that such lag caused a specific
historical failure. Agent, Report and Moku entry use panel presentation.

Non-panel progress is written synchronously from a per-stack display callback in
[NativeReadingPageFrames](Conversation/NativeReadingPageFrames.swift).


The display callback writes progress directly, without another task or timer
resume. The existing preparation sleep and the `ContinuousClock` origin taken
when preparation ends are unchanged; every sample uses actual elapsed time and
the same curve and duration. A native anchor attaches the clock only while a
window exists. It chooses that window's screen, or the main/first screen for an
offscreen window, and rebinds when the window or screen configuration changes.
This uses a screen display link so existing offscreen-window navigation can still
advance. Without a window, the request remains cancellable and produces no
frames. The anchor draws nothing, takes no input or accessibility focus, and is
separate from the two geometry anchors used for opening reversal.

Settle and retarget revoke both the route generation and the frame request;
native teardown revokes the request before a late preparation can arm it.
Stopping clears the callback and invalidates the link. The terminal sample stops
the driver before the existing navigation completion, while ordinary disappearance
still cancels without navigating. Parent preparation, committed-pose reversal,
panel travel and history replacement retain their existing owners. Display or
main-thread stalls can still delay presentation; this removes the independently
scheduled producer rather than promising every intermediate pose is displayed.

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
remain ordinary content; intermediate replies join summary-only execution work. Lightweight Pi/OpenCode turn projections retain interim replies for explicit
message visits without a detail lease. A targeted OpenCode child reply retains
all its text parts without exposing sibling replies or tools. OpenCode child sessions group their
execution rows into the same summaries and expose independent errors without
exposing sibling tools. An OpenCode assistant failure with no reply text
retains an independent failure-status message; a failed tool alone cannot create it. The same policy applies to live, completed, loaded
historical and inherited content across the four Harnesses. Empty filtered turns retain their execution status and result anchor; filtering
happens before grouping and rendering, so hidden events create no row gaps or scroll destinations. The
timeline's existing follow/pause, geometry-driven growth and jump-to-latest
behavior remains unchanged. Historical headings, previews and accessibility
labels use each row's execution title. The four Harnesses resolve it from the public `executionTitles`
map by exact execution identity. Missing names use the same row's first
user instruction, trimmed at its edges; blank or unavailable instructions use the
row's execution timestamp. This applies to new executions awaiting naming and
older executions without stored names. The fallback is a live reading projection:
later generated names replace it without persisting the instruction as a title. The current catalog title and other executions' instructions are never substituted. This also applies when main retains an older execution while the newest one
occupies a Sidecard. Thread title/emoji remain catalog metadata. Each Harness
entry sets `threadAgentDetail` from the public thread's Moku/current-history identity; Moku conversations keep their original
input visibility controls, prompts and notices. No stored history or other
surface is filtered. Narrow widths wrap the control and truncate the visible
author while preserving its complete accessible label, tooltip and text selection. For the selected running execution, work stays visible and its visibility control
is absent; completion restores the previous visibility behavior. Historical and
result visits compare their own execution identity with the running execution. The author comes from the actual Harness-rendered body, including runtime model
overrides; manifests cannot invent it. Completion time, duration and usage remain
in the footer. Inherited transcripts containing several turns retain each turn's
author locally. Its keyboard events pass through `NSApplication` so Escape reaches the same
current-event/window arbitration as application input. Return selects a history
row before its travel completes; the replay waits for that visit's existing
interaction-ready state before sending the next Escape.

Remote Markdown images use URLSession HTTP caching and revalidation, with no process-wide URL-only body cache. New document loads therefore honor `Cache-Control: no-store`; mounted images retain their current raster. The streamed 24 MiB body limit and decoded pixel limit remain enforced.

## Cards, composer and forms

Shared Harness card components keep task identity, usage, plan and extension layout consistent.
The identity title uses one measured line in every state, including while
running and before the first reply. Long titles truncate at the tail; the full
current title remains in help and the accessibility label. One line stays
reserved under vertical compression, with no second-line title space. A generated
title replacing a prompt cannot change the title seat's height. Card footprints
and independent state/model/runtime rows retain their existing contracts.
The execution excerpt uses the remaining identity-cell height after metadata,
steer and expanded recent-tool rows, with native tail truncation under compression.
There is no fixed five/eight-line execution limit; larger cells admit more whole
lines and short replies keep their natural height. Extension cells retain their
own space. Excerpt reveal layers use the same height proposal as settled text,
including when the card resizes; Report descriptions keep their explicit three-line
limit. The bounded source preview and streaming batch policy remain unchanged.
`HarnessThreadCard` and the Overview semantic boundary supply
`threadCardUsesFlatMaterials`: terminal badges and provider badges without an
emoji use static palette fills, and the in-progress plan row uses the accent-soft
surface without a glass container or effect. The 44pt emoji badge uses a static
opaque palette fill with no added border: adaptive accent-soft green when
completed, neutral surface-strong otherwise, including under Reduce Transparency.
By default it contains no Liquid Glass effect, avoiding per-card spatial glass updates when
panning Overview. Overview card shells remain neutral after completion. The emoji
stays 21pt, with the existing terminal mark preserving a non-color status cue.
The explicit isolated Overview benchmark can supply
`agentThreadEmojiUsesLiquidGlass` to `HarnessThreadCard` to compare the emoji
backdrop with untinted regular Liquid Glass. Only its emoji-bearing default
provider badge consumes the override; terminal marks, custom provider views,
clouds, plan rows and Report/collection badges retain their own materials.
The shared glass helper still respects Reduce Transparency. This is a launch-scoped
experiment, not a persisted preference; ordinary launches stay flat.
Agent and Report cards share its upper-right placement and title clearance.
Report uses the completed badge's accent-soft background without an execution
terminal mark; Agent execution status and its terminal mark remain independent.
The badge is status content with an accessible label and tooltip. When the Host
supplies `threadCardArchiveAction`, it becomes a 44pt independent archive button:
card hover or keyboard focus swaps its contents for a close icon, with a localized
archive label and tooltip. Pending requests disable the button; Return is consumed
by it rather than opening the surrounding card. No Send or message callback is
provided. Other card activation stays with the surrounding host. Empty plans
render no section.
The shared controls keep their original materials outside a card; this internal
renderer policy is not a preference and does not identify plugins by name.
Completion drawing and plan geometry remain unchanged. Loading-cloud
palette is supplied by the Harness rather than selected by identity inside the renderer.

The Git extension is omitted before composition when both known line totals are
zero, regardless of changed files or HEAD. It contributes no placement, footprint
or structural key, so the remaining extensions determine the complete card size.
Either positive total retains the extension. Unknown/failed totals keep their
existing changed-file/error presentation.
The Git extension renders signed numeric line counts only when both totals are
known. A single neutral label explains unknown, limit, timeout or unavailable
statistics; a separate stale label identifies retained observations. These states
retain the file count and branch without changing extension order. The extension
is read-only metadata with no dedicated diff action or button accessibility role.

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
window and host animation gates pause it. A mounted initial body gives way immediately to real content with a single 120ms
opacity entrance; remounts and later excerpt revisions keep the existing policy.

Composer state and submitted revision belong to the workspace. Attachment upload, file selection and send receipts are shared by the Dock and conversation surfaces. The Host’s `NativeMokuComposerInput` composes the shared text input, attachment chips and host file picker for both Dock and history; PluginUI owns those primitives and draft persistence. Harness and Moku interaction owners compose `InteractionQuestionField` with their own validation, submission and cancellation controls, sending through injected actions rather than bypassing Runtime admission.

The device open panel reserves the draft import while it is open. Cancelling
releases the reservation without staging files. Confirmed selections join the
same draft validation, pending-chip, preview and staging path as drop and host
file imports. The file values retain their macOS selection grants through preview
and upload. The desktop client streams local file contents to the connected
runtime under the existing client attachment lease.

Ready image thumbnails open the existing system Quick Look presentation using
managed absolute file URLs, with all ready images in the strip available for
navigation. Preview and remove are sibling buttons; pending images remain
non-previewable until staging supplies the original. Removing the selected
image, consuming the strip or unmounting it clears the preview selection. Preview
never stages, sends, discards or takes ownership of attachment files.

The shared attachment strip updates its content and horizontal viewport height
together. Removing the last 56pt image beside 28pt directory/file chips must not
animate the content stack independently of the shorter scroll clip; that briefly
cuts off the surviving chips. Attachment status/type changes use the same atomic
layout update. The surrounding Dock retains its own shell transitions.

Moku opts into `NativeComposerDraft.submit(optimisticallyClear:)`. Before
dispatch, persistent drafts atomically save the submitted text, directory
mentions and ready chips under a send ID alongside a fresh editable draft.
Acceptance consumes that ID. Rejection prepends the failed text to the latest
draft with a blank line and restores its chips. Selecting the same directory
in the next draft gives that draft its own mention. A reopened owner can
check the original receipt when the send lock is free. A prior command blocking
a different draft cannot claim that draft, even when both messages have the
same text. Local recovery is available when there is no retained receipt.
Storage errors belong to the failed write and clear when persistence succeeds.
Resolving a tracked handoff saves a cleanup ID atomically with the successor.
Cleanup can finish after reopening, even if the journal already released the
receipt. Querying a historical phase never submits input. An existing fork with
unsent input keeps its protected receipt until the user decides what to keep. A writer that loses a revision conflict keeps its unsaved
buffer and an error until it reopens the durable draft. Its stale revision
cannot overwrite the winning draft or prevent that draft from consuming a send.

A mounted editor receives these changes synchronously on the main actor.
Send and Return capture only committed input. While a failed send is being
restored during composition, the input method keeps its marked range. The
draft saves the recovered prefix and the composing text, then installs the
prefix and adjusts the native selection when composition finishes. The saved
draft records the identity of its last body edit. A second editor that only
changes directory or attachment chips keeps the inherited body identity. The
first editor can then commit its candidate once alongside those chips. If the
second editor replaces the body, even with identical text, its edit survives
as a separate paragraph above the committed candidate. Rejection also restores
the submitted text above both edits. The caret stays with the committed text. A held
Return or double-click cannot retry the previous send. Other composer callers
retain receipt-time clearing.

Attachment paste shortcuts bind to the exact mounted native composer through a
shared editor identity. Common window ancestry and overlapping geometry cannot
authorize a retained/covered composer to paste into its draft. Provider decoding
and staging keep the draft captured at paste admission. See the
[attachment ownership contract](../../../../../design/composer.md)
for draft and attachment ownership.

[Forms/PublicInteractionQuestionnaire.swift](Forms/PublicInteractionQuestionnaire.swift)
projects public form metadata consistently for the Dock and Reader fallback.
Visible defaults populate the editor; optional absence remains valid. Hidden
defaults participate in conditions without becoming steps, and inactive drafts
stay local. Core retains schema validation and native answer conversion.

For receipt-time clearing, accepted sends consume persisted attachments by chip and staged-file identity even when a successor has advanced the draft revision. Text and directory consumption retain their revision guard. Live successor drafts lose only the accepted chips; pending imports, previews and newer input remain untouched. Repeated consumption is a no-op, and readding the same file with a new identity is independent of the old receipt.

Each draft write publishes its ready staged-file IDs in the Core ownership
envelope together with its contents. A successful send releases its staging
reference only after this durable consumption succeeds. A persistence failure
keeps that reference; the runtime's independent Thread ownership protects
accepted files after the chip is consumed.

Native text bindings compare UTF-16 code units so canonically equivalent Unicode replacements remain real draft edits.
`NativeComposerTextInput.preservesSelection` opts Moku into native selection
retention across temporary focus/availability suspension. It snapshots before
selection is disabled, restores after selection is enabled, and reveals the
restored range in the multiline viewport. It restores only against identical
UTF-16 text; changed text uses an insertion point at the end. Marked text is
never snapshotted or replaced by this suspension path. Explicit selection
requests retain priority, and restoration does not request focus. The Host
retains a text-associated initial selection for full Dock editor remounts.
No mounted UI/IME correctness replay is configured in this source tree.

`NativeComposerTextInput` and the Custom task orchestration editor opt into the
shared [NativeCaretTextView](Composer/NativeComposerCaret.swift) insertion effect. It uses a
rounded caret, sized to 25/24 of the text size plus one point, with its center
one point below AppKit's actual `drawInsertionPoint` rectangle. The top edge
sits half a point lower and the lower end reaches the descender without moving
glyphs. View coordinates are converted through AppKit to the backing layer's
coordinates before placement, so a flipped or scaled text view does not
displace the mark. The 2.6-point core is white in Chief's dark composer and
uses the adaptive label color in Settings. Both use a warm-yellow upper halo
and cool-blue lower halo. Ordinary composers keep the native caret. Empty
emphasized composers leave three points between the insertion origin and
placeholder text.
The halo preserves the approved study’s blurred 16-point warm and 14-point cool
ellipses plus a 4.6-point gradient fringe. Halo widths and blur radii scale from
the study’s 25-point core to the editor’s actual caret height. The transparent glow image is rendered
once per caret height/backing scale and its opacity is animated by Core Animation;
no per-frame SwiftUI rendering or timer is needed. Emphasized editors place their
existing padding inside the native text viewport, preserving glyph positions while
leaving room for the glow before native scroll clipping.
The core breathes at 20–100% opacity while both halos fade fully.
Core Animation breathes over 2.4 seconds; native blink callbacks do not hide it
or restart the cycle. Same-line movement interpolates over 120ms from the current
presentation; repainting an unchanged rectangle does not restart movement.

Marked text uses the native caret, and line changes bypass interpolation. Selection,
loss of focus, hidden windows and detachment release the layer and its animations.
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
Liquid Glass as other floating actions, with a downward arrow and a six-point
rounded shape. The package requires macOS 26, so no older-system fallback
is needed. SwiftUI owns light/dark appearance and accessibility material
adaptation; the button keeps its localized accessibility label and help, native button semantics and
`jumpLatest` reading action, with no change to following or scroll behavior.

[Thread-card numbers](Cards/ThreadCardMetrics.swift) retain positional cells from
right to left while usage changes. Changed digits enter from above and retire
below over 260ms, for both increasing and decreasing totals; clocks retain their
180ms opacity transition. Initial values mount settled, unchanged glyphs stay
still, and added/removed positions follow the formatted width (including compact
units). Retained positions change only glyph identity; card and usage-part
identity stay stable.
SwiftUI owns outgoing usage glyph lifetimes, including interrupted updates. The text
raster tier suppresses animation only when its scale changes; it must not clear
unrelated glyph-motion transactions. This number path retains the existing
always-animate policy.

[Runtime clocks](Cards/ThreadCardClock.swift) use the same SwiftUI numeric cells
as their glyph source and layout/baseline strut. A bounded immutable bitmap cache
shares digits and colons across cards, keyed by resolved ink, legibility and
display/text raster scales. Core Animation owns the 180ms digit and colon fades;
no per-frame SwiftUI text layout or additional clock timer is required. Initial
values mount settled, positions retain identity from the right, and stopping a
clock retires any colon fade. Style changes replace ink without replaying it.
The bitmap seat uses the native host's backing-pixel rounding rather than stretching
the 13.75pt logical cell. The cache retains at most four styles and 32 MiB, except
for one individually oversized zoom tier; no card or execution is retained.

The native overview retains offscreen cards and the overview behind a reading
page. `ThreadCardAnimationVisibility` reports their actual viewport/page visibility
independently of the cloud-animation switch. A running duration suspends its
one-second task while that visibility is false or the scene is in the background;
on return it immediately samples wall time. Completed durations stay fixed.
Disabled cloud effects do not stop a visible duration. Outside
the overview, omitting the visibility environment keeps the ordinary visible
behavior; an inactive but still visible window can continue showing elapsed time.
Derived-work scans, permission attention and running-tool spinners pause for
hidden/background cards or disabled host animations. Pausing does
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
`ThreadCardInkMask` gradient masks. The Report collection reuses that mask with
its own shared 460ms cover progress and mirrors it for backward paging; excerpt
buffer ownership, 280ms timing and its fixed reveal direction are unchanged.
The mask view itself does not interpolate progress, removing
that cause of per-frame body evaluation. Buffer advancement, reveal
ownership, disabled-animation resets and the 800ms hold remain leaf-owned.
Each new reveal key replaces only its two stateless visual layers, retiring
the previous offset animation's presentation before the incoming mask starts
at zero. The excerpt owner, buffer and tasks remain mounted; appends within
the same window and local width changes retain the current visual identity.

One title transition consumes the latest pending value at each completed beat;
new titles do not cancel its wait, so sustained updates cannot starve display. Hiding, backgrounding or detaching cancels that owner and settles the latest title. Cancelling an active transition replaces only its stateless animated text leaf,
so an in-flight fade-in is retired even when its model phase is already settled;
the transition owner and card keep their identity. Disabling cloud effects does
not freeze text content. Title and excerpt animations use their ordinary timing
under Reduce Motion. The [motion contract](../../../../../design/motion.md)
describes Collection member opening and card removal. Native framework defaults
and external Report HTML/CSS remain renderer-owned.

Window visibility, detachment, cancellation and explicit pause are separate lifecycle controls. Reduce Transparency fallbacks, contrast and accessibility labels are independently owned by the relevant views. [NativeCloudLoading.swift](Design/NativeCloudLoading.swift) and [NativeCloudField.swift](Design/NativeCloudField.swift) share the loading field and pause at zero visibility/intensity.

### Native Overview decorations

`threadCardNativeDecorationsEnabled` defaults to false; only the production
Overview card closure opts in. Its cloud uses
[NativeOverviewCloudView](Design/NativeOverviewCloudView.swift), a stable native
view with a screen-rate-capped serial render timer and transparent Metal layer, instead of a SwiftUI
timeline or nested hosting graph. The existing seeded, point-space
`NativeCloudField` and the shader's `cloudField` function serve both renderers.
Palette colors resolve from the current SwiftUI environment into premultiplied
linear components; the native drawable declares the same linear working space.

The soft cloud field renders at half the backing-pixel width and height, then
scales to the same layer bounds. The shader maps actual drawable pixels back to
logical points, preserving positions, radii and the live motion path. Text and
card borders keep their own original resolution. The existing maximum-rate
driver is unchanged; this reduces spatial samples, not animation frequency.
The tradeoff is softer cloud detail, particularly under magnification. The
[candidate measurements](../../../../../tools/benchmarks/baselines/2026-11-13-live-cloud-candidates.md)
record the observed GPU/memory benefit and the absence of body-update CPU gains.

The native view retains its seed and epoch across running, palette and visibility
updates. It interpolates light intensity over 0.4 seconds, including reversals,
without publishing per-frame SwiftUI state; fading final layer opacity would not
preserve the field's additive energy. Geometry and semantic updates remain inputs
from the surrounding card. Inactive completed views do not request drawables;
bounded rendering work runs off the UI thread and removal retires its driver.
The existing shared SwiftUI renderer remains the capability fallback and the
renderer for other cloud consumers.

The render queue samples immutable inputs independently of the main run loop.
Only geometry, resolved colors, activity and visibility cross from AppKit;
first-frame reveal still returns to main. One in-flight GPU frame bounds work,
missing drawables retry, and generation/revision fences retire stale work.
Static fields stop after a successful draw; a zero-energy terminal frame finishes
fade-out and stops the timer even while main is busy. Hiding/occlusion preserves
the last image and cancels sampling; detach/removal retires the generation.
The timer is not a display-link or a physical-FPS guarantee. Main-thread blockage
still delays newly requested state, layout, visibility and interaction changes.
[NativeStatusSpinner](Design/NativeStatusSpinner.swift) supplies the production
Codex quarter-ring indicator. Core Animation owns its 800ms linear rotation;
resolved colors, line width and size retain the original geometry. Background
scenes, hidden/occluded windows and detachment stop rotation.
Resume rejoins the existing wall-clock phase. The decoration owns no input or
accessibility, and its native layer changes never publish a SwiftUI frame value.
See the [implementation and validation record](../../../../../design/motion.md)
for main-thread admission boundaries and remaining performance limits.

[NativeCardScan](Design/NativeCardScan.swift) moves the existing gradient through
Core Animation's 3.4-second linear cycle. Pausing retains its displayed position;
resuming aligns to the current wall-clock phase. It needs no application
per-frame callback. The existing scene and visibility gates stay
in the card, while native views exclude themselves from input and accessibility.

The production path uses the live Metal field. There are no baked loop
resources or playback rate-selection branches. No decoration/main-thread-hold
correctness replay is configured in this source tree. CPU, producer callbacks
and GPU submissions alone do not establish independent WindowServer motion
or physical frame pacing.

Fonts, icon licenses and attribution live under [Resources](Resources/). Metal assets are compiled through the package's build plugin.

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
submits work. It does not claim composer, sidecard, link or media
coverage. [The reading runner](../../../../../tools/native-interaction/README.md)
uses these observations for production-app chaos and replay.

Timeline offsets normalize `contentOffset.y` by `contentInsets.top` before
feeding `ScrollPosition`, retained history positions or relative scroll commands.
Snapshots keep the raw offset and inset alongside the normalized position so
replays can detect coordinate drift instead of accepting a finite but wrong value.

Chief Note citations and execution-result visits use the nested reader for current
and historical executions. The cited run keeps its identity through streaming,
completion and a successor. A citation starts at the document heading with
output following off. A result request locates the result after the body loads. Each Harness's typed detail rows supply visible
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

All Harness settings editors keep Provider, model and thinking/variant controls
in their primary layout. `NativeHarnessSettingsFields` puts permission mode,
Codex service tier and the default-configuration toggle under one initially
collapsed **Advanced options** disclosure. Pi execution snapshots have no
secondary controls and therefore no empty disclosure. Field drafts remain owned
by each Harness; collapse/expansion never saves, clears or replaces their values.
Default mode retains its existing inheritance and explicit-toggle semantics.
Read-only inherited profiles keep the disclosure and resource retry available.
The host sets `nativeSettingsReadOnly`; the shared wrapper disables basic and
advanced value controls without disabling inspection. The host also rejects
value changes independently of the presentation state.
Hosts can supply `nativeSettingsBeforeAdvanced` for one host-owned region between
basic fields and the disclosure; Pi snapshots use the same wrapper without an
empty disclosure. The slot clears itself for descendants to avoid recursive
insertion. Moku supplies its model routing preferences and keeps their interaction
scope independent of the Harness. `nativeSettingsRowVerticalPadding` allows its
12pt row rhythm without changing other Settings pages or local Agent detail.
Provider labels and the disclosure title use the existing Chinese/English
localization catalogs and update with the interface locale; native provider IDs
remain exact. OpenCode has no Agent selector or description and uses build for
capability checks and writes. No Harness editor correctness replay is configured here.

[NativeModelSelector](Forms/NativeModelSelector.swift) uses the shared system
`NSPopUpButton` for models and reasoning in Settings (`nativeSettingsFormPage`)
and onboarding/role panels (`nativeSettingsCompactPresentation`). Default and
reset values remain explicit menu options; no slider or nested model menu is
mounted in those forms. AppKit owns menu rendering, focus, keyboard navigation,
cancellation and accessibility. The shared adapter preserves opaque option IDs,
disabled rows, row-label activation and discrete-change interaction registration.
The native controls expose their actual actions/bindings to semantic interaction;
no select-control correctness replay is configured here.

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
The direct embedded-popover/slider components are separate from the current
Settings page/compact selectors. No Settings-control, Harness-form or full-page
Settings correctness replay is configured in this source tree.

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

The shared reading stack can present Agent, Report and Moku history routes
as a bounded panel, using a source card frame where available. It retains the same route identity, explicit progress clock,
close/cancel lifecycle as page navigation. Panel
content remains reader-owned; Agent title/emoji can use the window-local identity
bridge described below while its outer frame expands. The final aperture admits the host's independent toolbar
outside the panel. The front layout includes a 76pt trailing toolbar seat so
native pointer input reaches those buttons; their labels expose a complete
42pt circular hit region. Other application pages and vertical history transitions
keep their existing presentation. `NativeReadingPanelGeometry` is the shared
viewport/margin contract for production and the standalone native fixture.

`nativeReadingPanelViewport()` reserves an inner frame of 8pt horizontally,
48pt above and 22pt below by default for Moku history
reading panels. Report panels opt into
`topInset: 8, balancedVerticalInsets: true`, reserving 8pt at both ends. The main
Agent Thread panel and live execution Sidecard use `topInset: 22`, matching their
bottom viewport clearance. The Sidecard has no Close control of its own.
The main Agent reader and the related-execution reader in a Report overlay
the TOC on the page stack. Each mark has a 44×24pt hit target starting 4pt
from the viewport's leading edge. The index clears the top and bottom by at
least 64pt. The bounded document column uses a minimum margin of 48pt on both
sides, including before the second turn arrives. The scrollbar stays at the
viewport edge. Main-panel preparation, loading and top-level Harness errors
use the same margins. Each document applies them once around its content.
Current and historical Agent documents use 12pt of scrollable padding at each end, without
additional vertical padding around the conversation viewport. This keeps the
Close clearance while expanding the readable area at every window width;
timeline page capacity uses the same document padding. The sibling Moku input
keeps its existing host layout. The entire viewport
sits inside this frame, so persistent and
overlay indicators, their hit regions and both scroll limits clear the rounded
edge. The default top clears Close's complete 14pt inset + 32pt hit region,
including when an overlay scroller expands on hover. The main Agent document's
leading margin clears Close with the smaller top inset.
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
Despite its name, the explicit top override applies to both document edges.
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
corresponding document boundary at its scroll limit. Title/emoji and author spacing belong inside the document. Close stays at its
14pt panel inset, clear of the document and the TOC marks throughout
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
three-stage timing remain unchanged. The live execution Sidecard also uses
22pt viewport chrome and no page-stack inset; its 12pt scrollable document
inset gives the same 34pt boundary at each scroll limit. Its horizontal insets,
scrolling, launcher and dismissal ownership remain unchanged. Report uses the
balanced viewport argument with an 8pt top inset; its related-execution reader
retains its own page-stack spacing.
Moku viewport defaults are unchanged.

No mounted viewport correctness replay is configured in this source tree.

The later live Sidecard alignment was reviewed against the source geometry and
checked with Swift parsing and lint; its rendered scroll limits and interactions
have not been visually accepted in a running application.

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

No mounted Report-return correctness replay is configured in this source tree.

Hosts interrupting motion for recovery can request `cancelAll(finishingClose: true)`
to complete an accepted return for its current visit. Default cancellation still
preserves the page, and recovery never revives a previously cancelled return.

`nativeReadingEscape` shares the conversation reader’s native viewport-scoped
Escape owner. It rejects events owned by editing/IME, menus or
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
[loading contract](../../../../../design/reading.md)
for paired observations, variability and manual coverage limits.

### Agent Thread admission and motion

Agent Overview cards register window-local title/emoji anchors through
`NativeThreadIdentityRegistry`. An ordinary card-open copies their text and
geometry into one route visit. Before travel, the workspace prepares its sidecard
geometry and a row-free `ThreadConversation` using the same heading layout.
The main Agent reader centers the bounded reading column in the full viewport
throughout loading and history navigation. A real sidecard open/close resizes that viewport and
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
not use a trailing 48ms debounce. The panel's completion and visible host admit the title handoff. If reserving an
execution column shifts the live heading horizontally, the compositor continues
from its presented position to the measured reader anchors before handing
painting to the live heading. The bridge never retains
card/reader/plugin instances; replacement and close retire its layers. Direct result
navigation and entries without a visible source card retain their ordinary entry.
See the [reading admission contract](../../../../../design/reading.md).

Agent closing keeps the 420ms native panel return. The complete reader fades
over the first 80%; scaling and shell travel reach the source card at 86%.
The shell stays opaque until arrival, then crossfades to the refreshed Overview
through the final 14%. This final handoff owns transition completion so the
carrier cannot disappear before reaching the card. Closing has no independent
title/emoji travel. `NativeReadingPanelReturn` owns these phases for both Agent
and Report; nested history keeps its existing motion policy. The panel Close
appears only after
reader admission and fades before return; its position and hit region remain
owned by the production upper-left control.

The main Agent workspace opts into `nativeThreadUsesLoadingSkeleton`. Scoped
loading uses the shared `NativeThreadLoadingSkeleton` after its 180ms grace
period. Parsed Markdown mounts as a complete document; execution summaries and
the terminal footer use their ordinary SwiftUI layout. The panel host alone
controls first paint during primary travel. Running execution positioning and
later streaming updates retain their own scroll and rendering policies. A
completed execution promoted from a Sidecard still acknowledges destination
content readiness before the retained source retires.

Initial conversation admission uses an inline loading placeholder until its entry
request is consumed. It must not use the surface placeholder: with an identity
visit, that placeholder builds `NativeThreadOpeningContent`, itself a conversation,
causing recursive mounting before the initial `onChange` can run. The outer
surface retains title/emoji loading presentation; the internal admission gate
remains a leaf. The production thread-panel fixture above exercises this path.

### Width-driven Markdown layout

`NativeMarkdownColumn` measures document/list blocks at the supplied reading
width with unconstrained height. It retains at most four width proposals in
SwiftUI's layout cache, clearing them when the layout/subviews change; measurement
and placement share those results. List markers, quote rules and footnote numbers
use a fixed leading slot, so horizontal flexibility negotiation does not probe
their paragraph at one-point width. SwiftUI owns right-to-left mirroring.

Completed replies use the width-driven column in both the main timeline and
Super Thread's related-execution reader. For long documents,
[reading sections](Reading/NativeMarkdownReadingSections.swift) reserve
offscreen space from the block metrics at the actual reading width. Approaching
a section mounts its blocks once for the visit. Reversing direction keeps those
views, their measured heights and their native selections. Reading more of a
document can therefore increase the number of mounted views. Short replies,
footnote anchors and exposure-tracked notes use measured blocks throughout.
See the [Markdown layout contract](../../../../../design/markdown.md) for the
section sizes and streaming boundary.

The [local related-execution replay](../../../../../tools/e2e/README.md#super-thread-reading-regression)
checks scroll direction changes, native selection and resize. Image failure
hints use the native text view's tooltip and accessibility help.

Markdown publishes the complete parsed document and acknowledges its token in
the same update. A newer revision supersedes pending parse results, including
when the replacement is empty; disappearance cancels the worker.

There is no additional cross-visit attributed-string or native-view cache.
Existing immutable parse/content caches and layout-local measurements retain their
own lifetimes; every reader owns fresh native text, callbacks and selection.

The outer native reading panel and Agent completion-handoff reader accept the
workspace's finite width/height proposals directly. Their dimensions belong to
the workspace, not the hosted document; AppKit must not traverse all native text
descendants to infer another viewport size. Unspecified/unbounded proposals still
use the default fitting path. The panel's manually framed `NSHostingView` disables
content-derived sizing constraints, matching the retained handoff seats.
Content layout, selection, scroll position and compositor travel remain owned by
their existing implementations. See the [reader layout contract](../../../../../design/reading.md).

Report uses `NativeReadingAuxiliaryBackKey` to offer an opened referenced
execution's Back action to the outer reading workspace. Its default reference
list adds no Back step, even while pending admission or explicitly reopened.
The preference carries a stable identity and a main-actor callback; equality
ignores closure allocation so ordinary redraws cannot republish a fresh
navigation action. Folding the card
removes the preference. The Host keeps Close and browser-first cancellation.

Agent and Report Sidecards share `NativeSidecardWorkspaceGeometry`,
`NativeSidecardFold` and `NativeSidecardToggle` in Conversation. The shared
geometry retains the 16pt gap and switches to vertically stacked panes below
760pt; the fold owns the visible and interactive aperture without resizing the
native document on each animation frame. Agent aperture shapes and native frame
markers interpolate at the rendering leaves; only the bounded opacity curve has
an animatable view modifier. This avoids placing the retained document again on
every fold tick, even when its proposed size is already fixed. Report retains
its existing per-frame return-pose memo for closing during a fold. All use
`NativeSidecardTiming.foldAnimation`:
380ms, cubic Bézier `(0.22, 1, 0.36, 1)`. The shared duration also supplies the
Agent native-content interaction gate.
See the [layout-placement follow-up](../../../../../design/reading.md)
for the implemented layout/admission boundaries.
Report's linked Browser uses a close fade through `fadesOnClose`;
this changes only return presentation, not opening geometry or timing. Its shell
is retained before the first URL, so first opening and reopening use the same
host selection transaction as the other sidecards and the main pane. There is
no Browser-specific opening state, layout-stage callback or completion reset.

The production opening paths share these owners:

| Sidecard | Entry paths | Opening owner |
| --- | --- | --- |
| Agent Execution | Launcher, initial active execution, correlated send reveal | Host selection snapshot → shared fold |
| Agent Browser | Launcher, plugin URL intent | Host selection snapshot → shared fold |
| Report related executions | Readiness admission, launcher, switch from Browser; list/execution width changes | Report active selection → shared fold |
| Report linked Browser | HTML main-frame HTTP(S) link, new-window HTTP(S) GET, retained launcher, switch from references | Report active selection → shared fold |

All four use fixed destination-size native content, the same launcher-to-panel
aperture/offset and opening opacity ramp, including narrow stacked layouts and
retained widths. Agent drag disables travel; Report Browser
drag does likewise. Report references have no divider.
`NativeApplicationHTMLSurface` routes both HTML link entry points to the native
workspace; no application-owned CSS/JavaScript sidecard opener exists.
`BrowserViewport` keeps WebKit inside its representable, inheriting that shell's
mask and motion rather than adding another webpage transition.

Content admission is separate: Agent Browser suppresses its native page while the 380ms selection gate is active; Report
waits for current HTML readiness plus 200ms.
Those existing gates, document loading, Browser loading
and annotation indicators, 220ms Report navigation retraction, the resident Dock's
620ms response spring and the sequential 380ms fold / 420ms execution scroll retain
their own sequencing policies. External pages keep their
authored animations. No web content, native suppression, focus, media or navigation
policy is changed to force content to appear before it is ready.

Code review
can establish shared interpolation and transaction ownership, but cannot certify
rendered frame pacing, WebKit mask composition or rapid reversal appearance on a
WindowServer. Wide/stacked openings, switches, first-link/reopen,
resize and close/reversal still need visual acceptance when that scope is allowed.

Report commits its initial folded layout through `NativeReadingEntranceStage`
after primary reading travel. A preselected Note execution under Reduce Motion
reserves its final side-by-side or stacked panes from the first Report layout.
Document and execution readiness still govern content and input admission.
The reduced-motion Note visit presents its ready content at full opacity. `NativeApplicationHTMLReadinessKey` carries the
current source, thread, WebKit view generation and main-frame readiness.
`NativeReportSidecardPresentation` waits for both gates, then 200ms, before
admitting the latest pending selection. Report references and Browser share
that single selection; closing or switching cannot revive a replaced card.
Document replacement, covering and departure revoke pending admission.
Folding retains the selected execution reader, with hit testing and accessibility
excluded until reopening. Returning from an execution restores the reference
list; the next Escape folds it and returns focus to its launcher.
`NativeReadingAuxiliaryToolbarKey` contributes the Report launcher to the host's
reserved rail, alongside a retained Browser launcher when links have been opened.
`nativeReadingAuxiliaryLauncherPosition` supplies its actual workspace seat to
the fold, including Browser splits and narrow-window stacking.

The host scopes `threadRelatedExecution` to Report's referenced execution reader.
Running, waiting and completed references keep the exact execution title
(instruction, then timestamp fallback) and the Harness's thread emoji. The
heading waits for the selected row rather than borrowing the latest catalog
title while loading; ordinary Agent execution Sidecards keep their heading policy.
Completed references keep the final reply and ordinary non-work facts while
hiding execution work and its process summary. Active references show the
shared live process summary. After an accepted send from a Super Thread,
its active referenced execution shows the submitted text and a random emoji.
The Report visit retains that emoji by exact Thread/execution identity, including
same-execution steering, folding and catalog refresh. Later accepted sends to the
same execution replace only the text. Whitespace is collapsed for the heading;
blank text uses the exact execution's ordinary title/instruction/timestamp fallback.
The shared heading truncates long text to two lines and exposes its full text on
hover. Only the still-current composer/selection visit may install this title;
other active readers keep their existing heading policy. Completion restores the
ordinary execution title and Thread emoji; no catalog or historical title is
written. Leaving the Report retires these visit-local send titles. See the [Report admission contract](../../../../../design/reading.md)
for lifecycle details.

The outer reading stack can accept a `panelFrontIdentity` for a route-retaining
Host container. Its default remains the document identity. Report continuation
uses a stable native slide container inside that single outer stack; the Host
still keys each production document by route. Retiring a Report therefore cannot
tear down or replace the new route's outer motion/Close owner. See the
[continuation slide notes](../../../../../design/reading.md).

Report Close supplies `NativeReportPanelReturn` during parent preparation and
return only. `NativeReportSidecardPresentation.updateLayout` cancels pending
admission while retaining active selection for this phase; readiness loss or
suppression cannot widen the main reader. Completed route unmount calls `cancel`;
explicitly cancelling return restores normal readiness/admission. Covering and
execution continuation do not opt into this retention policy.
`nativeReportMainReturn(size:)` retains the real reader in a native carrier and
calls the same `NativeReadingPanelReturn` as Agent. The carrier travels with a
rounded aperture; its reader scales uniformly and fades over the first 80%.
Travel ends at 86%, followed by the shared shell handoff through the final 14%.
WebKit bounds stay fixed from
return preparation through completion; no GeometryEffect or implicit animation
transaction is required across the panel/route hosting boundaries. The document
frame memo retains the last interpolated size if Close interrupts width travel.
Report Sidecards opt into the same native host inside `NativeSidecardFold`; their
carrier changes opacity only while the fold memo retains its aperture/offset.
Agent Sidecards do not mount this additional Report host.
Both carriers use the stack's monotonic start time, duration and Agent return
curve `(0.3, 0, 0.2, 1)`. Native completion remains generation-fenced. Cancelling
return removes
carrier animations and restores its untransformed reader; route unmount retires
the hosting content. There is one live reader per surface, without a bitmap copy.
No native carrier-return correctness replay is configured for this surface path. See [Report Close](../../../../../design/reading.md)
for the native-host return and ownership contract.

`NativeRelatedExecutionEntrance` owns Report referenced-reader admission. It
reuses `NativeReadingContentPreparation` to wait for real row content and native
Markdown parsing, then fades one retained native host over 200ms. Only opacity
animates; reader geometry, resource leases and navigation remain with their
existing owners. Its preparation indicator stays visible until admission and
hidden readers are excluded from pointer, keyboard and accessibility interaction.
Streaming, refresh,
and read-error recovery do not repeat it; selection identity owns a fresh visit.

`NativeReportExecutionScroll` wraps the related-execution capability with that
admission gate. Manual reference selection retains the fade; a send-created
execution instead waits behind the actual outgoing reader and enters from below
while the outgoing viewport moves up. Both model viewports remain at their final
size. Landing retains the new host and its scroll model, and stale visit callbacks
cannot reenable input. The Report's Back button lives outside this carrier.
`NativeReportSidecardPresentation` owns the selection and execution visit alongside
Browser/list admission; accepted continuations are visit-local and independent of
the authored reference list. The window supplies one presentation per route.

`NativeSettingsChoiceButton` shares the existing interactive capsule appearance
between role modes and model routing presets: full capsule hit shape, selected
checkmark, native button keyboard behavior and accessibility selection. The
Settings panel's opaque background is independent of these small glass controls. Harness advanced options retain their native disclosure and expand the label’s
hit shape over trailing row space with a 32-point minimum height. Expansion stays
local to the editor and never changes retained field values or saves by itself.
