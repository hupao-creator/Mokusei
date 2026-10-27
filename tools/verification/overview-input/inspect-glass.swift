// Decode the independently captured PNGs and compare nonsemantic card interiors.
import AppKit
import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }

private struct Pixels {
    let bitmap: NSBitmapImageRep
    init(_ path: URL) throws {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: path)) else {
            throw Failure(description: "Cannot decode \(path.lastPathComponent)")
        }
        self.bitmap = bitmap
    }
    func difference(from other: Pixels, region: CGRect) throws -> (mean: Double, fraction: Double) {
        guard bitmap.pixelsWide == other.bitmap.pixelsWide, bitmap.pixelsHigh == other.bitmap.pixelsHigh,
              region.width > 0, region.height > 0,
              CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).contains(region) else {
            throw Failure(description: "Invalid comparison dimensions")
        }
        var total = 0.0, changed = 0, count = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                guard let a = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = other.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    throw Failure(description: "Cannot decode capture pixel")
                }
                let delta = 255 * (abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)) / 3
                total += delta; count += 1
                if delta >= 1 { changed += 1 }
            }
        }
        guard count > 0 else { throw Failure(description: "Empty pixel comparison") }
        return (total / Double(count), Double(changed) / Double(count))
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
            guard let on = captures.first(where: { $0["name"] as? String == "\(theme)-on" }),
                  let off = captures.first(where: { $0["name"] as? String == "\(theme)-off" }),
                  let frames = on["frames"] as? [String: String], frames == off["frames"] as? [String: String],
                  let mokuFrame = on["mokuFrame"] as? String, mokuFrame == off["mokuFrame"] as? String,
                  frames.count == 5 else { throw Failure(description: "Geometry or semantic fixture mismatch") }
            let a = try Pixels(directory.appendingPathComponent("\(theme)-on.png"))
            let b = try Pixels(directory.appendingPathComponent("\(theme)-off.png"))
            let scale = Double(a.bitmap.pixelsWide) / 1200
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
                regions.append(["id": id, "region": NSStringFromRect(region),
                                "meanChannelDifference": delta.mean, "changedPixelFraction": delta.fraction])
                guard delta.mean > 0.3, delta.fraction > 0.05 else {
                    throw Failure(description: "\(theme) \(id) shell has no visible on/off difference: \(delta)")
                }
            }
            // The fixed backdrop gives a separate control away from all cards,
            // Chrome and Moku. A whole-window change must not pass as a shell change.
            let background = try a.difference(from: b, region: CGRect(x: 8 * scale, y: 300 * scale, width: 8 * scale, height: 120 * scale))
            guard background.mean < 0.5 else { throw Failure(description: "Backdrop changed during \(theme) comparison: \(background)") }
            comparisons.append(["theme": theme, "regions": regions, "backgroundMeanDifference": background.mean])
        }
        try JSONSerialization.data(withJSONObject: ["comparisons": comparisons,
            "inspection": "Independent PNG decoding; all five card interior strips must change while fixed exterior backdrop stays stable."],
            options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("inspection.json"))
        print("PASS four glass-world production captures and independent shell pixel checks")
    }
}
