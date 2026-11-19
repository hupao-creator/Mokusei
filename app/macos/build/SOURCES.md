# Application icon source

`AppIcon.icns` is generated entirely from
[`generate-app-icon.swift`](generate-app-icon.swift): a white rounded square
with a centered blue-to-pale-blue sphere, a soft contact shadow and a fine lower
highlight. CoreGraphics renders the geometry and sRGB gradients at twice the
target resolution (at least 1024 pixels), then downsamples before ImageIO and
the macOS `iconutil` tool encode the result. Pixels outside the tile and its
shadow remain transparent.

The procedural design uses the user-supplied screenshot
`539BE5D3-EEAE-4F5B-885E-F2B43B279C80.jpg` as a visual reference. The screenshot's dark blue background, compression
artifacts and pixels are not included, and regeneration needs no image or font
inputs. The screenshot is a visual reference only and is not stored in this
repository. Its original author and license were not supplied; procedural
reconstruction does not establish ownership of the referenced design. The
generator source is covered by the repository [LICENSE](../../../LICENSE).

From the repository root, regenerate with the macOS command-line tools:

```sh
mkdir -p .build/app-icon
xcrun swiftc -module-cache-path .build/app-icon/ModuleCache \
  app/macos/build/generate-app-icon.swift -o .build/app-icon/generate
.build/app-icon/generate app/macos/build/AppIcon.icns
```

The iconset includes 16, 32, 128, 256 and 512 point images at 1× and 2×. PNG
encoding can vary across macOS toolchains; compare decoded pixels when checking
reproducibility across versions. Both development and production packaging copy
this same `AppIcon.icns` to `Contents/Resources/AppIcon.icns`, referenced by
`CFBundleIconFile=AppIcon`. Regeneration changes the source asset; rebuild and
package the application to use it in a new bundle.

To inspect the encoded representations without launching or replacing an app:

```sh
iconutil --convert iconset --output .build/app-icon/preview.iconset \
  app/macos/build/AppIcon.icns
sips -g pixelWidth -g pixelHeight -g hasAlpha \
  .build/app-icon/preview.iconset/icon_512x512@2x.png
```

Use a fresh output directory for each extraction. Inspect both the 1024-pixel
master and small Dock/Finder sizes; the outer padding must stay transparent.
