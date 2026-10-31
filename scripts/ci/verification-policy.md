# Verification value and execution policy

A check earns a merge requirement by naming a defect it detects at a production
boundary. Prefer the existing assertion on a hosted runner. A model assertion is
not an equivalent replacement for a mounted control, real transport, native CLI
or rendered pixel assertion. Missing hardware, fixtures or permission is an
execution limitation, never a passing result.

Current-revision successful CI can replace an equivalent local run. Local tools
remain useful for iteration and diagnosis; their existence does not make every
tool mandatory for every change. Historical logs and checks from a different
revision cannot certify the new revision.

Plan focused local checks first. Hosted CI currently provides advisory feedback;
its completion is not a merge requirement. Honor any actual remote required
checks if protection rules change. Do not add a full local `make check` merely
before or after equivalent CI. Root AGENTS.md defines failure triage, scoped retry and merge
coordination. Documentation-only diffs proven by the workflow's conservative
path/mode classifier use an explicit diff-validation scope; unknown/mixed changes
and manual dispatches run all checks below. Native tests outside a proven
documentation scope are not claimed as executed.

## Default hosted checks

| Gate | Independent value | Execution |
| --- | --- | --- |
| Go checks, race tests and generated properties | Architecture boundaries, data races, admission schedules, terminal-state invariants | Linux, plus Darwin-only clipboard/profile-lease tests on macOS |
| Runtime integration replays | Real HTTP/NDJSON, SQLite crash recovery, command ownership, Git worktrees, search lifecycle and cross-client cancellation | Linux `runtime` replay group |
| Adapter and Context replays | Real subprocess/protocol boundaries, malformed/late events, callback lifecycle, OAuth callback/refresh and cache ownership | Linux `adapters` replay group; scripted external peers and loopback services |
| Complete Swift suite | Mounted production controls, text composition/focus, attachment cleanup, WebKit, animation cancellation, geometry and actual bundled Metal rendering | Five disjoint ordinary shards plus explicit mandatory native method owners after one macOS build; display skips fail CI; DirectoryTag is included once |
| Generated Swift fixtures | Go-produced initial-response, Moku status/Timer, voice-event, conversation and Harness-form contracts reach real Swift consumers | Five producers export six files through the preparation artifact before the Swift shards |
| Go/Swift and process interop | Unicode/null/integer wire fidelity, file transfer, settings admission, profile identity, failed shutdown/reopen, Pi usage and native profile leases | Six existing interop launchers, three devtool replays and real daemon lifecycle on macOS |
| Isolated AppKit flows | Browser sheet lifecycle, application back navigation, settings persistence/conflict and real glass clipping during transitions | Existing settings and reading-presentation launchers on macOS |

The Swift shards defer only named methods needing a live Go fixture or
the isolated AppKit launcher. Their replay steps are mandatory, reject skipped
tests and retain reports/logs. New or display-related skips fail the job. Do not
turn a regression into an allowlist entry.

Methods needing an exclusive native owner are recorded in `swift_ownership.py`
and the verified build manifest before ordinary partitioning. The title
cancellation and excerpt-mask replays belong to the existing
`native-capture/tag-glass-captures` check so their intermediate-frame assertions
run with AppKit's event loop and real WindowServer delivery. The excerpt case
requires observed ink movement through rewrite and an actual component-width
change, and emits `EXCERPT_INK_MOTION_CONFIRMED`; timer completion and final text
do not replace its moving-pixel evidence. The full Workspace search geometry method belongs to
`native-controls/isolated-input`; its morph and emphasized caret must advance
in the real AppKit loop and report `SEARCH_CARET_GEOMETRY_CONFIRMED` after the
native geometry assertions. All full method identities remain in discovery and
are excluded from ordinary execution without a test-level skip or environment bypass.
Ordinary commands retain suite-prefix `--filter` selection and pass a separate
shared `--skip` for the full native method ID and its runtime source-location
suffix. This command selection does not add a framework skip outcome; the method
must still execute at its declared native owner.
Coverage requires exactly one successful owner receipt, one passing terminal
outcome and the required execution marker at that declared check; missing frames fail the native assertion, while
missing, skipped, failed, repeated or misrouted outcomes fail aggregation.
Local `make check-swift` uses the same ordinary exclusion, then runs the existing
producer for the declared check and validates its actual native evidence.
Producer reports limited with `--check` are local evidence and cannot substitute
for a complete mandatory CI group.
Controlled CLI fixtures verify argument and evidence contracts; only the actual
current-head Swift/native run validates Swift Testing's runtime selection semantics.

## Runner allocation and execution limits

The workflow serializes PR/main and extended cohorts in a repository-wide queue.
Each admitted cohort still builds current sources once and runs five disjoint
native shards in parallel, with serial GUI work inside each runner. An exact
run/producer-attempt manifest gates shared artifacts and all discovered method
IDs must appear exactly once; weights are scheduling hints, never a coverage list.
Obsolete queued PR heads/bases and main pushes stop before native scheduling.

There is no fifteen-minute whole-run acceptance gate or shared 840-second deadline.
Queue, attempt and total retry elapsed times are diagnostic metrics. Thirty-minute
job/command execution limits stop hung work; narrower CLI/test timeouts retain
their independent purpose. A timeout still means incomplete verification.

