# First-run onboarding

`NativeOnboardingState` admits a new profile after the authoritative workspace
catalog and Moku shell load. It owns the discovery → Chief → Tag → Super Thread → Dock
sequence; the connected workspace continues to own installation discovery,
settings resources, draft validation and Runtime persistence.

A valid preexisting desktop preferences file or actual catalog activity skips
first-run setup. Settings revisions and prefetched execution snapshots do not
establish prior use. The profile stores an explicit pending marker before setup,
so restarting during setup preserves all saved choices and returns to discovery.
A pending marker takes priority over subsequently created history. Marker write
failures stay visible and retryable. Completion is written only after the last
settings flush succeeds; ordinary preference writes preserve that state.

The floating panel keeps the landing background and uses a neutral window
surface with untinted Liquid Glass controls. The panel, hosted controls, and
Tag and Super Thread animations inherit the system appearance. During the
noninteractive handoff, the contracting surface takes on the Dock's capsule
color. Discovery presents
Harnesses independently as checking installation, loading configuration, ready,
or failed with a Harness-specific retry. An executable alone is not discovered:
readiness joins the workspace's retained Moku execution and enabled independent
background-role resources for that Harness. Inherited roles join
Moku's exact resource, so readiness does not wait for unused application scopes.
Configuration prefetch begins after that Harness is confirmed installed, leaving
the shared queue available for other installation replies. Each Harness queues
its execution resources ahead of ordinary Thread defaults in the same batch,
without a phase barrier that holds defaults behind execution retries. Defaults
are not read by any subsequent onboarding page and do not gate discovery or its retry;
they continue warming separately for Settings. Harnesses without execution-host
capability still require their ordinary resource. This includes each plugin's decoded
model catalog, capabilities/options and nonempty saved execution snapshots.
Transport/decode failures, CLI failures and embedded catalog errors remain errors;
background retries are bounded (1 and 3 seconds) and never count as completion.
Codex/Pi/OpenCode require usable model catalogs; Claude supports custom model
identifiers and can legitimately have an empty advertised list. OpenCode waits
for the account phase that can still filter model availability, not usage telemetry.

The title counts only ready Harnesses and keeps discovery progress or partial
failure explicit. Continue requires at least one ready Moku-capable Harness and
does not wait for unrelated slow/failed Harnesses. It admits the current ready
roster into Moku and the role pickers; returning to discovery can admit newly
ready Harnesses. The admitted roster remains stable across execution-profile
saves, while each active editor still enforces its own readiness and validation.
The same cached, source-keyed surfaces supply the subsequent editors immediately;
page changes do not reload successful resources or reseed selected defaults.
Disabled roles need no execution resources until enabled; changing a saved source,
role mode or connection authority retains the ordinary targeted reload boundary.
Plugin-owned installation guides remain available for missing Harnesses. Moku reuses the
Settings coordination map and native Harness execution fields. Tag and Super Thread
reuse application-owned background configuration, including inheritance and
retained independent profiles. Provider catalogs, pending model choices and
validation remain in their native plugins. Model, reasoning and other select
fields use AppKit system popups through the compact presentation environment,
with the same option identities, disabled states and discrete-change bindings
as Settings. The shared readiness registry
combines resource acquisition and incomplete local input; IME, failed saves,
unavailable Harnesses and invalid fields prevent advancing.

Inherited Tag and Super Thread configuration displays the actual saved Moku profile
through the same read-only native Harness fields as Settings, including catalog
and resource status. It waits for resource readiness rather than treating the
presence of a saved profile as sufficient. Switching back to independent mode
restores its own retained configuration.

Tag and Super Thread share Settings' Agent off, Use Chief and Configure separately
choices. Turning a role off keeps its source mode and retained independent
profile, and bypasses that role's resource/availability gate. Selecting either
enabled choice restores the ordinary readiness gate. Existing reports, tags and
pending backend work are retained.

The Tag SpriteKit and Report SwiftUI sequences are abstract capability examples,
shared with Settings through `NativeRoleConfigurationPanel` and with the visual
demo. Role titles and subtitles are shown during onboarding. Each mounted Tag
or Super Thread page plays once with the discovered Harness logos and retains
its completed composition. Settings uses the same behavior
without onboarding step admission. Leaving the page cancels playback; entering
it again creates a new playback visit. Hiding or deactivating the window during
playback settles to the completed composition without replaying on activation.
Tag
also rebuilds a static final frame on size, appearance, locale or Harness changes
after playback starts, and pauses SpriteKit once that frame is rendered. Tag's
collision boundaries remain invisible. A native `SKView` adapter makes both the
view and its backing Metal layer nonopaque and clears the layer before presenting
the scene. This keeps tab entry transparent before SpriteKit's first drawable;
a clear scene background alone does not configure the native host. Ordinary
updates retain scene identity, and unmounting pauses and detaches it.
No native Tag-surface capture suite is configured in this source tree;
transparent host/layer state and playback lifecycle are production constraints,
not a claim of continuous-frame coverage.
The Super Thread illustration gathers dense documents into one landscape document.
Each of its three abstract figures sits directly above two placeholder lines.
The illustration has no visible text and exposes a single accessibility description.

The setup panel does not mount a hidden composer. Pointer, keyboard, semantic
navigation and direct presentation entry points remain gated. After persistence,
the panel fades its contents, contracts to the actual Dock geometry, and reveals
the real composer. In an active, visible window, the
resident eyes stay open through the 180ms final fade and blink once for 320ms
as the input box comes fully into view. Leaving the foreground or hiding
the face during either interval cancels the cue for
this handoff. The editor accepts input as soon as the handoff finishes.
See the [first-run handoff replay](../../../../../tools/e2e/README.md#first-run-handoff)
for the window capture procedure. The one-time marker is independent of empty-workspace landing:
archiving all conversations still restores landing without replaying setup.

The deterministic [visual demo](../../../../../demos/landing-setup/README.md)
uses the production surfaces with in-memory data. It does not establish Runtime
persistence, real discovery, focus, input or native-frame correctness. The
Settings e2e starts with onboarding complete. The
[verification policy](../../../../../scripts/ci/verification-policy.md) defines
validation ownership.

The Super Thread role uses the Super Thread Agent application settings label.
Onboarding progress keys and the `report.settings` binding preserve completed
onboarding and saved execution configuration.

The explicit App launch option `--benchmark-scenario overview` prepares an
isolated rendering experiment by recording completion before workspace creation.
It requires `--data-dir` and the opt-in automation socket. The external runner
does not navigate or measure this setup flow; ordinary launches retain the
first-run admission above. Scenario preparation does not alter rendering or
native Harness execution.

The Overview benchmark entry also requests a fixed 1280 × 820 initial window
and disables scene restoration for that explicit scenario. This removes saved
window geometry as a startup variable; the OS bounds remain externally verified.
