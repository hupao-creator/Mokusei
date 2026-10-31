# Shared native UI

This target supplies design resources, Harness cards, Markdown reading, conversation layout, composer and forms to the macOS application. AppKit adapts native text, input and viewport behavior within the Swift package.

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
during native hover/drag tracking. A persistent (legacy) system style keeps its
scroller resident so its native gutter stays reserved at every content height:
crossing the overflow threshold neither narrows the viewport nor shifts centered
content or rewraps text. The trackless slot and AppKit's empty knob paint nothing
until scrolling is possible. Accessibility and device preferences take priority
over automatic hiding. No global appearance, swizzling,
window-wide traversal, wheel monitor, preference write or replacement scroll-position model
is involved. Light/dark, Increase Contrast, Reduce Transparency and Reduce Motion
stay on the native rendering path; this component adds no animation.

The SwiftUI adapter is a noninteractive background **inside its own content**.
Do not attach it outside a viewport: nested code/table panes must configure their
own scroll view rather than the surrounding timeline. Existing `ScrollPosition`,
`ScrollViewReader`, geometry callbacks, bounce policies and enabled axes remain
at their callers. Explicitly hidden navigation/chip indicators stay hidden.

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
| Shared conversation | Timeline, activities, Markdown code and tables | SwiftUI wrapper; timeline diagnostics remain timeline-owned |
| Shared composer | Native multiline editor, attachment strip, host file picker | AppKit subclass and control-scoped List adapter; attachment indicators remain hidden |
| Settings and shared selects | Main form, section strip, agent/error detail, native textareas, option and model menus | Wrapper/subclass only; bindings, validation and menu focus unchanged |
| Moku | Note (including short viewport), directory completion, Talk, dispatch details and interaction bodies | Wrapper; completion uses native drag/accessibility instead of its old custom thumb |
| Overview | Tag/filter navigation strips | Wrapper; existing hidden indicators and canvas input routing retained |
| Git | Worktree/file list, diff reader and synchronized horizontal code panes | Wrapper/subclass; line selection and horizontal synchronization remain owned by Git |
| Plugins | Report relations, OpenCode process, Browser annotation list and Voice transcript | Wrapper; Browser comment TextEditor also uses the control-scoped adapter |
| Harness interactions | Codex JSON elicitation, Claude permission/elicitation/reply and OpenCode permission/custom-answer editors | Control-scoped TextEditor adapter; form state, validation and actions stay with each Harness |
| WebKit Browser and Report HTML | Main document, subframes, textarea and page-owned overflow | Shared `NativeWebScrollbarStyle` user script in every frame; transparent tracks, native scrolling and unchanged scrollbar dimensions |

