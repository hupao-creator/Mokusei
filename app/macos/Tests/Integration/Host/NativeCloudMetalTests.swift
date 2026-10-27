import AppKit
import Metal
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI

/// Exercises the packaged Metal function through SwiftUI's actual shader path.
@MainActor
@Suite(.serializedNative, .requiresDisplay)
struct NativeCloudMetalTests {
    private func pixels<V: View>(_ content: V, size: CGSize = CGSize(width: 64, height: 48), colorMode: ColorRenderingMode = .nonLinear) throws -> [UInt8] {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.colorMode = colorMode
        let image = try #require(renderer.cgImage)
        return try pixels(image)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    @Test func bundledLibraryAndTransparentOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(URL: NativeCloudMetalField.libraryURL)
        #expect(library.functionNames.contains("cloudLoading"))
        let empty = try pixels(NativeCloudMetalField(lights: NativeCloudLights()))
        #expect(empty.allSatisfy { $0 == 0 })
    }

    @Test(arguments: [ColorRenderingMode.nonLinear, .linear])
    func shaderMatchesCanvasGradientCompositing(colorMode: ColorRenderingMode) throws {
        let lights = NativeCloudLights(geometry: [24, 20, 22, 17, 0.4, 36, 25, 30, 26, 0.25],
            colors: [Color(.sRGBLinear, red: 0.1, green: 0.3, blue: 0.9).opacity(0.6),
                     Color(.sRGBLinear, red: 0.7, green: 0.1, blue: 0.4)])
        let metal = try pixels(NativeCloudMetalField(lights: lights), colorMode: colorMode)
        let canvas = try pixels(Canvas(opaque: false, colorMode: .linear) { context, _ in
            context.drawLayer { field in
                field.blendMode = .plusLighter
                for offset in stride(from: 0, to: lights.geometry.count, by: 5) {
                    var light = field
                    light.translateBy(x: CGFloat(lights.geometry[offset]), y: CGFloat(lights.geometry[offset + 1]))
                    light.scaleBy(x: CGFloat(lights.geometry[offset + 2]), y: CGFloat(lights.geometry[offset + 3]))
                    let color = lights.colors[offset / 5]
                    let energy = Double(lights.geometry[offset + 4])
                    let gradient = Gradient(stops: [
                        .init(color: color.opacity(energy), location: 0),
                        .init(color: color.opacity(energy * 0.82), location: 0.22),
                        .init(color: color.opacity(energy * 0.36), location: 0.52),
                        .init(color: color.opacity(energy * 0.08), location: 0.80),
                        .init(color: color.opacity(0), location: 1)
                    ])
                    light.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                               with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 1))
                }
            }
        }, colorMode: colorMode)
        #expect(metal.contains { $0 > 0 })
        let errors = zip(metal, canvas).map { abs(Int($0) - Int($1)) }
        #expect(errors.max()! <= 5)
        #expect(Double(errors.reduce(0, +)) / Double(errors.count) < 0.5)
    }

    @Test func productionFieldMovesFadesAndHonorsAppearance() throws {
        let palette = NativeCloudPalette(channels: [.init(color: .cyan, seed: 7, energy: 0.42)])
        var colorScheme = ColorScheme.light
        let size = CGSize(width: 64, height: 48)
        func sample(_ time: Double, _ intensity: Double) -> NativeCloudLights {
            NativeCloudField(palette: palette, intensity: intensity, time: time, seed: 42)
                .lights(in: size, colorScheme: colorScheme)
        }
        let first = try pixels(NativeCloudMetalField(lights: sample(3.8, 1)))
        let later = try pixels(NativeCloudMetalField(lights: sample(8, 1)))
        let faded = try pixels(NativeCloudMetalField(lights: sample(3.8, 0.25)))
        #expect(first != later)
        #expect(first.reduce(0) { $0 + Int($1) } > faded.reduce(0) { $0 + Int($1) })
        #expect(sample(3.8, 0).isEmpty)
        colorScheme = .dark
        let dark = try pixels(NativeCloudMetalField(lights: sample(3.8, 1)))
        #expect(first.reduce(0) { $0 + Int($1) } > dark.reduce(0) { $0 + Int($1) })
    }

    @Test(arguments: [0.0, -0.25])
    func dormantLoadingRemainsTransparentAndFillsItsProposal(intensity: Double) throws {
        _ = NSApplication.shared
        let palette = NativeCloudPalette(channels: [.init(color: .cyan, seed: 7, energy: 0.42)])
        let loading = NativeCloudLoading(palette: palette, intensity: intensity)
        let renderer = ImageRenderer(content: loading.background(Color.red))
        renderer.proposedSize = ProposedViewSize(width: 64, height: 48)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 64)
        #expect(image.height == 48)
        let output = try pixels(image)
        let expected = try pixels(Color.clear.background(Color.red))
        let background = try pixels(Color.red)
        #expect(expected == background, "The transparent control must preserve the opaque red background")
        #expect(output == expected, "intensity \(intensity) must leave the opaque background unchanged")
    }

    @Test func positiveInterpolatedLoadingValuesRenderBeforeAndAfterZero() throws {
        _ = NSApplication.shared
        // Broad lobes keep this lifecycle assertion independent of the random
        // motion seed; paused motion must still render every positive intensity.
        let palette = NativeCloudPalette(channels: [.init(color: .cyan, seed: 7, energy: 0.42)],
                                         lobeScale: CGSize(width: 20, height: 20))
        var loading = NativeCloudLoading(palette: palette, intensity: 1, isAnimating: false)
        let expected = try pixels(Color.clear.background(Color.red))
        let background = try pixels(Color.red)
        #expect(expected == background, "The transparent control must preserve the opaque red background")
        let renderer = ImageRenderer(content: loading.background(Color.red).frame(width: 64, height: 48))
        renderer.scale = 1
        for intensity in [1.0, 0.5, 0.05, 0, 0.05, 1] {
            loading.animatableData = intensity
            renderer.content = loading.background(Color.red).frame(width: 64, height: 48)
            let output = try pixels(#require(renderer.cgImage))
            try #require(output.count == expected.count)
            var changedPixels = 0
            for offset in stride(from: 0, to: output.count, by: 4) {
                let redChanged = output[offset] != expected[offset]
                let greenChanged = output[offset + 1] != expected[offset + 1]
                let blueChanged = output[offset + 2] != expected[offset + 2]
                if redChanged || greenChanged || blueChanged { changedPixels += 1 }
            }
            if intensity > 0 {
                #expect(changedPixels > 0, "intensity \(intensity) must change the opaque background's RGB")
            } else {
                #expect(output == expected, "intensity \(intensity): \(changedPixels) pixels differ from the opaque background")
            }
        }
    }
}
