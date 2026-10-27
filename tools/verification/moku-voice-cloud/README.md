# Native Moku voice cloud replay

Run `python3 tools/verification/moku-voice-cloud/run.py` from the root, or add
`--skip-build` immediately after a successful current `make check`. Run serially
with other SwiftPM builds. `MOKU_VOICE_INSPECT=1` leaves the isolated native
production-component window running for 30 seconds for Computer Use inspection.
It launches only its own disposable application, not the installed Mokusei.

The replay links production Debug modules and mounts NativeMokuDock and the
production NativeVoiceCloud. Synthetic FloatS16 PCM goes through the actual
NativeVoiceCaptureAnalyser adapter and pitch DSP; it checks 570/110 Hz, hidden
analysis reset, resume and capsule mount/collapse/expand. No runtime/profile,
model, network service, microphone, speaker or existing voice owner is touched.
It is not evidence of a live microphone/WebRTC/provider call.

The entrance replay also mounts the production cloud wrapper, voice controls,
Dock and history composer with a real NativeVoiceMediaClient held at its prepare
command before microphone permission. It captures before/entering/active/leaving/
restored states under the current system Reduce Motion setting, checks that rendering admits just
one preparation, and checks draft/input restoration after normal and rapid
60-ms cancellation. The preparation fixture allocates no server session or media.
These are native screenshots and lifecycle assertions, not frame-rate or physical
trackpad measurements; capture latency can miss the transition's first frames.
SwiftUI's Reduce Motion environment is read-only. This replay does not change
system preferences; rerun after manually changing Accessibility → Display →
Reduce motion to visually cover the other branch. Screenshot filenames record
whether the system preference was reduced or animated.

ScreenCaptureKit captures this process's full native window. Both metadata size
and opaque coverage are checked: Stage Manager may pad a transformed thumbnail
to full window dimensions. The replay activates only its own window and rejects
that transparent-wedge output instead of treating it as animation evidence.
The replay samples the background away from eyes, text and controls: motion
must change RGB pixels, while static drawing must not. Captures and numeric
measurements persist in `/tmp/mokusei-moku-voice-cloud-evidence`, configurable
with `MOKU_VOICE_EVIDENCE`. The static override exercises the manual `motionEnabled` input, independently
of system preferences. Failed
captures are retained under `failure` for diagnosis.

The Swift NativeVoiceAnalysisTests additionally cover amplitude-independent
pitch, noise/DC/silence, the capture generation fence, mute, stale-sample fallback
and no catch-up jump after hidden intervals. NativeCloudMetalTests exercise the
actual bundled Metal shader. These do not measure display FPS or audio hardware.

The approved loudness mapping now replaces pitch-dependent movement. Replay
covers quiet PCM without reliable pitch, stronger PCM at the same frequency,
silence and mute fallbacks in addition to visibility, compact/expanded Dock,
light/dark rendering and manual pause. A fixture timer keeps PCM fresh during
asynchronous WindowServer captures. Swift tests also compare light geometry at
fixed intensity, ensuring the response includes position/radius changes.
See [native voice](../../../app/macos/Sources/Voice/README.md) for the actual product signal chain and
safe production bundle adoption after the current voice session ends.
