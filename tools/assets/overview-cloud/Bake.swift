import AppKit
import CoreImage
import ImageIO
import Metal
import SwiftUI
import UniformTypeIdentifiers

@main struct Bake {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let started = CACurrentMediaTime()
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: args[1]))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "nativeCloudVertex")!
        descriptor.fragmentFunction = library.makeFunction(name: "nativeCloudFragment")!
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let width = 180, height = 110, padding = 1, columns = 24, count = 960, rows = 40
        let tileWidth = width + padding * 2, tileHeight = height + padding * 2
        let atlasWidth = columns * tileWidth, atlasHeight = rows * tileHeight
        let duration = 8.0
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ci = CIContext(mtlDevice: device, options: [.workingColorSpace: linear, .cacheIntermediates: false])
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: textureDescriptor)!
        struct Uniforms { var pointsPerPixel: SIMD2<Float>; var geometryCount: UInt32; var colorCount: UInt32 }
        for style in NativeCloudLoopStyle.allCases {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let palette = NativeCloudPalette(channels: style.channels.map { channel in
                let hex = scheme == .dark ? channel.dark : channel.light
                return .init(color: Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
                    green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1),
                    seed: channel.seed, energy: channel.energy)
            }, phase: style.phase, lobeScale: style.lobeScale)
            var environment = EnvironmentValues(); environment.colorScheme = scheme
            let colors = palette.channels.flatMap { channel -> [SIMD4<Float16>] in
                let c = channel.color.resolve(in: environment)
                let value = SIMD4<Float16>(Float16(c.linearRed), Float16(c.linearGreen), Float16(c.linearBlue), 1)
                return Array(repeating: value, count: 6)
            }
            let context = CGContext(data: nil, width: atlasWidth, height: atlasHeight, bitsPerComponent: 8,
                                    bytesPerRow: atlasWidth * 4, space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            for index in 0..<count {
                try autoreleasepool {
                    let phase = Double(index) / 120
                    var a = NativeCloudField(palette: palette, intensity: 1, time: (phase + 1) * 1.4 + palette.phase,
                                            seed: 0x4d6f6b75736569).lights(in: CGSize(width: 360, height: 220), colorScheme: scheme).geometry
                    var rgba = colors
                    // Blend the final second into the loop's first second. Quintic
                    // weights preserve both endpoint position and velocity.
                    if phase >= 7 {
                        let t = phase - 7
                        let weight = t * t * t * (t * (t * 6 - 15) + 10)
                        var b = NativeCloudField(palette: palette, intensity: 1, time: t * 1.4 + palette.phase,
                                                seed: 0x4d6f6b75736569).lights(in: CGSize(width: 360, height: 220), colorScheme: scheme).geometry
                        for n in stride(from: 4, to: a.count, by: 5) { a[n] *= Float(1 - weight); b[n] *= Float(weight) }
                        a += b; rgba += colors
                    }
                    var uniforms = Uniforms(pointsPerPixel: SIMD2(2, 2), geometryCount: UInt32(a.count), colorCount: UInt32(rgba.count))
                    let command = queue.makeCommandBuffer()!
                    let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
                    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                    a.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                    rgba.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                    guard command.status == .completed else { throw command.error! }
                    let image = CIImage(mtlTexture: texture, options: [.colorSpace: linear])!
                    let frame = ci.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                 format: .RGBA8, colorSpace: colorSpace)!
                    let x = (index % columns) * tileWidth, y = atlasHeight - (index / columns + 1) * tileHeight
                    context.draw(frame, in: CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
                    context.draw(frame, in: CGRect(x: x + padding, y: y + padding, width: width, height: height))
                }
            }
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("OverviewCloudLoop-\(style.rawValue)-\(name).png") as CFURL,
                                                              UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
            print("baked \(style.rawValue) \(name): \(atlasWidth)x\(atlasHeight), \(count) frames")
        }
        }
        let metadata: [String: Any] = ["duration": duration, "fps": 120, "count": count, "width": width, "height": height,
                                     "padding": padding, "columns": columns, "rows": rows, "pointWidth": 360, "pointHeight": 220,
                                     "seed": "4d6f6b75736569", "crossfadeSeconds": 1]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("OverviewCloudLoop.json"))
        print("offline bake seconds: \(CACurrentMediaTime() - started)")
    }
}