Preserve each attempt's evidence and select the latest execution of each required
slot; never fall back from a new failure to an old success. Re-run failed jobs
only after diagnosis shows a retry is appropriate. A same-commit passing retry
does not establish that the first failure was harmless. The workflow still
requires all selected jobs and complete observed method coverage to report success; that result is advisory for merging.

## Extended hosted checks

Dispatch `CI` with `extended=true` on the intended ref for pinned native Codex,
Pi and OpenCode against loopback providers and the Moku system matrices.
No account, paid model, microphone or self-hosted Mac is involved. Extended
dispatches run only four independent native-CLI/system lanes. The normal PR run
does not claim these checks ran.

Run these checks for native CLI/adapter compatibility, process ownership and system
coordination changes. Its independent value is detecting actual CLI loader/protocol
changes and cross-role faults that scripted peers do not establish. Pinning a CLI
gives reproducible coverage of that version, not proof of future upstream compatibility. The long-running stability gate has been removed; these checks
do not claim continuous resource qualification.

## Checks with concrete device-dependent value

These are change-triggered acceptance checks, not universal local merge gates.

| Check and trigger | Defect that equivalent software injection cannot establish | Required evidence |
| --- | --- | --- |
| Microphone, audible WebRTC playback and audio-route changes; when media/audio/device routing, permission handling or WebRTC dependency changes | Permission succeeds but capture never starts; connected media is silent; switching an audio device fails to recover | A disposable real voice session on the affected Mac/device, observed capture/playback and route recovery. Synthetic PCM and signaling remain CI-covered |
| Physical Force Touch and trackpad scroll/pinch; when pressure configuration, hit regions, monitors or recognizer routing changes | Correct controller state but real OS events never reach it, or recognizers steal physical input | Physical input on the affected path. State-machine, synthetic event, focus and geometry checks remain CI-covered |
| A specified performance regression on a target Mac; only when a change makes a concrete device-performance claim | Target chip/display/thermal conditions produce a regression that a hosted VM's timing does not represent | Repeatable target-machine comparison with fixed workload and declared metric. CPU/timer samples are not display FPS, GPU or energy evidence |

If a hosted runner cannot execute a newly affected graphical check, first name
the missing capability and assess independent value. For example, WindowServer
pixels during a glass morph catch intermediate rectangular clipping that final
geometry misses. Such a specific visual regression can justify a related-change
acceptance check; it does not justify rerunning all UI tools locally for unrelated
changes. A capability failure must remain visible until coverage or the explicitly
scoped acceptance requirement is resolved.

## Signed production package exception

The production-app navigation and reading replays have independent value beyond
the ad-hoc AppKit fixtures: they run the actual Release bundle and its bundled
Runtime, catching missing resources, development-only library paths, mismatched
team signatures, broken startup/discovery, production navigation registration,
and scoped reader loading/release or load-earlier wiring.

Require these only when signing/entitlements, bundled resources/dependencies,
application or bundled-Runtime startup/discovery, or production navigation/reader
wiring changes. They can run on hosted macOS with Apple Development signing
credentials. This workflow does not configure those credentials; preserve this
specific signed-package acceptance until they are configured. An ad-hoc fixture
does not replace the existing same-team/hardened signing contract. Ordinary
component changes use their default CI coverage instead.

Build once, then reuse the same production artifact serially:

```sh
./scripts/go.sh run ./cmd/mokusei-dev bundle \
  --channel production --configuration release --output /absolute/evidence/bundle
python3 tools/verification/native-interaction/run.py \
  --app /absolute/evidence/bundle/Mokusei.app
python3 tools/verification/thread-interaction/run.py \
  --app /absolute/evidence/bundle/Mokusei.app
```

These use isolated profiles and do not send Harness model tasks or require an
account. Normal production discovery/search still runs; this is not a promise
of zero network or model-asset downloads. Preserve the printed per-run evidence
directories. No developer signing private key is exported by this CI migration.

## Obligations replaced or removed

| Former local activity | Decision and reason |
| --- | --- |
| Repeat all of `make check` after equivalent CI passes | Replaced by successful checks for the current revision; retain `make check` as a local development command |
| Repeat DirectoryTag separately from the full Swift suite | Removed from CI; identical cases already run in the full suite |
| Skip all native UI because CI is called headless | Replaced by actual hosted native execution, with required coverage reporting |
| Three tag-glass cases requiring an isolated capture launcher despite not needing capture | Run their unchanged glyph, semantic input and layout assertions in ordinary graphical Swift tests |
| Hand-inspect every screenshot or record a complete video for routine correctness | Use existing intermediate-frame pixel, geometry and interaction assertions; keep recording for a named visual defect or presentation review |
| Run historical glass/CPU research tools for every change | Removed as a general requirement: they have no general correctness threshold and do not measure FPS/GPU/energy |
| Use a real paid account to prove normal regression correctness | Use isolated protocol and pinned native-CLI loopback verification. Real-account smoke remains an explicit provider/authentication diagnostic, not an equivalent deterministic merge gate |

Standalone visual/research drivers remain available to reproduce specific issues.
Before requiring an additional local run, identify the uncovered production
boundary and why the default or extended hosted checks do not cover it. If no
such difference exists, use the existing CI evidence instead.
