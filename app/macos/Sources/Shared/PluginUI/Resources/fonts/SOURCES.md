# Bundled native fonts

These bundled OpenType TrueType files derive from the Fontsource WOFF2
packages listed below. Their `wght` variation axes remain available to CoreText.
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
unique internal family and PostScript names (`Chief JetBrains Mono <Subset>` and
`ChiefJetBrainsMono<Subset>…`) to let CoreText register them simultaneously; their outlines,
metrics and variable axes are unchanged. `NativeTypography.mono` supplies these subsets as a
weighted CoreText cascade, preserving Greek, Cyrillic, Vietnamese and extended Latin coverage.
Subset source hashes and renamed PostScript names are recorded in `jetbrains-subsets.json`.
Only font-identifying name fields are renamed. Copyright, designer, manufacturer,
source URLs and license records retain their upstream values; registering a local
family name does not change the font's authorship or OFL license.

AppKit/CoreText performs system fallback for glyphs beyond the original fonts' coverage
(including CJK), as the browser does. Glyphs outside bundled coverage use CoreText system fallback; the exact
CJK family depends on the installed platform fonts.
`NativeTypography` never substitutes the complete Inter or JetBrains family with a system font.

Source SHA-256:

- Inter: `3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62`
- JetBrains Mono: `18be452724bfdc236c074ca94a249a7f41a86752c7d04ab258ce9ed5651f6a7e`
