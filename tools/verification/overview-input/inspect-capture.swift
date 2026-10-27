// Decode the recorded file itself; screenshots supplement, never substitute video.
import AppKit
import AVFoundation

struct Failure: Error { let message: String }
func regionDifference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, _ frame: CGRect) -> Double {
    var sum = 0.0, count = 0.0
    for y in stride(from: max(0, Int(frame.minY)), to: min(lhs.pixelsHigh, Int(frame.maxY)), by: 2) {
        for x in stride(from: max(0, Int(frame.minX)), to: min(lhs.pixelsWide, Int(frame.maxX)), by: 2) {
            let a = lhs.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let b = rhs.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            sum += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            count += 3
        }
    }
    return sum / max(1, count)
}

@main struct Inspect {
 static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("events.json"))) as! [String: Any]
    let events = manifest["events"] as! [[String: Any]]
    let asset = AVURLAsset(url: directory.appendingPathComponent("real-cards.mp4"))
    let duration = try await asset.load(.duration).seconds
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output); reader.startReading()
    var frameCount = 0, previous = -1.0, firstPTS: Double?
    var points: [(name: String, time: Double)] = []
    for event in events {
        guard let name = event["name"] as? String, let at = event["at"] as? Double else { continue }
        if name.contains("initial 16 real cards") { points.append(("\(name) background", at - 0.12)) }
        for offset in [0.0, 0.05, 0.1, 0.15, 0.21, 0.3, 0.4, 0.55] {
            points.append(("\(name) +\(Int(offset * 1000))ms", at + offset))
        }
    }
    var frames: [(name: String, at: Double, image: CGImage)] = []
    let context = CIContext()
    var heldFrame: (at: Double, image: CGImage)?
    while let sample = output.copyNextSampleBuffer() {
        let pts = sample.presentationTimeStamp.seconds
        if firstPTS == nil { firstPTS = pts }
        let at = pts - firstPTS!
        guard at >= previous, let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "Invalid decoded frame") }
        previous = at; frameCount += 1
        let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))!
        let ready = points.filter { $0.time <= at }
        for point in ready {
            // Variable-rate recording holds its preceding frame through static
            // intervals. Taking the next frame can turn an empty reference into
            // the newly mounted grid, or skip past the exit being checked.
            let selected = point.time == at ? (at: at, image: image) : (heldFrame ?? (at: at, image: image))
            frames.append((point.name, selected.at, selected.image))
        }
        points.removeAll { $0.time <= at }
        heldFrame = (at, image)
    }
    guard reader.status == .completed, frameCount > 100, previous > 3 else { throw Failure(message: "Recording decode failed or too short") }
    for page in 0..<Int(ceil(Double(frames.count) / 16)) {
        let sheet = NSImage(size: CGSize(width: 1888, height: 1380)); sheet.lockFocus()
        NSColor.black.setFill(); CGRect(x: 0, y: 0, width: 1888, height: 1380).fill()
        for j in 0..<16 {
            let index = page * 16 + j; if index >= frames.count { break }
            let f = frames[index], x = (j % 4) * 472, y = 1380 - (j / 4 + 1) * 345
            NSImage(cgImage: f.image, size: .zero).draw(in: CGRect(x: x, y: y + 30, width: 472, height: 312))
            (String(format: "%.3fs ", f.at) + f.name as NSString).draw(at: CGPoint(x: x + 4, y: y + 4),
                withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)])
        }
        sheet.unlockFocus()
        try NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
            .write(to: directory.appendingPathComponent("decoded-\(page).jpg"))
    }
    var checks: [[String: Any]] = [], passed = true
    for theme in ["light", "dark"] {
        let event = events.first { $0["name"] as? String == "\(theme): exit snapshot" }!
        let old = NSRectFromString((event["oldFrames"] as! [String: String])["card-0"]!)
        let elapsed = event["elapsed"] as! Double
        guard elapsed > 0.14 && elapsed < 0.39, event["layingOut"] as? Bool == true else { throw Failure(message: "Exit evidence missed animation window") }
        let background = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("\(theme)-background.png")))!
        let grid = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("\(theme)-grid.png")))!
        let exit = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("\(theme)-exit-210ms.png")))!
        guard let recorded = frames.first(where: { $0.name == "\(theme): filter 16 → 3 +300ms" }) else {
            throw Failure(message: "Missing recorded filter intermediate frame")
        }
        let filterAt = events.first { $0["name"] as? String == "\(theme): filter 16 → 3" }!["at"] as! Double
        guard recorded.at >= filterAt + 0.23, recorded.at < filterAt + 0.37 else {
            throw Failure(message: "Video skipped the pre-cleanup exit interval")
        }
        let decoded = NSBitmapImageRep(cgImage: recorded.image)
        guard let reference = frames.first(where: { $0.name == "\(theme): initial 16 real cards background" }),
              let occupied = frames.first(where: { $0.name == "\(theme): initial 16 real cards +400ms" }) else {
            throw Failure(message: "Missing video background/occupied reference")
        }
        let videoBackground = NSBitmapImageRep(cgImage: reference.image)
        let videoGrid = NSBitmapImageRep(cgImage: occupied.image)
        // Broad regions include each part's shrunken screen-space location.
        // card-0 is outside the survivor column in both appearances.
        for (part, region) in [("glass", CGRect(x: 0.15, y: 0.77, width: 0.5, height: 0.12)),
                               ("badge", CGRect(x: 0.72, y: 0.05, width: 0.23, height: 0.32)),
                               ("text", CGRect(x: 0.12, y: 0.18, width: 0.48, height: 0.45))] {
            let rect = CGRect(x: (old.minX + region.minX * old.width) * 2, y: (old.minY + region.minY * old.height) * 2,
                              width: region.width * old.width * 2, height: region.height * old.height * 2)
            // Compare like encodings: H.264 decoding/color conversion differs
            // from lossless screenshots even when both show an empty background.
            for (source, image, empty, occupied) in [("screenshot", exit, background, grid),
                                                    ("decoded-video", decoded, videoBackground, videoGrid)] {
                let before = regionDifference(occupied, empty, rect)
                let after = regionDifference(image, empty, rect)
                let ok = before > 0.01 && after < max(0.008, before * 0.12)
                passed = passed && ok
                checks.append(["theme": theme, "part": part, "source": source, "before": before, "after": after,
                               "ratio": after / max(before, 0.001), "passed": ok])
            }
        }
    }
    let report: [String: Any] = ["passed": passed, "frames": frameCount, "duration": duration, "lastDecodedTime": previous,
        "checks": checks, "storyboardSamples": frames.count,
        "note": "Pixel checks use own-window screenshots inside the exit interval and decoded MP4 intermediate frames. Storyboard labels are approximate elapsed recording-callback times, not scan-out timestamps. Capture cadence is not display FPS."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("inspection.json"))
    print(String(data: data, encoding: .utf8)!)
    if !passed { exit(1) }
 }
}
