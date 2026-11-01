// Independent PNG oracle for opaque card interiors and non-card backdrop sampling.
import AppKit
import Foundation
import ImageIO

private struct Failure: Error, CustomStringConvertible { let description: String }

private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ path: URL) throws {
        guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure(description: "Cannot decode \(path.lastPathComponent)")
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // Color.resolve supplies sRGB components. Decode the PNG's declared
            // profile directly into sRGB; NSBitmapImageRep.colorAt can return a
            // device-RGB NSColor whose conversion changes already-sRGB samples.
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { throw Failure(description: "Cannot create sRGB pixel buffer") }
        self.width = width; self.height = height; bytes = pixels
    }

    func difference(from other: Pixels, region: CGRect) throws -> (mean: Double, fraction: Double) {
        guard width == other.width, height == other.height, region.width > 0, region.height > 0,
              CGRect(x: 0, y: 0, width: width, height: height).contains(region) else {
            throw Failure(description: "Invalid comparison dimensions")
        }
        var total = 0.0, changed = 0, count = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let offset = (y * width + x) * 4
                let delta = (0..<3).reduce(0.0) { sum, channel in
                    sum + abs(Double(bytes[offset + channel]) - Double(other.bytes[offset + channel]))
                } / 3
                total += delta; count += 1
                if delta >= 1 { changed += 1 }
            }
        }
        guard count > 0 else { throw Failure(description: "Empty pixel comparison") }
        return (total / Double(count), Double(changed) / Double(count))
    }

    func difference(from rgb: [Double], region: CGRect) throws -> Double {
        guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
              region.width > 0, region.height > 0,
              CGRect(x: 0, y: 0, width: width, height: height).contains(region) else {
            throw Failure(description: "Invalid palette comparison")
        }
        var total = 0.0, count = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let offset = (y * width + x) * 4
                total += (0..<3).reduce(0.0) { sum, channel in
                    sum + abs(Double(bytes[offset + channel]) - rgb[channel])
                } / 3
                count += 1
            }
        }
        guard count > 0 else { throw Failure(description: "Empty palette sample") }
        return total / Double(count)
    }
}

@main private enum Main {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let report = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("captures.json"))) as? [String: Any],
              let captures = report["captures"] as? [[String: Any]], captures.count == 4 else {
            throw Failure(description: "Four production captures required")
        }
        var comparisons: [[String: Any]] = []
        for theme in ["light", "dark"] {
            guard let first = captures.first(where: { $0["name"] as? String == "\(theme)-a" }),
                  let second = captures.first(where: { $0["name"] as? String == "\(theme)-b" }),
                  let frames = first["frames"] as? [String: String], frames == second["frames"] as? [String: String],
                  let mokuFrame = first["mokuFrame"] as? String, mokuFrame == second["mokuFrame"] as? String,
                  let palette = first["paletteRGB"] as? [String: [Double]], palette == second["paletteRGB"] as? [String: [Double]],
                  frames.count == 5 else { throw Failure(description: "Geometry or semantic fixture mismatch") }
            let a = try Pixels(directory.appendingPathComponent("\(theme)-a.png"))
            let b = try Pixels(directory.appendingPathComponent("\(theme)-b.png"))
            let scale = Double(a.width) / 1200
            var regions: [[String: Any]] = []
            for id in ["codex", "claude", "pi", "opencode", "report"] {
                guard let frameText = frames[id] else { throw Failure(description: "Missing \(id)") }
                let frame = NSRectFromString(frameText)
                // This strip is inside the outer shell, below the semantic text,
                // plan and round badge; it cannot be a text antialiasing difference.
                var strip = CGRect(x: frame.minX + 24, y: frame.maxY - 11,
                                   width: frame.width - 48, height: 4)
                // The production Dock overlaps the bottom cards' empty shells.
                // Measure the longer exposed strip, outside its glass/shadow,
                // so Dock pixels cannot be mistaken for a card material change.
                let dock = NSRectFromString(mokuFrame).insetBy(dx: -12, dy: -12)
                if strip.intersects(dock) {
                    let left = max(0, dock.minX - strip.minX), right = max(0, strip.maxX - dock.maxX)
                    strip = left >= right
                        ? CGRect(x: strip.minX, y: strip.minY, width: left, height: strip.height)
                        : CGRect(x: dock.maxX, y: strip.minY, width: right, height: strip.height)
                }
                let region = CGRect(x: strip.minX * scale, y: strip.minY * scale,
                                    width: strip.width * scale, height: strip.height * scale).integral
                let delta = try a.difference(from: b, region: region)
                var evidence: [String: Any] = ["id": id, "region": NSStringFromRect(region),
                    "meanChannelDifference": delta.mean, "changedPixelFraction": delta.fraction]
                guard delta.mean <= 0.3, delta.fraction <= 0.05 else {
                    throw Failure(description: "\(theme) \(id) card changed with the backdrop: \(delta)")
                }
                // Running cards retain their frozen cloud field. The completed
                // cards and Report have no cloud over this strip, so they also
                // provide an independent palette/opacity reference.
                if let key = ["codex": "completed", "pi": "completed", "report": "surface"][id] {
                    guard let rgb = palette[key] else { throw Failure(description: "Missing palette reference \(key)") }
                    let firstError = try a.difference(from: rgb, region: region)
                    let secondError = try b.difference(from: rgb, region: region)
                    guard firstError <= 2, secondError <= 2 else {
                        throw Failure(description: "\(theme) \(id) is not its opaque palette surface: \(firstError), \(secondError)")
                    }
                    evidence["paletteRGB"] = rgb
                    evidence["paletteMeanErrors"] = [firstError, secondError]
                }
                regions.append(evidence)
            }
            // A changed external control proves the two captures did not simply
            // reuse the same scene while the card strips stayed unchanged.
            let background = try a.difference(from: b, region: CGRect(x: 8 * scale, y: 300 * scale, width: 8 * scale, height: 120 * scale))
            guard background.mean > 5, background.fraction > 0.95 else {
                throw Failure(description: "Backdrop did not visibly change during \(theme) comparison: \(background)")
            }
            let dock = NSRectFromString(mokuFrame)
            let dockStrip = CGRect(x: dock.minX + 24, y: dock.maxY - 8, width: dock.width - 48, height: 3)
            guard !frames.values.contains(where: { NSRectFromString($0).intersects(dockStrip) }) else {
                throw Failure(description: "Non-card material control overlaps a card")
            }
            let dockRegion = CGRect(x: dockStrip.minX * scale, y: dockStrip.minY * scale,
                                    width: dockStrip.width * scale, height: dockStrip.height * scale).integral
            let dockDelta = try a.difference(from: b, region: dockRegion)
            guard dockDelta.mean > 0.3, dockDelta.fraction > 0.05 else {
                throw Failure(description: "The production Dock lost its backdrop response: \(dockDelta)")
            }
            comparisons.append(["theme": theme, "regions": regions, "backgroundMeanDifference": background.mean,
                "dockRegion": NSStringFromRect(dockRegion), "dockMeanDifference": dockDelta.mean,
                "dockChangedPixelFraction": dockDelta.fraction])
        }
        try JSONSerialization.data(withJSONObject: ["comparisons": comparisons,
            "inspection": "Five card interiors stay stable across changed backdrops; completed cards and Report match opaque palette colors; the untouched production Dock still responds to the backdrop."],
            options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("inspection.json"))
        print("PASS four card-materials production captures and independent opacity/palette/backdrop checks")
    }
}
