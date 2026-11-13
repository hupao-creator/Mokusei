# Overview cloud assets

Run `python3 tools/assets/overview-cloud/generate.py` from any directory to
regenerate the checked-in assets. Xcode, its Metal compiler and a Metal-capable
Mac are needed only for regeneration; ordinary product builds just copy the
assets. This product-asset tool is separate from the artifact-only benchmark.

The baker compiles the production cloud field, uses the shared visual palette
specification and executes the production Metal shader offline. Each of the
four styles has light and dark atlases: 960 unique time samples over eight
seconds, at 120 fps, rendered at 180×110 pixels in the existing 360×220 point
field. The final second blends into the opening interval with a quintic weight.
One-pixel gutters limit neighboring-tile sampling. Colors are stored as
premultiplied sRGB PNGs. Runtime playback is Core Animation, without per-frame
application rendering or a 30 fps variant.

`OverviewCloudSources.json` records inputs and outputs so changes to palettes,
the field, shader or baker cannot silently use stale assets. Changing a palette
requires regeneration. The frame-rate request follows the window's display,
capped by the 120 fps source; actual physical presentation is owned by macOS.
Higher source rates require regenerating the assets and updating their contract.

The loop, common shape trajectory with per-card phase, scaled resolution and
opacity-based completion fade are intentional visual tradeoffs. The live
renderer remains the fallback for custom palettes or unavailable assets.
