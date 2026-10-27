# Overview text resolution comparison

```sh
python3 tools/verification/overview-text/run.py .build/overview-text/captures
python3 tools/verification/overview-text/analyze.py .build/overview-text/captures
```

The analysis needs Pillow and NumPy (available in the Codex bundled Python).
The capture runner needs only the standard library, Xcode and the visible desktop.
It builds this checkout and opens an isolated test-owned window, with production
`NativeOverviewCanvas` and `HarnessThreadCard`, synthetic text and a fixed dark
background. It starts no runtime and accesses no user conversations or settings.
ScreenCaptureKit captures only this process's full-size window. PNG dimensions
match its actual backing scale; no screenshot is resized for analysis.

`captures.json` records camera scale, window content scale, backing scale, actual
card bounds and output dimensions. Reference cases disable only the new glyph
resolution environment. Camera 100%, 125%, 170% and window 125% compare against
those references. The 100% text crop must be pixel-identical; normalized title
edge concentration must improve by at least 25% in each magnified case. This
metric is a regression check for these fixed glyphs, not a universal font-quality
score. Inspect the unscaled `comparison.png` and full PNGs as well.

The lower probe provides independent controls at the same final font/layout size:
ordinary scaleEffect, direct larger fonts, affine transform, drawingGroup with
and without a displayScale boost, geometryGroup, custom TextRenderer, no glass
container, and larger fonts reduced back to world size. These retain the
investigation that separated glyph rasterization from contrast and glass effects.
The drawingGroup controls contain only SwiftUI drawing primitives.

This is a static rendering check. Physical input, animation and navigation remain
covered by the existing overview input replay and native integration tests.
