# Native settings

Settings form controls use system SwiftUI/AppKit controls on the existing macOS
26 minimum. The page's `nativeSettingsFormPage` environment selects system
popups, rounded text/secure fields, switches, bordered action buttons and AppKit
plain text editors; embedded Thread editors retain their existing presentation.
Rows still own labels, descriptions and announced validation errors. Help buttons
open native popovers, and text editor height is adjusted with a keyboard-accessible
Stepper instead of a custom drag grip. Native text editing retains composition,
selection, Undo, label activation and the draft close/save gate.

| Settings surface | Native interactions |
| --- | --- |
| General | Appearance/language popups, Agent/install buttons, cancel and destructive clear buttons |
| Local Agent details | Harness defaults switches, fields, catalog menus and CLI refresh/retry buttons |
| Moku | Transparent coordinating Agent and dispatch-target icon buttons, execution fields, routing preset capsules and custom text editor |
| Report and Tag | Off/inherited/independent filled choices, Harness seats, native execution fields and live capability animations |

Report and Tag each expose three mutually exclusive choices: Agent off, Use
Moku and Configure separately, in both Settings and onboarding. A contextual
explanation remains visible below the choices. Off hides execution fields and
preserves both the underlying source mode and retained independent settings.
Selecting either enabled choice updates enablement and source in one draft
change; the first independent choice copies saved Moku settings only when no
independent settings have been retained. Selecting the current choice is a no-op.
Mode choices use the discrete-change save path rather than the text debounce,
while preserving composition and pending-save gates.
The save revokes active work and pauses automatic processing without removing
existing reports, tags or pending work. Re-enabling resumes after native cleanup.
The workspace does not prefetch execution resources for disabled roles. A
disabled role is ready to continue without an available execution profile.

Report and Tag show the saved Moku execution profile beside the inherited Agent
in both Settings and onboarding. The read-only details reuse the Harness's native
fields and catalog statuses, including model, reasoning and other execution
parameters. They join Moku's saved resource even while a role-mode save is pending,
so a retained independent profile cannot supply the inherited details or catalog.
Resource loading, errors and retry remain visible; retry stays enabled while
configuration fields are read-only. Missing/unavailable Agents and unready
resources prevent onboarding from advancing. Returning to independent mode keeps
its retained choices.

Each Settings opening gives Tag and Report independent animation visits. Once
playback starts, switching tabs and returning shows the completed composition;
closing and reopening Settings permits both animations to play again. An
interrupted playback settles to its final frame, and Reduce Motion consumes the
visit without playing. Onboarding retains its own step lifetime.

All controls keep their existing bindings, availability and pending/save/error
gates. System menu items carry option indexes separately from titles, preserving
duplicate display names and opaque UTF-16 option IDs. The interaction registry
preserves discrete-change semantics. Agent mode choices register as selected
actions (`off`, `inherit`, `independent`) rather than a separate enabled switch.

The shared role editor's inheritance and Harness choices define a capsule hit
shape inside each plain button label, after its full-width frame and surface.
The entire visible capsule, including the space beside its text, selects the
choice in both Settings and onboarding.
The shared choices retain their interactive capsule glass in Settings and
onboarding; selection, save gates and capability checks are unchanged.

The coordination and dispatch map retains the icon presentation from before
`016735c` (system Settings controls): transparent 48-point seats, hover surfaces
and keyboard focus rings. Targets use icons, selection underlines and dashed
paths rather than checkboxes. The last selected target remains fully opaque
while removal is disabled. General's Agent installation buttons and the other
Settings form controls retain their system presentation.

Settings and onboarding use the original animated eye character for every
coordinating Harness. Its vector body, idle motion, handoff and target-gaze
feedback are restored; no sphere artwork or fallback sphere gradient remains.

