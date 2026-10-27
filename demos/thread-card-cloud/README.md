# Thread card cloud preview

**Historical preview.** This builder still references the removed
`Sources/App/NativeContentHost.swift` and compiles a subset of the old Host
sources. The setup and controls below describe the original experiment; its
build command is no longer a supported current replay. Use the
[production Overview / glass-world fixture](../../tools/verification/overview-input/README.md)
for current card/material screenshots, and the [cloud motion replay](../../tools/verification/cloud-motion/README.md)
for the shared renderer. The original sources and visual parameters are retained
for historical review; see the [demo inventory](../README.md).

An isolated native visual check for the approved light field on running harness
thread cards. It renders production components with local fixture values and
does not start agents or load a user workspace.

The demo uses the built `HarnessThreadCard`, harness logos, fonts and native
regular glass. The tag filter above the cards is compiled from its production
sources. The shared card now draws its own production cloud; `DemoHarness.swift`
uses the palettes exported by the owning harnesses, with no demo-only renderer:

- Codex: blue, indigo and pale periwinkle from its existing logo gradient.
- Claude: terracotta, apricot and peach around its existing orange accent.
- Pi: red, amber, green, cyan, blue and magenta, as requested by the user.
- OpenCode: graphite and silver, following its neutral light/dark identity.

Rainbow lobes are slightly smaller so the colors remain distinguishable.
Each harness starts at a different phase. The preview keeps the existing card
layout and clips the field to the existing 22-point rounded surface.

## Run

From the repository root:

```sh
make build
python3 demos/thread-card-cloud/build.py
open .build/thread-card-cloud/ThreadCardCloudDemo.app
```

For visual iterations with native dependencies already built, rerun only the
Python build. The demo uses those local Release objects and their framework
search path; its app bundle is not a standalone distribution.

## Controls

- **深色** switches only the preview window's appearance.
- **结束运行 / 重新运行** simulates completion/restart for all four fixtures and
  the reference filter. The card light fades over 0.4 seconds.
- **光云强度** changes the card field from 40% to 160%; it leaves the reference
  tag filter at its production exposure.
- **暂停流动 / 继续流动** freezes/resumes the clouds for inspection.
- **重置** returns intensity to 100% and resumes cloud motion.
- **卡片状态** exercises running, background running, attention, completion,
  interruption, failure and idle presentations.
- **快速重启 · 150 ms** reverses a fade before it completes.
- **宽卡片** shows the same field in wider apertures; scroll to the lower cards.

System motion preferences are not read. The
cloud is decorative, excluded from accessibility and does not accept input.
The text and runtime counters are the production card components with sample
values. No user workspace or runtime is loaded.

The production renderer is described in
[Harness thread card cloud loading](../../app/macos/Sources/Shared/PluginUI/README.md).

The standalone builder uses Swift 6 with warnings treated as errors. Its local fixtures do not establish native account or task execution behavior.