[NativeWebScrollbarStyle](Design/NativeWebScrollbarStyle.swift) uses standard
`scrollbar-color` on supporting WebKit versions
([Safari 26.2 onward](https://webkit.org/blog/17640/webkit-features-for-safari-26-2/)),
retaining native fade, hit testing and live system scrollbar preferences. Thumb
color uses each element's actual `currentColor` without reducing its opacity.
This preserves text-level contrast on dark pages that omit `color-scheme`, where
`CanvasText` can still be black. The viewport uses the body's foreground because
pages commonly put their canvas colors on body rather than html. Root/body
class/style changes, body replacement and system color-scheme changes refresh
that viewport foreground. Viewport resize refreshes width/height media-query
changes; a scoped head observer handles stylesheet insertion/removal, text edits
and relevant link/style attributes. Captured stylesheet load events refresh
after resources (including delayed links and styles outside head) actually apply.
These signals share one pending 50ms refresh, without idle polling or an observer
over the entire body subtree. Unrelated head/body content changes do not read
computed style; unchanged colors do not write CSS, and the policy's own root
custom-property write does not schedule another read.
This tracks text contrast, not arbitrary image or
translucent-background contrast, and does not preserve a page's exact authored
thumb hue. A
constructed stylesheet works with restrictive inline-style CSPs and applies to
new overflow elements without walking their DOM. No overflow, wheel/key handler,
scroll offset, scrollbar width or page color scheme is changed. Page-authored
track backgrounds, borders and shadows are cleared. Older WebKit receives
transparent pseudo tracks and a visible fallback thumb; native overlay fading
is not guaranteed for that custom rendering path. Page-specific higher-priority
rules and shadow-root styles remain WebKit/page-owned boundaries.
The policy covers ordinary document/overflow CSS in each injected frame; it
does not force overrides into arbitrary shadow trees, canvas-drawn scrollbars or
higher-priority page rules. CSSOM-only rule edits, edits/removals of styles outside
head that emit no load event, and animated colors are not continuously sampled.

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
width across its own overflow threshold. Windowless
WebKit checks actual script injection, subframes, dynamic overflow, restrictive
CSP, geometry, both axes, textarea selection and dark/light foregrounds without
color-scheme, including body theme changes, real view resizes, stylesheet
insertion/edit/removal and deferred local CSS loading. Instrumented calls to the
real isolated-world `getComputedStyle` verify coalescing and that unrelated
content mutations do not trigger reads. It never
opens a window or changes system preferences. Headless Swift tests use
`MOKUSEI_TEST_HEADLESS=1`; display cases report skips, not passes. These checks
cannot certify rendered WebKit/overlay thumb pixels, hover/fade timing, actual
accessibility preference changes, the complete mounted application, focus/IME
behavior or physical mouse/trackpad feel.
Existing mounted composer, reading, Markdown, Settings, Git, Note and Browser
suites supply hosted graphical coverage; manual visual comparison with the
reference remains unperformed when only headless execution is allowed.

## Reading and execution disclosure

[Reading/NativeMarkdownView.swift](Reading/NativeMarkdownView.swift) renders message-level streaming content as literal selectable text only when no reading viewport is known. Mounted Thread timelines supply `nativeReadingPageCapacity`, so [Reading/NativeStreamingPage.swift](Reading/NativeStreamingPage.swift) instead holds the open page back until it closes. Streaming revisions do not enter the ordinary Markdown parser; a settled prefix is parsed at top-level block boundaries and published one page at a time. On settlement, rich rendering resumes; obsolete parsing results cannot replace a newer streaming revision. Completed messages remain rich even while another message in the turn is active.

A streaming page is the visible content height of the owning `HarnessMessageTimeline` (viewport minus its fixed top/bottom insets, in points). Only complete top-level blocks are parsed, so a page break can never fall inside a fenced code block, table, list, blockquote or indented code block; an atomic block that alone exceeds a page is revealed whole. The open page stays invisible until the next settled block would not fit (or its measured height already fills the page), and completion flushes the remainder after reparsing the whole source. The reparse resolves reference definitions and footnotes that point at later chunks; pages rebuild only when that whole-document result differs from the already displayed blocks. Flushes reuse `NativeReadingPageTiming.replacementAnimation` for the vertical page entrance and honor Reduce Motion. A message that is one unsplittable block (for example a single long list) therefore appears when that block closes or at completion; multiple chunks in one state update coalesce into one flush.

[Reading/NativeMarkdownParser.swift](Reading/NativeMarkdownParser.swift), [NativeMarkdownText.swift](Reading/NativeMarkdownText.swift) and [NativeMarkdownTypography.swift](Reading/NativeMarkdownTypography.swift) own parsing and native text layout. Inline-code URL links retain link actions and selection; tables derive height from laid-out content. Mermaid fences display source. Native selection uses the active reading selection palette consistently across blocks. Local absolute paths and local `file:` URLs render image syntax and add an inline preview below ordinary file links, while retaining native link actions. Local files bypass attachment resolvers and network loading; the composer ImageIO thumbnail loader decodes off the main actor (2048px maximum edge, 64MiB source limit). Text attachments fit the reading width and a 480pt height while preserving aspect ratio. Missing, unreadable and non-image sources retain their link/alternative text. Remote file hosts and executable URL schemes are rejected; relative paths have no inferred filesystem base. Local rasters live only with mounted Markdown blocks and refresh on remount.

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

[Conversation/ThreadConversation.swift](Conversation/ThreadConversation.swift) and [ThreadTimeline.swift](Conversation/ThreadTimeline.swift) organize reading from the Harness's public turn index. [ThreadDeferredExecution.swift](Conversation/ThreadDeferredExecution.swift) owns demand for settled execution bodies. Multiple disclosures share a turn resource; the last lease releases its payload. Explicit expansion mounts the full process rows, while a collapsed settled process retains its summary. Running/waiting content and pending interactions remain available.

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
Selecting history uses the existing scoped document and Back restores the retained
current scroll position. Thread history switches vertically according to TOC order:
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
Execution sidecards keep their single-execution presentation.
An external result request is the host route's entry document, so its Back and
Escape use that route's return action. It gains an internal history return only
after explicit TOC navigation. Each mounted row owns an independent content
handle, even when the retained current document and result render the same row;
closing one cannot revoke the other's content.

[ThreadReadingHeader.swift](Conversation/ThreadReadingHeader.swift) places the
mounted turn's resolved author under the title, beside execution/user-message
visibility controls. Narrow widths wrap the controls and truncate the visible
author while preserving its complete accessible label, tooltip and text selection.
The author comes from the actual Harness-rendered body, including runtime model
overrides; manifests cannot invent it. Completion time, duration and usage remain
in the footer. Inherited transcripts containing several turns retain each turn's
author locally. The [sidebar replay](../../../../../tools/verification/reading-presentation/README.md#thread-history-sidebar)
covers mounted navigation, author updates, long indices and responsive layout.

Remote Markdown images use URLSession HTTP caching and revalidation, with no process-wide URL-only body cache. New document loads therefore honor `Cache-Control: no-store`; mounted images retain their current raster. The streamed 24 MiB body limit and decoded pixel limit remain enforced.

## Cards, composer and forms

Shared Harness card components keep task identity, usage, plan and extension layout consistent. Plan rows have a native glass highlight only for an actual in-progress step; empty plans render no section. The emoji/follow-up control keeps a stable circular glass surface and native focus/action semantics. Loading-cloud palette is supplied by the Harness rather than selected by identity inside the renderer.

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

Composer state and submitted revision belong to the workspace. Attachment upload, file selection and send receipts are shared by the Dock and conversation surfaces. Form components validate the public typed interaction schema and send through injected actions rather than bypassing Runtime admission.

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
the CI manifest assigns it there instead of an ordinary Swift shard. It arms
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
must cover color, glass sampling, rounded clipping, camera transforms, exit
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

The mounted `NativeModelSelectorReplayTests` exercises real controls and bindings
for opaque IDs, disabled rows, keyboard cancellation, native slider actions,
reset, model navigation, catalog refresh and one-choice capabilities. Run `python3 tools/verification/reading-presentation/run.py --model-selector`
in the AppKit loop, alongside the existing `ClaudeSettingsControlReplayTests`
and Harness-form replay. The launcher retains light/dark model-list and
reasoning-panel renders under `.scratch/reading-presentation/NativeModelSelectorReplayTests`. These renders inspect component
pixels, not WindowServer shadow/compositing or physical pointer delivery.

`NativeModelSelectorHeadlessTests` also drives the production list, slider, reset
and model-navigation bindings without creating a window. It covers stale profile
callbacks and exact native IDs under `MOKUSEI_TEST_HEADLESS=1`; it does not replace
the popover opening/dismissal, focus or WindowServer replay above. Setting
`MOKUSEI_MODEL_SELECTOR_HEADLESS_ARTIFACTS` captures the unmounted production
content in both appearances without creating or ordering a window; popover
chrome, screen placement and compositing remain outside those renders.

## Compact configuration presentation

`nativeSettingsCompactPresentation` selects the presentation shared by onboarding
and Settings role panels for existing groups
and background-role configuration. `NativeSettingsReadiness` reports optional
readiness leases from mounted editors: no reporter is unknown; all reporters
must be ready. Each step owns its registry and unmounting removes the editor lease. Harness plugins report incomplete local model-dependent input, while the
Host separately reports resource availability. The parent consumes the current
step's readiness leases and rejects callbacks from departing pages. Settings and
onboarding share native field bindings, catalogs and persistence.