Model, thinking/effort and variant choices use the same AppKit `NSPopUpButton`
as other selects in Settings and onboarding, including compact role panels.
`NativeModelSelector` delegates to the system select in these environments;
Harness catalog, default and dependent-choice mapping remain at their callers.
Embedded Thread editors retain their capsule/popover presentation.

`NativeSettingsControlsReplayTests` mounts the shared production form and sends
AppKit actions through real controls, checking option identity/disabled state,
text binding and Undo. The existing Settings launcher below exercises persistence,
IME, conflict and close behavior; the navigation demo covers light/dark, compact
and zoomed production page layouts.

[NativeSettingsNavigation](NativeSettingsNavigation.swift) shares section selection
and the close gate between page controls and [semantic workspace actions](../Interaction/README.md).
Programmatic close and the global Overview command preserve IME protection,
invalid-field focus and save flushing. Quit waits for the pending valid save
before Runtime teardown; invalid or failed saves offer Keep Editing and Quit
Without Saving. The existing bounded cleanup deadline and repeated Quit remain
available.
The horizontal header includes General, Moku, Tag and Report in that order, followed by any other enabled application sections. Native tab semantics, a selected underline and roving keyboard focus are shared at every width; the header scrolls when its tabs no longer fit.
Switching sections scrolls the whole padded form to its top, retaining the same
18-point title inset whether the selected form fits or overflows. At extreme
zoom the outer shell scrolls back to its top as well. Form width follows the
panel rather than SwiftUI's overflow-dependent scroller proposal, keeping its
560-point column centered on the same axis with or without overflow. Horizontal
padding keeps controls clear of the native gutter. The title and subtitle wrap
to their natural height in narrow windows and either language; they remain part
of the scrolling content.
Unavailable selections, including the removed archive and plugin management
sections, fall back to General and normalize when the available sections change or the page mounts.
Thread archive data and commands remain independent of Settings.

The expanded surface and page retain their fixed dark appearance in light,
dark and system workspaces. This is a local environment override; the workspace
appearance preference and other windows retain their existing ownership.

Settings is an Overview-only modal expansion of the resident Moku Dock. The
same capsule grows toward a centered 780-point-wide surface, starting at a
900-point preferred height and growing with the active form, bounded by 24-point
viewport margins. Its expanded surface uses the opaque native
`NSColor.windowBackgroundColor` in the panel’s fixed dark appearance, with no tint
or Liquid Glass. The same readable fill is used with Reduce Transparency.
The resident eyes travel into the reserved leading 30-point header column and
return to the composer with the shell. A single
Close button replaces the full-page traffic-light/back capsule and its 74-point
safe area; the main window retains its own native controls. When extreme zoom
leaves less than 220 logical points of page height, the entire settings shell
also scrolls so its fixed chrome cannot make form controls unreachable.

The scene blurs Overview and blocks pointer, keyboard and accessibility access
until the capsule finishes returning. Close, Escape and backdrop click share
`NativeSettingsNavigation`'s draft gate; backdrop clicks never reach Overview.
Native menus, IME and Agent details retain their Escape priority. Input and Note
visits remain retained beneath Settings, including draft and reading position.
Incoming messages and interventions cannot replace Settings. On release, a
pending intervention takes its ordinary priority over a retained Note/composer.

`NativeSettingsTransition` owns the 420 ms capsule transition lifetime. The live
page lays out at its final size; closing fades its ink before panel contraction.
Reversals fence obsolete completions. Resize, inactivity, Reduce Motion and
explicit settling retire the current animation without leaving the modal gate
stuck. Opening and return both report transitioning to semantic callers.
Reduce Motion settles the shell directly.
`python3 tools/verification/reading-presentation/run.py --settings-transition`
mounts the production Dock and Settings page for viewport/zoom/landing, backdrop
blur and click-through, restoration, interruption and lifecycle regression checks.
The runner captures representative panel screenshots with its evidence.

