# Application icon source

`AppIcon.icns` is generated entirely from
[`generate-app-icon.swift`](generate-app-icon.swift): an sRGB rounded square
and four filled circles, rendered with CoreGraphics and encoded by ImageIO and
the macOS `iconutil` tool. The geometry was authored for this repository during
the source-publication review. It has no external image, font, traced artwork,
download or model-generated image input. The generator and its output are
covered by the repository [LICENSE](../../../LICENSE); no third-party artwork
license is asserted or required for this generated asset.

From the repository root, regenerate with the macOS command-line tools:

```sh
mkdir -p .build/app-icon
xcrun swiftc -module-cache-path .build/app-icon/ModuleCache \
  app/macos/build/generate-app-icon.swift -o .build/app-icon/generate
.build/app-icon/generate app/macos/build/AppIcon.icns
```

The iconset includes 16, 32, 128, 256 and 512 point images at 1× and 2×. PNG
encoding can vary across macOS toolchains; compare decoded pixels when checking
reproducibility across versions.

## Replaced asset and historical scope

The previous icon in baseline `a42e44c9943260e36ab4876f3619a43e5f20ec9b`
was byte-identical to Git blob `eab908a5f38610fbe5403b36322757a395065010`,
introduced as `apps/desktop/build/icon.icns` by commit
`d053cfc89f6665579ec7f7e2c26987aeed77e987` ("Use Osmie artwork for desktop
package icons"). That commit describes selected botanical artwork but supplies no
author, original source or license. The name "Osmie" alone proves neither
third-party origin nor project ownership. The older procedural icon generator
from `8979607b91139aaaf4dd0679540a388f490ab694` produced a different asset and
cannot establish the replaced icon's provenance.

The current icon was replaced because that evidence is insufficient to assert
permission to redistribute the old artwork. This replacement does not remove
the old blob from Git history. Before publishing historical commits, the
publisher must either establish permission for that asset or exclude that
history from the public repository. The current generated source snapshot has
no dependency on the old artwork. No historical copyright ownership is inferred
from this replacement.
