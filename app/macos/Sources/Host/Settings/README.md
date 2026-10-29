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
| General | Appearance/language popups, glass world switch, Agent/install buttons, cancel and destructive clear buttons |
| Local Agent details | Harness defaults switches, fields, catalog menus and CLI refresh/retry buttons |
| Moku | Transparent coordinating Agent and dispatch-target icon buttons, execution fields, routing switch and text editor |
| Report and Tag | Onboarding inheritance/independent glass choices, Harness seats, native execution fields and live capability animations |

All controls keep their existing bindings, availability and pending/save/error
gates. System menu items carry option indexes separately from titles, preserving
duplicate display names and opaque UTF-16 option IDs. The interaction registry
keeps the same descriptors and discrete-change semantics.

The coordination and dispatch map retains the icon presentation from before
`016735c` (system Settings controls): transparent 48-point seats, hover surfaces
and keyboard focus rings. Targets use icons, selection underlines and dashed
paths rather than checkboxes. The last selected target remains fully opaque
while removal is disabled. General's Agent installation buttons and the other
Settings form controls retain their system presentation.

The reference-image model/effort selector is a separate component task. Its
integration points are the shared `NativeSettingsSelect`/`NativeSettingsSelectPopover`
entry and each Harness's model, thinking/effort or variant field in
`CodexSettings`, `ClaudeSettings`, `PiSettings` and `OpenCodeSettings`. This change
does not alter their catalog, default or dependent-choice mapping. Changes in
those Harness files here are confined to refresh/retry button presentation.

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
Unavailable selections, including the removed archive and plugin management
sections, fall back to General and normalize when the available sections change or the page mounts.
Thread archive data and commands remain independent of Settings.

Settings is an Overview-only modal expansion of the resident Moku Dock. The
same capsule grows toward a centered 780×680-point target, bounded by 24-point
horizontal and 56-point vertical viewport margins. Its expanded surface uses
untinted system regular glass without separate sidebar/content fills; Reduce
Transparency supplies a solid fallback. The resident character remains mounted
but hidden while Settings owns the full panel. A single
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
page lays out at its final size; closing fades its ink before glass contraction.
Reversals fence obsolete completions. Resize, inactivity, Reduce Motion and
explicit settling retire the current animation without leaving the modal gate
stuck. Opening and return both report transitioning to semantic callers.
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

Saves carry expected settings revision. Success adopts the normalized response as the new base while retaining later local edits. Conflicts reconcile against the returned latest state; an obsolete failed save does not discard or block a newer ready draft. Current failures remain visible. Local appearance/language and `glass world` persistence has its own path and works without a connected Runtime. The General → Interface preferences toggle keeps the exact `glass world` label in both languages and directly saves `DesktopPreferences.glassWorld`; it does not enter a Runtime draft. `desktop-preferences.json` stores `preferences.glassWorld`, defaults to true when missing, and preserves it during appearance, language and selected-thread writes. Atomic write failures retain the prior observed value and show the existing preference error notice. Interaction snapshots expose the saved Boolean as `settings.glassWorld`.

Moku displays its concrete saved execution profile. Background editors select inherited Moku configuration or an independent snapshot; switching back to inheritance retains the independent choice for later reuse. Moku, Report and Tag use their built-in system instructions; settings do not expose full system-prompt replacement. Moku routing guidance remains editable under Advanced settings; an existing enabled editor is expanded on entry, and invalid-field focus also expands it. There is no additional system-prompt setting. A running execution/batch retains its admitted profile. Plugin availability still limits application sections and the Moku Harness roster;
Settings no longer exposes plugin enablement or service-restart instructions.

The [landing setup demo](../../../../../demos/landing-setup/README.md) mounts the
same Moku coordination map with an in-memory settings model. Its `.compact`
presentation omits map labels. Settings also uses this map presentation and retains advanced routing guidance in a disclosure. Both presentations
use the historical circular avatar (`8f3548f`) with the same selection, handoff
and target feedback; the Settings page retains its native execution editors and saved values.

Changing the coordinating Harness is rejected through the existing save-error
path while Moku or any ordinary Agent Thread is busy, including pending input
and waiting interactions. Other settings remain editable. The selected Harness
inherits the existing note when the idle replacement is applied.

[SettingsDiagnostics](../../Core/SettingsDiagnostics.swift) records bounded operational fields and correlates client flow with command identity. Diagnostics do not contain submitted setting values and their failure does not fail a save.

Verification: `./scripts/go.sh run -race ./tools/verification/settings-shell` for Go boundaries; on macOS build a runtime with `make runtime`, then run `./scripts/go.sh run -race ./tools/verification/settings -runtime "$PWD/.build/go/mokusei-runtime"`. The launcher drives real Swift settings flows against an isolated daemon, including acquisition before page mount, cache reuse, concurrent readers and failed-read recovery. The same existing native flow mounts the production General page offline to verify the `glass world` binding, snapshot and JSON persistence, missing-field defaults, unrelated preference writes, and visible write failures. Set `MOKUSEI_GLASS_WORLD_ARTIFACTS` to capture its off-state Settings window through ScreenCaptureKit; this avoids stale layer-backed control frames from view-cache snapshots.

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

Escape cancels the focused model/reasoning selector's open native popover before
page navigation, without changing its value. The next Escape returns from Settings.
`NativeModelSelectorReplayTests` mounts the page Escape monitor and sends events
through NSApplication to cover this precedence, focus restoration and reopening.

The production [onboarding panel](../Onboarding/README.md) and Settings mount
the same `NativeRoleConfigurationPanel`, map, Harness fields and typed application
background editor. `nativeSettingsCompactPresentation` suppresses group explanations
and selects the inheritance/independent glass controls. Tag and Report keep their
production animations while configuration stays immediately available. Leaving
the tab unmounts and cancels its animation; inactive/hidden windows pause it and
Reduce Motion shows the completed composition. Settings has no onboarding progress
or admission steps. Onboarding alone omits advanced routing. `draft.flush()`
awaits accepted writes and rejects incomplete/composing/failed edits before a
step can finish. `flushForQuit()` retains its retired-draft semantics.
Harness editors report acquisition and incomplete local model choices through
`NativeSettingsReadiness`; the Host does not inspect provider fields.
