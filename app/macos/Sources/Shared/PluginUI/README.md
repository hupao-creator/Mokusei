# Shared native UI

This target supplies design resources, Harness cards, Markdown reading, conversation layout, composer and forms to the macOS application. AppKit adapts native text, input and viewport behavior within the Swift package.

## Scrollbars

[NativeScrollView](Design/NativeScrollView.swift) is the opt-in SwiftUI viewport;
`NativeStyledScrollView` is its AppKit counterpart. Both use native mini scrollers
for the narrow, rounded, subdued appearance of the reference. The system owns
colors, hover/tracking, fade timing and accessibility rather than a custom thumb
or gesture. AppKit's preferred style preserves Always, When Scrolling and
Automatically based on input device, including live preference/device changes.
Always may reserve a native gutter; it intentionally takes priority over the
transient reference appearance. No global appearance, swizzling, window-wide
traversal, wheel monitor, preference write or replacement scroll-position model
is involved. Light/dark, Increase Contrast, Reduce Transparency and Reduce Motion
stay on the native rendering path; this component adds no animation.

The SwiftUI adapter is a noninteractive background **inside its own content**.
Do not attach it outside a viewport: nested code/table panes must configure their
own scroll view rather than the surrounding timeline. Existing `ScrollPosition`,
`ScrollViewReader`, geometry callbacks, bounce policies and enabled axes remain
at their callers. Explicitly hidden navigation/chip indicators stay hidden.

Inventory and integration boundaries:

| Owner | Scrollable surfaces | Integration |
| --- | --- | --- |
| Shared conversation | Timeline, activities, Markdown code and tables | SwiftUI wrapper; timeline diagnostics remain timeline-owned |
| Shared composer | Native multiline editor, attachment strip | AppKit subclass; attachment indicators remain hidden |
| Settings and shared selects | Main form, section strip, agent/error detail, native textareas, option and model menus | Wrapper/subclass only; bindings, validation and menu focus unchanged |
| Moku | Note (including short viewport), directory completion, Talk, dispatch details and interaction bodies | Wrapper; completion uses native drag/accessibility instead of its old custom thumb |
| Overview | Tag/filter navigation strips | Wrapper; existing hidden indicators and canvas input routing retained |
| Git | Worktree/file list, diff reader and synchronized horizontal code panes | Wrapper/subclass; line selection and horizontal synchronization remain owned by Git |
| Plugins | Report relations, OpenCode process, Browser annotation list and Voice transcript | Wrapper |
| WebKit Browser | Main document, subframes and page-owned overflow | Native WebKit; removed the injected transparent 2px CSS override. Page-authored styling remains page-owned |

Settings, the general model selector, Thread Detail TOC and Note are parallel
work areas. Changes here are limited to viewport construction and removal of
local style overrides; do not replace their page structure, state or navigation
when integrating. A new TOC/model menu should use the same wrapper or AppKit
subclass and retain its own selection/reveal logic. The baseline includes main's
Note history (#106) and Overview framing (#107).

Run `python3 tools/verification/scrollbars/run.py` from the repository root for
the windowless production AppKit boundary replay. It checks repeated configuration,
document/clip/scroller identity, selection and scroll offsets, native targets,
enabled axes, four appearances and preference-notification isolation. It never
opens a window or changes system preferences. Headless Swift tests use
`MOKUSEI_TEST_HEADLESS=1`; display cases report skips, not passes. These checks
cannot certify rendered thumb pixels, hover/fade timing, actual accessibility
preference changes, mounted SwiftUI geometry or physical mouse/trackpad feel.
Existing mounted composer, reading, Markdown, Settings, Git, Note and Browser
suites supply hosted graphical coverage; manual visual comparison with the
reference remains unperformed when only headless execution is allowed.

## Reading and execution disclosure

[Reading/NativeMarkdownView.swift](Reading/NativeMarkdownView.swift) renders message-level streaming content as literal selectable text. Streaming revisions do not enter the Markdown parser. On settlement, rich rendering resumes; obsolete parsing results cannot replace a newer streaming revision. Completed messages remain rich even while another message in the turn is active.

[Reading/NativeMarkdownParser.swift](Reading/NativeMarkdownParser.swift), [NativeMarkdownText.swift](Reading/NativeMarkdownText.swift) and [NativeMarkdownTypography.swift](Reading/NativeMarkdownTypography.swift) own parsing and native text layout. Inline-code URL links retain link actions and selection; tables derive height from laid-out content. Mermaid fences display source. Native selection uses the active reading selection palette consistently across blocks. Local absolute paths and local `file:` URLs render image syntax and add an inline preview below ordinary file links, while retaining native link actions. Local files bypass attachment resolvers and network loading; the composer ImageIO thumbnail loader decodes off the main actor (2048px maximum edge, 64MiB source limit). Text attachments fit the reading width and a 480pt height while preserving aspect ratio. Missing, unreadable and non-image sources retain their link/alternative text. Remote file hosts and executable URL schemes are rejected; relative paths have no inferred filesystem base. Local rasters live only with mounted Markdown blocks and refresh on remount.

Markdown source preprocessing preserves code characters and recognizes footnotes
before entity decoding; escaped syntax stays literal. Footnote labels use Unicode
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

Native text bindings compare UTF-16 code units so canonically equivalent Unicode replacements remain real draft edits.

`NativeComposerTextInput` optionally emphasizes its insertion mark through
[NativeComposerCaret](Composer/NativeComposerCaret.swift). Moku uses a
2.6-point rounded caret, sized to 25/24 of the text size and centered in the
native insertion rectangle. The core is white in dark appearance and uses native
ink in light appearance, with a warm-yellow upper halo and cool-blue lower halo.
The halo preserves the approved study’s blurred 16-point warm and 14-point cool
ellipses plus a 4.6-point gradient fringe. Halo widths and blur radii scale from
the study’s 25-point core to the editor’s actual caret height. The transparent glow image is rendered
once per caret height/backing scale and its opacity is animated by Core Animation;
no per-frame SwiftUI rendering or timer is needed. Emphasized editors place their
existing padding inside the native text viewport, preserving glyph positions while
leaving room for the glow before native scroll clipping.
Light ink stays at 80–100% opacity throughout the cycle for contrast; dark-mode
white ink breathes at 20–100%, while both halos fade fully.
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

There is no global Reduce Motion policy applied to every animation. The current [Moku Dock](../../Host/MokuScene/NativeMokuDock.swift) disables its surface/eye expansion animation when that preference is enabled; [Overview chrome](../../Host/Overview/NativeOverviewChrome.swift) separately handles tag/control transitions. Other animation paths follow their own implementation. Do not infer support or removal from an old blanket statement.

Window visibility, detachment, cancellation and explicit pause are separate lifecycle controls. Reduce Transparency fallbacks, contrast and accessibility labels are independently owned by the relevant views. [NativeCloudLoading.swift](Design/NativeCloudLoading.swift) and [NativeCloudField.swift](Design/NativeCloudField.swift) share the loading field and pause at zero visibility/intensity. [NativeVoiceCloud.swift](Design/NativeVoiceCloud.swift) consumes bounded voice visualization state without starting capture.

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

[NativeModelSelector](Forms/NativeModelSelector.swift) is the shared native capsule
and popover for Harness model choices. Its model list scrolls, marks the current
choice, preserves disabled rows and supports arrows, Home/End, Page Up/Down,
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
