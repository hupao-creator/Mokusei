# Desktop interaction verification

This runner checks **interaction input → real system → user-observable state**.
Overview, Reading, Settings and Collection use the opt-in
[native automation protocol](../native-interaction/README.md), with real Swift
UI, Runtime, authenticated HTTP/NDJSON, persistence and native Codex processes.
Composer uses an explicit operator-assisted system Accessibility/input path; the
runner independently checks its public persisted inputs, output and interruption.
It does not link reducers or instantiate fixture views. Runtime setup and public
content reads establish prerequisites and independent result evidence; they are
not counted as interaction coverage. Runtime invariants belong to PBT; UX timing,
resource use and visual-performance measurements belong to benchmarks.

## Current scenario contract

[scenarios.json](scenarios.json) is the executable inventory. IDs remain stable
across wording changes; changing a scenario's meaning requires a new ID. Each
entry names its owning module doc and required evidence files. A report always
contains every requested ID, including blocked and unreached entries.

| ID | Implemented interaction and criterion | Prerequisite / evidence | Coverage boundary |
| --- | --- | --- | --- |
| `E2E-OVERVIEW-001` | Observe a mounted task at 1×, pan by (+48, −90)pt, and restore the center of all card placements. Cell spans and window clearances determine the expected coordinates. | One task in the default suite, two tasks and eight reports in the Collection suite. The automatic, panned and recentered snapshots record the three poses. | Semantic camera actions and mounted identity. Pointer hit testing and drawn pixels need separate evidence. |
| `E2E-READ-001` | Open the prepared Agent from Overview; observe its ready, nonempty mounted turn; deliver an external follow-up; observe its mounted successor; activate the first history entry; Back returns to the successor; Overview closes the reader | Fresh profile, real Codex directory, settled source reply; `creation.json`, scoped content, `ui-initial/current/history/return/overview.json`, `ui-events.jsonl` | Navigation callbacks, content acquisition and mounted turn identity; HTTP follow-up input, not composer submission. Semantic readiness is not proof of exact rendered pixels or text layout |
| `E2E-SETTINGS-001` | Open Settings with Chief selected and only Chief, Tag and Super Thread available; activate an unselected `routingPreset` capsule; close through the save gate; read the exact saved preset through public Runtime state; reopen on Chief and observe it selected | Same isolated connected workspace; `settings-before/edited/persisted/reopened.json`, UI operations and public API receipts | Default navigation and the binding/draft/transport/persistence/reopen path for one preset; IME, keyboard, pointer hit-testing, errors/conflicts and system presentation need separate evidence |
| `E2E-COLLECTION-001` | Open a grouped member, return, then revisit and read. Switch directory and archive/restore unrelated reports while All remains mounted. | Two isolated directories, two completed tasks and eight reports from a deterministic peer. | The 18-cell All groups two fresh reports. A nine-cell directory releases them. A brief visit holds the cover, a qualified visit promotes the report, and the group releases when the expanded view reaches 14 cells. |
| `E2E-COMPOSER-001` | Type a follow-up and activate the actual Send button; observe accepted draft clearing and completed output; send a held task, observe Stop in the empty action seat, activate it and observe interruption and an editable empty composer without navigating away | Exclusive desktop, accessible isolated bundle, external operator; `operator-send/stop.json` AX observations, exact persisted prompts, `composer-send-content/oracle/ui.json`, `composer-running/stopped/stop-content/stop-ui.json` | Operator-assisted OS input, not unattended CI; current ordinary Thread text input and cancellation only, not pause/resume, historical forks, IME or uncertain receipt recovery |

The implemented desktop scenarios require execution evidence before they can be
called verified. Source inspection and a successful preparation do not certify
them. The runner emits the actual status, revision and evidence for each attempt;
there is no repository-wide "covered" flag. Current implementation supports
Codex only and deterministic text without attachments. The collection scenario
uses two ordinary Threads, the other scenarios one.
Reading uses two completed executions; Composer adds one completed follow-up and
one interrupted execution. Real provider behavior/authentication, other Harnesses,
forks, archive button input, reconnect/restart recovery and cancellation invariants are not
certified by these scenarios.

### System appearance and language

