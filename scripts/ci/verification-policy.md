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

## Default hosted gates

| Gate | Independent value | Execution |
| --- | --- | --- |
| Go checks, race tests and generated properties | Architecture boundaries, data races, admission schedules, terminal-state invariants | Linux, plus Darwin-only clipboard/profile-lease tests on macOS |
| Runtime integration replays | Real HTTP/NDJSON, SQLite crash recovery, command ownership, Git worktrees, search lifecycle and cross-client cancellation | Linux `runtime` replay group |
| Adapter and Context replays | Real subprocess/protocol boundaries, malformed/late events, callback lifecycle, OAuth callback/refresh and cache ownership | Linux `adapters` replay group; scripted external peers and loopback services |
| Complete Swift suite | Mounted production controls, text composition/focus, attachment cleanup, WebKit, animation cancellation, geometry and actual bundled Metal rendering | macOS graphical session; display skips fail CI; DirectoryTag is included once |
| Generated Swift fixtures | Go-produced initial-response, Moku status, voice-event and conversation contracts reach real Swift consumers | Four fixture producers before the full suite |
| Go/Swift and process interop | Unicode/null/integer wire fidelity, file transfer, settings admission, profile identity, failed shutdown/reopen, Pi usage and native profile leases | Six existing interop launchers, three devtool replays and real daemon lifecycle on macOS |
| Isolated AppKit flows | Browser sheet lifecycle, application back navigation, settings persistence/conflict and real glass clipping during transitions | Existing settings and reading-presentation launchers on macOS |

The full Swift invocation defers only named methods needing a live Go fixture or
the isolated AppKit launcher. Their replay steps are mandatory, reject skipped
tests and retain reports/logs. New or display-related skips fail the job. Do not
turn a regression into an allowlist entry.

## Extended hosted gate

Dispatch `CI` with `extended=true` on the intended ref for pinned native Codex,
Pi and OpenCode against loopback providers, the Moku system matrices, and the
full 30-minute / at-least-100-cycle crash/resource gate. No account, paid model,
microphone or self-hosted Mac is involved. The normal PR run does not claim these
checks ran.

Run this gate for native CLI/adapter compatibility changes and for daemon
recovery, process ownership or long-lived resource changes. Its independent value
is detecting actual CLI loader/protocol changes, leaks and crash recovery that
scripted peers or short runs cannot establish. Pinning a CLI gives reproducible
coverage of that version, not proof of future upstream compatibility. A shortened
soak is diagnostic only and cannot replace full stability qualification.

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
