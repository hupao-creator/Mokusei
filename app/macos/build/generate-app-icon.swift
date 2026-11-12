import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rebuilt from the supplied visual reference; no screenshot pixels or fonts are embedded.
func iconPNG(pixels: Int) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Supersampling keeps the rim, rounded corners and soft shadows smooth at Dock sizes.
    let renderPixels = max(1024, pixels * 2)
    let context = CGContext(
        data: nil, width: renderPixels, height: renderPixels, bitsPerComponent: 8,
        bytesPerRow: renderPixels * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(renderPixels) / 1024, y: CGFloat(renderPixels) / 1024)

    func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: colorSpace, colors: stops.map(\.1) as CFArray,
                   locations: stops.map(\.0))!
    }

    let tile = CGPath(
        roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
        cornerWidth: 244, cornerHeight: 244, transform: nil
    )
    context.setShadow(offset: CGSize(width: 0, height: -7), blur: 20,
                      color: CGColor(srgbRed: 0.08, green: 0.17, blue: 0.30, alpha: 0.12))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(tile)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient([
        (0, CGColor(srgbRed: 0.96, green: 0.98, blue: 0.99, alpha: 1)),
        (1, CGColor(gray: 1, alpha: 1)),
    ]), start: CGPoint(x: 512, y: 64), end: CGPoint(x: 512, y: 960), options: [])
    context.restoreGState()

    let sphere = CGRect(x: 166, y: 166, width: 692, height: 692)
    context.setShadow(offset: CGSize(width: 0, height: -20), blur: 28,
                      color: CGColor(srgbRed: 0.18, green: 0.40, blue: 0.58, alpha: 0.28))
    context.setFillColor(CGColor(srgbRed: 0.86, green: 0.94, blue: 0.97, alpha: 1))
    context.fillEllipse(in: sphere)
    context.setShadow(offset: .zero, blur: 0, color: nil)

    context.saveGState()
    context.addEllipse(in: sphere)
    context.clip()
    context.drawLinearGradient(gradient([
        (0, CGColor(srgbRed: 0.02, green: 0.17, blue: 1.00, alpha: 1)),
        (0.18, CGColor(srgbRed: 0.12, green: 0.31, blue: 1.00, alpha: 1)),
        (0.48, CGColor(srgbRed: 0.37, green: 0.57, blue: 1.00, alpha: 1)),
        (0.76, CGColor(srgbRed: 0.67, green: 0.82, blue: 0.98, alpha: 1)),
        (1, CGColor(srgbRed: 0.94, green: 0.98, blue: 0.99, alpha: 1)),
    ]), start: CGPoint(x: 512, y: sphere.maxY),
        end: CGPoint(x: 512, y: sphere.minY), options: [])
    // A restrained edge shade gives the globe volume without a specular hotspot.
    context.drawRadialGradient(gradient([
        (0, CGColor(srgbRed: 0.10, green: 0.30, blue: 0.66, alpha: 0)),
        (0.82, CGColor(srgbRed: 0.10, green: 0.30, blue: 0.66, alpha: 0)),
        (1, CGColor(srgbRed: 0.10, green: 0.30, blue: 0.66, alpha: 0.10)),
    ]), startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 512), endRadius: 346, options: [])
    context.restoreGState()

    context.setStrokeColor(CGColor(srgbRed: 0.16, green: 0.37, blue: 0.70, alpha: 0.25))
    context.setLineWidth(1.5)
    context.strokeEllipse(in: sphere.insetBy(dx: 0.75, dy: 0.75))
    // Fade the inner white rim upward, leaving the saturated blue crown uninterrupted.
    context.saveGState()
    context.addEllipse(in: sphere.insetBy(dx: 5, dy: 5))
    context.setLineWidth(5)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient([
        (0, CGColor(gray: 1, alpha: 0.92)),
        (1, CGColor(gray: 1, alpha: 0)),
    ]), start: CGPoint(x: 512, y: sphere.minY),
        end: CGPoint(x: 512, y: 560), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    let raster = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: pixels * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    raster.interpolationQuality = .high
    raster.draw(context.makeImage()!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, raster.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    return data as Data
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate-app-icon /path/to/AppIcon.icns")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let manager = FileManager.default
let temporary = manager.temporaryDirectory.appendingPathComponent("mokusei-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: temporary) }
try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

var images: [Int: Data] = [:]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        if images[pixels] == nil { images[pixels] = try iconPNG(pixels: pixels) }
        let suffix = scale == 2 ? "@2x" : ""
        try images[pixels]!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
let staged = temporary.appendingPathComponent("AppIcon.icns")
process.arguments = ["--convert", "icns", "--output", staged.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "AppIcon", code: Int(process.terminationStatus),
                  userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
// Leave the previous asset intact if the platform encoder fails.
try Data(contentsOf: staged).write(to: output, options: .atomic)
print("Generated \(output.lastPathComponent) from geometric primitives")