Use a private profile and a disposable macOS session for system-wide setting
changes. The [native app contract](../../app/macos/README.md#system-appearance-and-language)
owns resolution, profile compatibility and window appearance.

1. Launch into a fresh profile and inspect onboarding and menus. Repeat with a
   profile containing saved `preferences.appearance` and `preferences.locale`
   opposite to the system settings. Check that this profile keeps its onboarding
   marker, selection and reading records across a normal write and relaunch.
2. Cover Chinese with different scripts and regions, English with different
   regions, and a different primary language with Chinese second. Inspect the
   visible language and `snapshot.settings.locale`, including after changing the
   preferred order while Chief is running. Check the profile's output locale
   receipt before starting a generated-output operation.
3. Open Settings from loaded Overview and confirm Chief is selected and the
   available tabs are Chief, Tag and Super Thread. Select another tab, close
   Settings, and reopen on Chief. Repeat the open on a previously loaded Overview
   while disconnected.
4. Change macOS Appearance from Light to Dark and back with Overview, a reader
   and an attachment preview open. Record effective appearance in the snapshot
   and capture each window. Repeat with the same Settings visit and the same
   first-run form mounted. Check that the form backgrounds and controls follow
   the new appearance without changing the active tab or setup step.
5. With an installed, enabled agent, compare the Chief map and the Tag and
   Super Thread animation backdrops in both appearances. Capture the animations
   during playback and after switching away and back. Check that the role mode
   controls below them remain clickable and that Reduce Transparency uses the
   opaque fallback. See the [Settings backdrop and playback contract](../../app/macos/Sources/Host/Settings/README.md).

Keep the revision, primary language order, appearance, profile fixture, launch
mode and before/after observations with each run. A process-local simulation
covers only its injected inputs. It cannot certify macOS notifications or all
window pixels.

### Custom task orchestration editor

Open **Chief → Task Orchestration Preferences → Custom** in Settings. Verify
the title and hint in English and Simplified Chinese. In light and dark
appearance, capture the empty editor before and after focus. The rounded
glass has the same border in both states. Type the first words of the hint,
return the insertion point to the start of the line, and compare the first text
origin, baseline and insertion position with the empty frame. At narrow widths,
compare the hint and the same text typed into the editor across wrapped lines.
Delete the text and check that the entire hint returns with the same padding.
Repeat with Reduce Transparency and check for an opaque editor with a neutral
outline. Check that an invalid draft shows the danger outline on and off focus.
Compare same-line typing and Return with Chief's composer. The insertion point
eases along a line and moves directly to a new line. Select text and move focus
away to check that the glow clears.

Enter multiline text, replace and undo a selection, and scroll within the field.
Check that the text and selection share the inset as lines scroll in and out.
Check that macOS exposes a labeled multiline editor with the current value and
selection. With a system input method, start composing and cancel or commit the
marked text. Check that composition uses the native caret and that Escape during
composition leaves Settings open. Switch presets and return to Custom, then
close and reopen Settings and compare the exact text with the saved
`moku.routingGuidance`. Record the revision, appearance, input method, editor
observations and saved value. The [Settings preview](../../demos/settings-navigation/README.md)
can check the mounted editor with an in-memory save. Runtime persistence requires
an isolated connected workspace. `E2E-SETTINGS-001` exercises preset persistence.

### Super Thread reading regression

The [Markdown layout contract](../../design/markdown.md) also applies to the
related-execution sidebar. This local desktop replay needs the native Report
reader and system scroll input. The `supported` suite covers navigation in the
ordinary Thread reader.

In a private profile, prepare two completed Threads in one directory and link
both from one Super Thread. Open that report from Overview and activate the
target row in **Related executions**. Verify the selected execution against
its public scoped reply. Direct the input into the right-hand text column
while the report stays open. Include downward scrolling and a reversal with
momentum. Record the timeline offset, content height, viewport and time for
the next UI request after each gesture. A five-second request timeout fails
this replay. For a short, settled text fixture, the extent at a fixed width
must stay constant and the offset must travel in both directions.

For a long fixture, the [128 KiB mixed Markdown corpus](../benchmarks/reading/corpus.py)
provides identifiable first and last blocks. Check first entry, scrolling to
the final marker, scrolling back through visited sections, native text
selection after leaving a section and returning, narrow-window reflow, Back
to the related list and re-entry. First visits can refine the reserved heights.
After traversing the full document at one width, reversing through it should
retain the measured extent. Record the app and fixture digests, each input,
the original timeout and sample when present, and the isolated cleanup receipt.
Mounted readiness and UI request times measure different events from display
frame times.

### Agent history composer

Use an isolated profile with an ordinary Agent Thread and at least three
runs. After the input below the current run settles, select an earlier run
from Conversation contents, select another earlier run, and return to current.
Check the visible run in each direction, including when returning to the first
historical selection. Use distinct drafts to check that input follows the
selected run and that selection leaves focus with the reader. The mounted
history controls use the same navigation callbacks as the rail.

For the [composer geometry contract](../../design/composer.md#geometry-and-surfaces),
record the isolated window during each selection. Check intermediate frames at
fixed window size with empty drafts. The glass must stay expanded and the
Harness mark must remain visible. Compare each frame's horizontal center and
width to the settled bar at the same column, allowing for capture and edge
detection precision. With a running execution in an open Execution sidecard,
switch between historical runs in the main pane and check the same geometry.
When the destination actually changes columns, check for direct travel between
the two settled centers. Repeat at ordinary and narrow window sizes in English
and Simplified Chinese. Record the build identity, observed sizes, language,
events, frame samples and capture limitations. `E2E-READ-001` checks mounted
navigation, while the window recording supplies the geometry evidence.

## Fact sources

Expectations follow these current production contracts, not removed replays:

- [Moku creation](../../internal/services/moku/README.md#e2e-preparation):
  `context.go` validates a nonempty enumerated directory; `tools.go` admits
  `create_thread`. Tool success is admission, so preparation separately awaits
  completed output.
- [Runtime input/content](../../internal/core/runtime/README.md#e2e-observation):
  `commands.go` receives `thread:follow-up`; scoped content is the authoritative
  independent output read. No database writes or internal log reads occur.
- [Mounted interactions](../../app/macos/Sources/Host/Interaction/README.md#e2e-contract):
  `NativeWorkspaceInteraction.swift`, `NativeReadingInteraction.swift`,
  `ThreadDetailTurn.swift` and `ThreadHistorySidebar.swift` own the observed
  route, execution, row and control identities.
- [Settings](../../app/macos/Sources/Host/Settings/README.md#e2e-contract):
  `NativeModelRoutingPreferences.swift` registers four preset actions;
  `NativeSettingsDraft.swift` and `NativeSettingsNavigation.swift` own save/close.

## Build and run

Python 3.10+, the pinned Go toolchain, macOS 26/Xcode with Metal, and a usable
native Codex CLI are prerequisites. No real provider account is required.
Build receipts bind both binaries to the production source digest and record
their SHA-256. A stale or missing receipt blocks the run. `--go` accepts the local
pinned wrapper or CI's `go`; build failures remain nonzero.

```sh
python3 tools/e2e/build.py --go ./scripts/go.sh --with-app

# No GUI. A ready preparation still exits 2: interactions remain unverified.
python3 tools/e2e/run.py run --runtime .build/e2e/mokusei-runtime \
  --prepare-only --output output/e2e/preparation

# Arrange an exclusive desktop slot first. All desktop users must agree on this lock.
python3 tools/e2e/run.py run --runtime .build/e2e/mokusei-runtime \
  --app app/macos/.build/debug/Mokusei \
  --desktop-lease /private/tmp/mokusei-ui-verification.lock \
  --desktop-owner YOUR_COORDINATOR_THREAD_ID \
  --output output/e2e/interaction

python3 tools/e2e/run.py list
python3 tools/e2e/run.py verify output/e2e/interaction
```

Output directories must be new; no rerun overwrites evidence. The default
`supported` suite requests Overview, Reading and Settings. Use `--suite collection` on the
same run command to check the populated camera and the report budget under its real clock. It enables
the isolated Super Thread Agent, activates the uniquely bundled test application and waits for the mounted reader to own foreground before timing visits.
`all` additionally requests collection and Composer. Composer requires `--operator-composer` and real external
input receipts. `--suite composer` selects just that scenario. No scenario is
silently skipped. The desktop lease uses atomic directory creation, records
threadId/pid/start/nonce, and refuses any existing lock (including an unresolved
stale lock). It remains held until App and Runtime teardown; cleanup removes only
the matching directory inode and owner. It coordinates cooperating runners, not unrelated apps;
manual shared-desktop scheduling remains necessary. The App's existing explicit
`--benchmark-scenario overview` prepares onboarding in the fresh profile; it
does not certify first-run onboarding.

### Collection member opening

The automated Collection journey opens a member by semantic target. To check
the mounted grid, use the journey's populated, isolated workspace. Open the
collection's page count, then activate the same visible member in separate runs
with a pointer click and Accessibility Press. Record the window through reader
arrival. Verify the report identity and title, and check that the cover grows
toward the panel center across intermediate frames. Close the reader and check
which cover is selected on Overview. Repeat with Reduce Motion and check that
the grid zoom and crossfade are absent. Record any reader loading state and
whether Reduce Motion came from the system setting or a replay-local override.
The [member panel contract](../../app/macos/Sources/Host/Overview/README.md#viewed-application-collections)
owns the geometry and interaction gates.

## External input and isolation

The runner reuses the benchmark's external `Provider`, HTTP adapter and public
scoped-content reader read-only. It records their source hashes and adds only
e2e response text. The provider replaces **model service responses**, not the
native Codex CLI, Harness, Runtime or UI. `BENCHMARK CREATE` / `BENCH ITEM` are
the reused peer's wire markers; no performance measurement is performed.
Actual discovered CLI path/version/digest are recorded, not inferred from PATH.

Each invocation creates a private temporary profile, native configuration/home,
workspace and socket. Child environment contains no inherited API credentials;
only the synthetic peer credential is configured. External HTTPS proxy requests
are rejected; these controls do not claim to be an OS network sandbox. Native
catalog cache/fallback availability is not real-provider availability. No daily
profile, global account/configuration, product debug API or internal log sink is
used. Raw native homes and connection credentials stay outside uploaded evidence.

## Validity, result and evidence

`report.json` separates run validity (`valid`, `blocked`, `invalid`, `incomplete`)
from each interaction (`passed`, `failed`, `blocked`, `not-run`). A successful
operation receipt is not the result: the runner waits for mounted, nontransitioning
postconditions across repeated observations. Expected complete output is checked
by exact UTF-8 size/SHA through a public turn subscription, independently of
mounted execution identities. The provider's own response does not prove delivery.

Exit codes: **0** means all requested interactions passed with valid evidence and
cleanup; **1** means a valid run observed a functional assertion failure;
**2** means blocked/invalid/incomplete execution, unavailable prerequisites,
timeout, corrupt/missing evidence or unreached interactions. CLI parse errors
also use 2. Python optimization is rejected so assertions cannot disappear.

`source.json` records Git revision, dirty status, runner/adapter hashes and CI
run/attempt/ref. Build receipts identify actual binary bytes and source inputs.
`events.jsonl` records phases, process identities and outcomes; `api.jsonl` and
`ui-events.jsonl` retain external operations and observations. Each scenario's
named JSON files retain the actual criterion inputs. `cleanup.json` records
process termination and the private temporary directory. `manifest.json` hashes
all emitted evidence. Offline `verify` checks completeness/integrity and the
reported exit code; it neither reruns the product nor authenticates the author.
Missing files, unknown states and an empty result cannot earn a pass.

The whole run defaults to 600 seconds for `collection` and `all`, and 240 seconds
otherwise. Calls also have bounded local deadlines.
SIGINT/SIGTERM/total timeout revoke execution and enter cleanup. The runner first
requests graceful termination, then fences fallback signals to OS process
identities observed before teardown, including descendants in separate groups.
Forced cleanup invalidates the run. OS-enforced kill, machine loss and children
that escape observation cannot be claimed clean; missing final evidence fails
verification. Temporary profiles are retained locally on both success and failure
for diagnosis; the operator may remove the exact `privateDirectory` after all
owned processes are confirmed stopped. CI retains only the evidence directory.

## CI boundary

[Desktop interaction e2e](../../.github/workflows/e2e.yml) is an independent manual
workflow on one hosted macOS runner. Build, interaction and cleanup are serial;
dispatches queue. Choose `collection` for changes to reading eligibility or
collection projection. The default `supported` choice exercises OVERVIEW, READ and SETTINGS.
Native Codex is explicitly installed at `0.167.0`; the actual
selected executable is still recorded. Environment/version differences from a
local run remain visible. No signing credentials or self-hosted shared desktop
are needed for this development-artifact protocol check. A GUI prerequisite
failure stays nonzero. The workflow publishes evidence on failure as well as
success and fails when expected artifacts are absent. This workflow is not part
of `Complete coverage`, and its existence is not a claim of a hosted passing run.

## Composer system-input boundary

The production protocol has no `composer.send` / `composer.pause` operations.
The optional `--operator-composer` mode packages the same checked Swift executable
and its resource bundles with a unique test bundle ID. It publishes
`operator-request.json` with the exact App path, PID, nonce, Thread and stage.
An external operator activates that App through system Accessibility and performs
the indicated text input and button clicks. No production debug API is added.

```sh
python3 tools/e2e/run.py run --runtime .build/e2e/mokusei-runtime \
  --app app/macos/.build/debug/Mokusei --suite all --operator-composer \
  --desktop-lease /private/tmp/mokusei-ui-verification.lock \
  --desktop-owner YOUR_COORDINATOR_THREAD_ID \
  --output output/e2e/operator --timeout 900
```

The operator reads each request and operates only its exact isolated App. The
`activate` stage needs the actual window mounted; `send` and `stop` specify the
synthetic input. For each input stage the operator writes the named receipt into
the output directory after observing the result. Its JSON copies `nonce`, `pid`,
`threadId`, `app`, `stage`, sets `driver` to `system-accessibility`, includes each
listed confirmation as `true`, and retains the actual AX observations in the
nonempty `observations` string. This is an explicit operator attestation, not an
automatically collected AX transcript or screenshot. The runner never creates
these receipts. Operator mistakes and fabricated attestations cannot be excluded
by a hash manifest; the public oracles are independent checks, not author authentication.

Each request includes `inputEvidenceTemplate`. An operator may copy it to the
receipt's optional `inputEvidence` field and record the actual backend name,
TCC host when known, and permission probe tool/status/permissions/artifact.
Probe status is `unknown`, `reported` or `recorded`; `recorded` requires its
bundle-local artifact. Missing values remain `unknown`, not inferred from CUA,
another probe or a successful click. These are operator declarations.

`rawAXArtifacts` and `screenshotArtifacts` are null when archival status is
unknown, empty lists when explicitly not archived, or bundle-local filename
lists when retained. Named files must exist and be present in the manifest.
The report's `inputEvidence.operatorStages` keeps each validated stage's metadata
and receipt separately. A tool-return screenshot or manually summarized AX
observation is not automatically a raw archived recording; Runtime result
artifacts remain independent. Exact per-run probe results and input backends
belong to that report, not a permanent host-capability claim in this guide.

The Send criterion includes an exact persisted prompt, a new execution, exact
completed reply, mounted result and observed empty draft. The second input holds
the real native engine at an unfinished external Responses stream. Stop must be
observed and clicked in the same reader visit, without a close/reopen workaround;
the exact current execution must become `interrupted`, Stop must disappear and
the editor remain usable. Stop is cancellation, not a resumable pause. Source
socket closure alone does not establish successful cancellation. The hold has no
Runtime control hook; cleanup releases it even on failure.

No built-in unattended OS-input driver or hosted Composer run exists. The local
standalone AX probe can lack TCC permission even when the trusted desktop tool
can read and control the isolated App. Missing permissions, missing receipts,
missing controls, a deadline or failed public postconditions remain nonpassing;
HTTP submission is never substituted for Composer input. Keyboard Return, IME,
attachments, other providers, historical/exact-execution input, steering during
active output and recovery after uncertain admission are outside this scenario.

### Chief file picker

Use a uniquely bundled production build and an isolated online profile with a
configured Chief. The [Dock contract](../../app/macos/Sources/Host/MokuScene/README.md#dock-and-composer)
and [shared composer](../../app/macos/Sources/Shared/PluginUI/README.md#cards-composer-and-forms)
own the control and its draft import. Start on Overview and click the plus next
to the eyes. Choose **Import from this device**, cancel the native chooser, and
check that the draft text and chips are still present. Reopen it and select a
known text file and image. Check their ready chips, open and dismiss the image
preview, and send. Independently read the current Chief transcript through
Runtime and match the user message, attachment names and sizes. Check the
managed file bytes against the fixtures and confirm the draft clears. A
deterministic external peer can observe native delivery without a provider account.

Repeat the control and chooser check in Chief history. Capture the plus and
the eyes in the same row in light and dark system appearances and at a narrow
width or app zoom that admits the two-row composer. Inspect the control's
localized accessibility label, action and frame. Keep the commit, app digest,
profile and input backend, screenshots or AX observations, fixture digests,
transcript result and cleanup receipt. This local system-input procedure is
separate from `E2E-COMPOSER-001` and has no hosted runner.
