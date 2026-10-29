# Native settings

[NativeSettingsNavigation](NativeSettingsNavigation.swift) shares section selection
and the close gate between page controls and [semantic workspace actions](../Interaction/README.md).
Programmatic close and the global Overview command preserve IME protection,
invalid-field focus and save flushing. Quit waits for the pending valid save
before Runtime teardown; invalid or failed saves offer Keep Editing and Quit
Without Saving. The existing bounded cleanup deadline and repeated Quit remain
available.
The sidebar includes General, Moku and enabled application sections.
Unavailable selections, including the removed archive and plugin management
sections, fall back to General and normalize when the available sections change or the page mounts.
Thread archive data and commands remain independent of Settings.

The sidebar reuses `NativeWindowNavigationView`, the same top-left traffic-light
and back capsule used by Thread Detail. The sidebar has no separate Settings
title. Tabs start below the shared 74-point navigation safe area in both sidebar
and compact layouts. This space compensates for content zoom so tabs never move
under the fixed-size navigation capsule. Content uses the selected tab as its
page label without repeating it as a standalone heading; form group headings
remain visible. A title-free drag region reserves 28 points above the scroll area
in sidebar layouts and 8 points in compact layouts.
The page marks General, Moku and contributed application content as settings
forms. Shared group headings and regular field labels, including labels with
inline description hints, use 14-point type; descriptions, control values and
sidebar navigation retain their own typography. Compact local-agent detail labels
retain their smaller size.
The shared back target reports its actual
frame for the Settings return animation and calls the existing draft close gate. [The isolated native demo](../../../../../demos/settings-navigation/README.md)
links the production page and navigation for light/dark/compact and narrow English
and zoomed screenshots.

[NativeSettingsTransition](NativeSettingsTransition.swift) restores the button-anchored
circular reveal removed by the SwiftUI shell migration (`310149f1d`). The live
page keeps its final layout: opening uses the historical 480 ms emphasized curve
(`f670e94c6`), return uses 380 ms, and a missing source uses a 160 ms fade.
Source and back frames use logical `workspace` coordinates, including at content
zoom. Settings stays mounted and the underlying route stays inert until return
completes. Reversal fences obsolete completions; resize, scene inactivity,
Reduce Motion and explicit settling retire the current animation. Semantic
interaction snapshots report both opening and closing as transitioning.
Run `python3 tools/verification/reading-presentation/run.py --settings-transition`
for production-scene pixel and lifecycle checks at 1×/2× zoom, reverse, resize,
inactive, missing-source and explicit-settle cases. Reduce Motion is handled
in production but the replay does not change the system accessibility preference.

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

Moku displays its concrete saved execution profile. Background editors select inherited Moku configuration or an independent snapshot; switching back to inheritance retains the independent choice for later reuse. Moku, Report and Tag use their built-in system instructions; settings do not expose full system-prompt replacement. Moku routing guidance remains editable; there is no additional system-prompt setting. A running execution/batch retains its admitted profile. Plugin availability still limits application sections and the Moku Harness roster;
Settings no longer exposes plugin enablement or service-restart instructions.

The [landing setup demo](../../../../../demos/landing-setup/README.md) mounts the
same Moku coordination map with an in-memory settings model. Its `.setup`
presentation omits map labels and advanced routing guidance. Both presentations
use the historical circular avatar (`8f3548f`) with the same selection, handoff
and target feedback; the Settings page retains its default complete editor.

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