The application menu and Cmd+, are enabled only for a loaded Overview. Direct
presentation and semantic requests enforce the same boundary; reading, Moku
history and initial connection/recovery pages cannot open Settings or implicitly
navigate to Overview. A previously loaded Overview can still edit local
preferences while disconnected.

[NativeSettingsModel](NativeSettingsModel.swift) loads public settings and Harness presentation. [NativeSettingsDraft](NativeSettingsDraft.swift) keeps editable, ready and committed state separately. Page, control and native text-editor adapters present that state; the [Runtime](../../../../../internal/core/runtime/README.md#settings) remains persistence and validation authority.

Text edits debounce with IME protection; complete option changes can save immediately. Incomplete model-dependent choices remain visible locally instead of submitting guessed defaults. Changing model/provider updates dependent options together using the advertised schema. Opening initialized settings reuses saved execution profiles; explicit refresh reloads native catalog facts.

Returning a local draft to its saved value adopts any newer streamed settings
without issuing a redundant write. Persisted routing guidance is normalized,
while the nonempty editor retains its exact text and native Undo ranges after
autosave. Equivalent saved text still adopts unrelated streamed settings without
an unnecessary write. Later typing and an enabled empty routing editor remain
intact when unrelated fields save. Saving a change from nonempty guidance to
empty text still stores null and closes the editor.

Claude uses the shared Settings group, defaults toggle, model/effort/permission
selects and CLI status. Its model menu retains a custom-identifier choice for
native aliases and models outside the advertised catalog; selecting a catalog
model still updates dependent effort choices as one draft group. An uninitialized
execution profile displays loading status until native discovery returns.
Unknown thinking capabilities show a warning and defer execution-profile effort
confirmation to native `get_settings` during save. Only advertised effort-based
models require an effort choice before submitting the draft. Known unsupported
choices, disabled models and native applied-value mismatches still reject saves.

The connected workspace starts installation discovery and prefetches the real
typed settings resources before Settings opens. Enabled Harness defaults, Moku
execution profiles and registered background-configuration application scopes
load through the Core client's bounded discovery admission (four active reads,
one per Harness). Slow native discovery does not occupy every Runtime command
slot or prevent unrelated Harnesses from loading. Page/Harness selection shares
an in-flight read and reuses successful resources across mounts; thread editors retain their own lifetime.
Saved source changes reload only the affected resource. Removed scopes/cwds,
installation changes, disconnect, authority replacement and full reload retire
the corresponding cache. Draft edits and unrelated streamed revisions do not.
Background failures retry after 1 and 3 seconds, then retain the error for the
editor's retry/refresh. Execution-snapshot errors also remain retryable even
when the native presentation itself loaded. No background retry loop runs
indefinitely. Closing Settings leaves workspace acquisition running.

Installation discovery distinguishes not-yet-loaded, initial loading, successful
(including empty) and failed reads. Moku shows a compact native progress notice
until the roster is known, rather than an empty dispatch diagram or premature
provider validation. Empty rosters point to General for installation; failed or
partially failed detection exposes a retry action and the detection error. Only
a successful roster can establish that a saved provider is unavailable. Periodic
refreshes keep a successful roster visible. Stopping discovery cancels its probe
and fences late completions so reconnect/reload can start a fresh read.

The shared Harness editor also shows native progress during initial acquisition.
Read failures take precedence over an allocated surface and expose retry;
execution-snapshot failures do not also claim that the profile is merely unpinned.
Harness-owned refresh/status controls remain responsible for their catalog states.
The native settings replay mounts these production controls across loading,
failure/retry, empty, ready and invalid-provider states, and recovers a mounted
Harness editor after a real HTTP read failure.

The page's shared text-editing scope aggregates composition by editor owner.
Both Moku and contributed application textareas report native marked-text
lifecycle directly, including when their window is not the key window. Ending
or unmounting one editor releases only that editor's composition; unrelated
text-field notifications cannot clear another editor's close/save gate.

