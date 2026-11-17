# Moku thinking visual study

```sh
python3 demos/moku-thinking-orbit/build.py
open .build/moku-thinking-orbit/MokuThinkingDemo.app
```

`--skip-build` reuses current production objects. `--output` accepts only a
`MokuThinkingDemo.app` path inside this checkout's `.build`; the builder refuses
to replace its running app. It compiles local Swift sources, independent of any
other checkout.

The default capsule/Arc surface uses the real production Dock with fixture
reasoning text. The other study surfaces use this directory's isolated circular
resident and contour renderers. They do not define production geometry or timing.
Pause-input, pause-animation, short-text, new-paragraph and theme controls operate
fixture clocks. Production geometry, glass, blink and running feedback come from
current modules. No model/runtime correctness or physical-frame claim follows
from viewing the study.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.
