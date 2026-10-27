# Bundled native fonts

These files preserve the font versions already used by `apps/desktop/src/renderer/src/fonts.css`.
They are the existing npm package WOFF2 files decompressed to OpenType TrueType (not redrawn,
replaced, or converted to static weights). Their `wght` variation axes remain available to CoreText.
The source licenses are included alongside the fonts.

| Native file | Existing source package | Font version | Weight axis |
| --- | --- | --- | --- |
| `inter-latin-wght-normal.ttf` | `@fontsource-variable/inter@5.3.0/files/inter-latin-wght-normal.woff2` | Inter 4.001, git `66647c0bb` | 100–900 |
| `jetbrains-mono-latin-wght-normal.ttf` | `@fontsource-variable/jetbrains-mono@5.3.0/files/jetbrains-mono-latin-wght-normal.woff2` | JetBrains Mono 2.211 | 100–800 |
| `jetbrains-mono-{cyrillic-ext,cyrillic,greek,vietnamese,latin-ext}-wght-normal.ttf` | The matching WOFF2 subsets from `@fontsource-variable/jetbrains-mono@5.3.0/files/` | JetBrains Mono 2.211 | 100–800 |

Upstream sources: [Inter](https://github.com/rsms/inter),
[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono),
[Fontsource](https://github.com/fontsource/fontsource).
Both fonts use SIL Open Font License 1.1; see `inter-LICENSE.txt` and `jetbrains-mono-LICENSE.txt`.

The Latin font coverage matches the Inter subset selected by the renderer. All six normal
JetBrains subsets imported by the renderer are bundled. The five non-Latin subset fonts have
unique internal family and PostScript names (`Mokusei JetBrains Mono <Subset>` and
`MokuseiJetBrainsMono<Subset>…`) to let CoreText register them simultaneously; their outlines,
metrics and variable axes are unchanged. `monoNSFont` supplies these subsets as a weighted
CoreText cascade, preserving Greek, Cyrillic, Vietnamese and extended Latin coverage.
Subset source hashes and renamed PostScript names are recorded in `jetbrains-subsets.json`.
Only font-identifying name fields are renamed. Copyright, designer, manufacturer,
source URLs and license records retain their upstream values; registering a local
family name does not change the font's authorship or OFL license.

AppKit/CoreText performs system fallback for glyphs beyond the original fonts' coverage
(including CJK), as the browser does. A native probe verified `Ж`, `Ω`, `ạ`, and `Ā` resolve
to the appropriate JetBrains subset, while `中` resolves to PingFang SC.
`NativeTypography` never substitutes the complete Inter or JetBrains family with a system font.

Reproduction, from the repository root with FontTools and Brotli installed:

```python
from pathlib import Path
from fontTools.ttLib import TTFont

for family in ("inter", "jetbrains-mono"):
    source = Path(f"node_modules/.pnpm/@fontsource-variable+{family}@5.3.0/node_modules/@fontsource-variable/{family}/files/{family}-latin-wght-normal.woff2")
    font = TTFont(source)
    font.flavor = None
    font.save(f"app/macos/Sources/Shared/PluginUI/Resources/fonts/{family}-latin-wght-normal.ttf")

for subset in ("cyrillic-ext", "cyrillic", "greek", "vietnamese", "latin-ext"):
    source = Path(f"node_modules/.pnpm/@fontsource-variable+jetbrains-mono@5.3.0/node_modules/@fontsource-variable/jetbrains-mono/files/jetbrains-mono-{subset}-wght-normal.woff2")
    font = TTFont(source)
    font.flavor = None
    suffix = "".join(part.title() for part in subset.split("-"))
    rename_ids = {1, 3, 4, 6, 16, 17, 18, 21, 22, 25}
    rename_ids.update(instance.postscriptNameID for instance in font["fvar"].instances
                      if instance.postscriptNameID != 0xFFFF)
    for record in font["name"].names:
        if record.nameID not in rename_ids:
            continue
        value = record.toUnicode().replace("JetBrainsMono", f"MokuseiJetBrainsMono{suffix}")
        value = value.replace("JetBrains Mono", f"Mokusei JetBrains Mono {suffix}")
        if value != record.toUnicode():
            record.string = value.encode(record.getEncoding())
    font.save(f"app/macos/Sources/Shared/PluginUI/Resources/fonts/jetbrains-mono-{subset}-wght-normal.ttf")
```

Source SHA-256:

- Inter: `3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62`
- JetBrains Mono: `18be452724bfdc236c074ca94a249a7f41a86752c7d04ab258ce9ed5651f6a7e`
