# Native cloud motion replay

Compile the actual shared motion/geometry and its replay without starting a
runtime or changing system accessibility settings:

```sh
mkdir -p .build/cloud-motion
xcrun swiftc -swift-version 6 -warnings-as-errors \
  app/macos/Sources/Shared/PluginUI/Design/NativeFrameRate.swift \
  app/macos/Sources/Shared/PluginUI/Design/NativeCloudField.swift \
  tools/verification/cloud-motion/main.swift -o .build/cloud-motion/replay
.build/cloud-motion/replay
```

The shared renderer uses `NativeFrameRate.interval` to allow 120 updates per
second. SwiftUI and the display determine actual presentation cadence; this
does not require the removed application-wide Metal refresh scheduler.

Checks smooth bounded movement at the shared 120 Hz preference across many
target changes, stable repeated samples for static drawing, independent surfaces
and motion lanes, departure from the former loop, and direct sampling after long
hidden intervals. These checks establish motion behavior, not rendered frame
rate or visual appearance.

The renderer now uses a precompiled SwiftUI Metal color shader. Build with Xcode
and its Metal toolchain installed (`xcodebuild -downloadComponent MetalToolchain`
if needed). The local SwiftPM build plugin compiles and bundles the shader for
both `swift build` and packaged apps; no runtime MSL source compilation is needed.

Run the shader/compositing integration checks with:

```sh
xcrun swift test --package-path app/macos --filter NativeCloudMetalTests
```

These checks load the generated library and render through SwiftUI, covering
transparent output, Canvas gradient equivalence, motion, fading and appearance.
They do not measure on-screen 120 FPS or power consumption.
