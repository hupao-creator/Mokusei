# Shared native UI

This target supplies design resources, Harness cards, Markdown reading, conversation layout, composer and forms to the macOS application. AppKit adapts native text, input and viewport behavior within the Swift package.

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
[NativeComposerCaret](Composer/NativeComposerCaret.swift). Moku uses a solid
3-point caret with the native light/dark text color and native blink cadence.
Same-line movement interpolates over 120ms from the current presentation; repainting
an unchanged rectangle does not restart movement. There is no gradient or glow.

Marked text uses the native caret, and line changes bypass interpolation. Selection,
loss of focus, hidden windows and detachment release the layer. Reduce Motion makes
movement immediate while retaining the thicker mark and normal native blinking.
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
