# First-run onboarding

`NativeOnboardingState` admits a new profile after the authoritative workspace
catalog and Moku shell load. It owns the discovery → Moku → Tag → Report → Dock
sequence; the connected workspace continues to own installation discovery,
settings resources, draft validation and Runtime persistence.

A valid preexisting desktop preferences file or actual catalog activity skips
first-run setup. Settings revisions and prefetched execution snapshots do not
establish prior use. The profile stores an explicit pending marker before setup,
so restarting during setup preserves all saved choices and returns to discovery.
A pending marker takes priority over subsequently created history. Marker write
failures stay visible and retryable. Completion is written only after the last
settings flush succeeds; ordinary preference writes preserve that state.

The floating panel keeps the existing landing background and uses an opaque
neutral reading surface with untinted Liquid Glass controls. Discovery presents
installed Harness logos or plugin-owned installation guides. Moku reuses the
Settings coordination map and native Harness execution fields. Tag and Report
reuse application-owned background configuration, including inheritance and
retained independent profiles. Provider catalogs, pending model choices and
validation remain in their native plugins. The shared readiness registry
combines resource acquisition and incomplete local input; IME, failed saves,
unavailable Harnesses and invalid fields prevent advancing.

The Tag SpriteKit and Report SwiftUI sequences are abstract capability examples,
shared with Settings through `NativeRoleConfigurationPanel` and with the visual
demo. Each mounted Tag or Report page plays once with the discovered Harness
logos and retains its completed composition. Settings uses the same behavior
without onboarding step admission. Leaving the page cancels playback; entering
it again creates a new playback visit. Hiding or deactivating the window during
playback settles to the completed composition without replaying on activation.
Reduce Motion shows the completed composition without deferred playback. Tag
also rebuilds a static final frame on size, appearance, locale or Harness changes
after playback starts, and pauses SpriteKit once that frame is rendered. Tag's
collision boundaries remain invisible. Report gathers dense documents into one
landscape document containing three abstract figures; it is not a report template.

The setup panel does not mount a hidden composer. Pointer, keyboard, semantic
navigation and direct presentation entry points remain gated. After persistence,
the panel fades its contents, contracts to the actual Dock geometry, and reveals
the real composer. The one-time marker is independent of empty-workspace landing:
archiving all conversations still restores landing without replaying setup.

Verification uses the mounted `NativeMokuLandingTests` for hydration, admission,
interruption and marker errors. `NativeOnboardingUserFlow` extends the existing
Go-backed Settings flow with real discovery/resources, independent and inherited
role settings, Back, failed completion persistence and actual Dock handoff:

```sh
make runtime
./scripts/go.sh run -race ./tools/verification/settings -runtime "$PWD/.build/go/mokusei-runtime"
python3 tools/verification/reading-presentation/run.py --moku-landing
```

The deterministic [visual demo](../../../../../demos/landing-setup/README.md)
remains available for appearance and animation review. The production settings
flow, rather than its fixture controls, certifies Runtime persistence. Startup
and navigation changes also require the signed production package checks in the
[verification policy](../../../../../scripts/ci/verification-policy.md).
