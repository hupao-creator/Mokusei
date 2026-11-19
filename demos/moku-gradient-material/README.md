# Moku capsule material preview

```sh
python3 demos/moku-gradient-material/build.py
open .build/moku-gradient-material/MokuGradientMaterialDemo.app
```

The builder compiles selected production geometry, capsule eyes and glass sources
with a minimal platform module and ad-hoc signs a local app. It does not need the
full Release application.

Both labeled light/dark columns call the same production warm-dark clear glass;
fixture text/appearance choices are separate. The controls expose backgrounds,
intensity, motion and a regular-glass comparison. At zero intensity the clear
glass remains. A local opaque preview does not change system preferences.
Production Reduce Transparency retains priority. Expanded Note uses dark Regular
Liquid Glass; this demo's expanded fixture still calls its clear branch.
The editable fixture is not the complete production composer, voice or focus flow.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.
