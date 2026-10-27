import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The icon has no image/font inputs: all artwork is defined by these shapes.
func iconPNG(pixels: Int) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: pixels * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setFillColor(CGColor(srgbRed: 0.10, green: 0.22, blue: 0.21, alpha: 1))
    context.addPath(CGPath(
        roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
        cornerWidth: 208, cornerHeight: 208, transform: nil
    ))
    context.fillPath()

    // Four separate discs surround an open center at every raster size.
    context.setFillColor(CGColor(srgbRed: 0.98, green: 0.78, blue: 0.40, alpha: 1))
    for (x, y) in [(512, 304), (720, 512), (512, 720), (304, 512)] {
        context.fillEllipse(in: CGRect(x: x - 136, y: y - 136, width: 272, height: 272))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
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