Saves carry expected settings revision. Success adopts the normalized response as the new base while retaining later local edits. Conflicts reconcile against the returned latest state; an obsolete failed save does not discard or block a newer ready draft. Current failures remain visible. Local appearance/language persistence has its own path and works without a connected Runtime. General → Interface preferences saves `DesktopPreferences` directly without entering a Runtime draft. `desktop-preferences.json` stores `preferences.appearance` and `preferences.locale`; updates retain selection and onboarding state. Atomic write failures retain the prior observed value and show the existing preference error notice. Interaction snapshots expose the saved values as `settings.appearance` and `settings.locale`.

Moku displays its concrete saved execution profile. Background editors select inherited Moku configuration or an independent snapshot; switching back to inheritance retains the independent choice for later reuse. Moku, Report and Tag use their built-in system instructions; settings do not expose full system-prompt replacement. Moku's “Model selection preferences” (模型选择偏好) offers Economy, Balanced,
Performance and Custom separate capsule buttons after its basic execution fields
and before Advanced options, including the complete Custom guidance editor.
Moku rows use 12pt vertical padding instead of the default 15pt; label hierarchy,
advanced disclosure padding and description spacing retain their existing metrics.
The Custom editor draws an adaptive Settings border with accent focus and danger
validation states, retaining native text editing and focus-ring behavior.
They reuse the role-mode choice style, show a checkmark on the selected item and
wrap into fewer columns as the window narrows. Chinese and English explanations
refer only to cost-effective and frontier models; concrete model names and routing
guidance remain owned by Runtime. The saved
`moku.routingPreset` activates native-catalog-based guidance on the next Moku
execution. Custom/omitted restores the separately retained `moku.routingGuidance`
text editor; existing manual settings open as Custom. Selecting a preset and
switching interface language never replaces that text. Tabs use discrete
save semantics, retain keyboard/accessibility selection, and localize through
`DesktopLocale` in Chinese and English. Custom text keeps its existing validation,
composition, autosave and close-flush behavior. Runtime owns the model mapping
and injects only candidates from the captured selected Harness catalogs; see
[model routing policy](../../../../../internal/services/moku/README.md#model-routing-preferences).
`NativeModelRoutingPreferencesTests` mounts the real capsule controls and saves
through the production draft to verify restoration and language changes. A running execution/batch retains its admitted profile. Plugin availability still limits application sections and the Moku Harness roster;
Settings no longer exposes plugin enablement or service-restart instructions.

The [landing setup demo](../../../../../demos/landing-setup/README.md) mounts the
same Moku coordination map with an in-memory settings model. Its `.compact`
presentation omits map labels and model selection preferences. Settings also uses this map presentation and shows the four model preference choices directly. Both presentations
use the historical circular avatar (`8f3548f`) with the same selection, handoff
and target feedback; the Settings page retains its native execution editors and saved values.

Changing the coordinating Harness is rejected through the existing save-error
path while Moku or any ordinary Agent Thread is busy, including pending input
and waiting interactions. Other settings remain editable. The selected Harness
inherits the existing note when the idle replacement is applied.

[SettingsDiagnostics](../../Core/SettingsDiagnostics.swift) records bounded operational fields and correlates client flow with command identity. Diagnostics do not contain submitted setting values and their failure does not fail a save.

Verification: `./scripts/go.sh run -race ./tools/verification/settings-shell` for Go boundaries; on macOS build a runtime with `make runtime`, then run `./scripts/go.sh run -race ./tools/verification/settings -runtime "$PWD/.build/go/mokusei-runtime"`. The launcher drives real Swift settings flows against an isolated daemon, including acquisition before page mount, cache reuse, concurrent readers and failed-read recovery. The same native flow mounts the production General page offline to verify appearance/language controls, snapshot and JSON persistence, new-profile defaults, selection/onboarding preservation, and visible write failures with recovery.

The launcher leaves execution profiles uninitialized until native workspace
acquisition. `transport -swift-settings-capacity` additionally replays the full
four-Harness cold burst through the real Swift client and Go HTTP admission,
including slow discovery, ordinary command headroom and cancellation.

`NativeSettingsNavigation` owns the opt-in interaction registry and Settings visit
identity. The page supplies its current section and render refresh to mounted
controls. Controls register their real bindings/native editor callbacks through
[NativeSettingsInteractions](../../Shared/PluginUI/Forms/NativeSettingsInteractions.swift).
Handles expire when their owner, descriptor, visit, section or refresh changes;
detached controls unregister by owner. This preserves model/provider dependency
logic, IME, validation and autosave for script-driven chaos testing. Notices and
save metadata are observable, with Runtime public state as the persistence oracle.
Run `python3 tools/verification/native-interaction/settings.py` from the repository
root to exercise the production app's internal Settings controls across fresh
seeded profiles and app/Runtime restarts.

Automatic installation checks request each Harness independently. A completed
row becomes usable while slower rows remain checking; an available Moku host's
editor is not blocked by unrelated installation discovery. Periodic/activation
checks do not force environment invalidation. Explicit recovery and installation
still refresh the environment. Generation checks fence late replies after reload
or disconnect. These reads never change the settings draft.

Workspace-owned settings prefetch revalidates retained editors every five minutes
without forcing native cache invalidation; this refreshes capabilities even when
installation paths stay unchanged. OpenCode can return a native catalog before
optional account checks complete: it labels that uncertainty and rereads without
forcing another probe. No settings navigation or Map layout is changed.

AppKit owns the system select's menu tracking, keyboard navigation and cancellation.
Settings keeps its existing page Escape handler; embedded model popovers retain
`NativeSettingsEscapeCancelling` for document-level navigation.

The production [onboarding panel](../Onboarding/README.md) and Settings mount
the same `NativeRoleConfigurationPanel`, map, Harness fields and typed application
background editor. `nativeSettingsCompactPresentation` suppresses group explanations
while the background editor keeps its three mode choices and contextual
explanation. Tag and Report keep their production animations while configuration stays immediately available. Each tab
visit plays once and retains its completed composition. Leaving the tab unmounts
and cancels its animation; inactive/hidden windows settle an interrupted playback
to the final frame without replaying on activation. Reduce Motion shows the
completed composition without deferred playback. Tag pauses SpriteKit after
rendering its final frame. Settings has no onboarding progress
or admission steps. Onboarding alone omits model selection preferences. `draft.flush()`
awaits accepted writes and rejects incomplete/composing/failed edits before a
step can finish. `flushForQuit()` retains its retired-draft semantics.
Harness editors report acquisition and incomplete local model choices through
`NativeSettingsReadiness`; the Host does not inspect provider fields.

Settings starts with a 900-point preferred height and grows to the active tab's
natural document height (including header and form insets). The shared Dock shell
keeps its 780-point preferred width and caps both dimensions to the workspace
viewport with 24-point margins. General, Moku, Tag and Report use this same sizing,
including inherited and independent Harness forms. Smaller windows, app zoom,
expanded editors and notices retain native scrolling; extreme zoom also scrolls
the whole shell so navigation remains accessible. No scrollbar is hidden to fit
content.

Attention uses the standard background configuration editor for enablement, inherited Moku configuration and an independent execution profile. Its wake intervals and visible-thread threshold are product constants.


The former Report Agent section is named **Super Thread Agent**. Its existing
`report.settings` identity, inherited/independent choices and enabled state are
unchanged; reopening Settings requires no preference migration.

All Harness advanced-options headers retain the native disclosure, with a
full-width label and 32-point minimum hit height. Title, chevron and trailing space toggle the same
disclosure; native keyboard activation, localized expanded state, disabled gates
and the semantic interaction binding remain available. Collapsing retains values.
