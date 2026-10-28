import AppKit
import ScreenCaptureKit
import Foundation
@testable import MokuseiUI

private struct StudyFailure: Error, CustomStringConvertible { let description: String }

@MainActor private func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let result = view as? T { return result }
    return view.subviews.lazy.compactMap { findView(type, in: $0) }.first
}

@MainActor private func productionArc(in view: NSView) -> NativeMokuCharacterCanvas? {
    if let view = view as? NativeMokuCharacterCanvas, view.seat == .decorations { return view }
    return view.subviews.lazy.compactMap { productionArc(in: $0) }.first
}

/// Observe the actual native window and its mounted display owners. No manual
/// draw or clock advancement is allowed to manufacture animation evidence.
@MainActor func verifyThinkingDemo(window: NSWindow, fixture: ThinkingFixture) async {
    let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("evidence")
    var checks: [String] = []
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw StudyFailure(description: message) }
        checks.append(message)
    }
    func wait(_ message: String = "Native view", _ condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < until else { throw StudyFailure(description: message + " did not settle") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    func ink(_ bytes: [UInt8]) -> Int {
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[index]), green = Int(bytes[index + 1]), blue = Int(bytes[index + 2])
            if green - red >= 6 && green - blue >= 8 && red < 215 && bytes[index + 3] > 240 { count += 1 }
        }
        return count
    }
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let report = output.appendingPathComponent("result.json")
        if FileManager.default.fileExists(atPath: report.path) { try FileManager.default.removeItem(at: report) }
        window.level = .floating
        try await Task.sleep(for: .milliseconds(800))
        var target: SCWindow?
        for _ in 0..<40 {
            target = try await SCShareableContent.currentProcess.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
                    && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                    && abs($0.frame.width - window.frame.width) < 1
                    && abs($0.frame.height - window.frame.height) < 1
            })
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let target, let host = window.contentView else { throw StudyFailure(description: "Own full-size native window unavailable") }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
        config.ignoreShadowsSingleWindow = true; config.scalesToFit = true; config.showsCursor = false
        config.capturesAudio = false; config.captureMicrophone = false; config.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(desktopIndependentWindow: target)
        func capture(_ name: String) async throws -> [UInt8] {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let data = pixels(image)
            let opaque = stride(from: 3, to: data.count, by: 4).filter { data[$0] > 240 }.count
            guard opaque > image.width * image.height * 98 / 100 else {
                throw StudyFailure(description: "Refusing transformed or transparent window capture")
            }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(name + ".png"))
            return data
        }
        let original = findView(HistoricalCharacterCanvas.self, in: host)
        try require(original?.hasScheduledFrame == true, "Historical reader owns a live native schedule")
        let first = try await capture("01-electron-light")
        fixture.source += "文字按顺序进入，眼睛轻轻扫读，身体随后跟上。"
        try await Task.sleep(for: .milliseconds(900))
        let second = try await capture("02-electron-append")
        try require(first != second && original!.frameCount > 10, "Historical native pixels change after incoming text")
        try require(ink(second) > 80, "Historical orbit has visible sage text")
        fixture.role = .tool
        try await Task.sleep(for: .milliseconds(650))
        _ = try await capture("03-electron-tool")
        fixture.role = .reasoning
        fixture.dark = true
        try await Task.sleep(for: .milliseconds(800))
        _ = try await capture("04-electron-dark")

        fixture.study = .capsule; fixture.dark = false
        try await Task.sleep(for: .milliseconds(700))
        _ = try await capture("05-capsule-mounted")
        try await wait { findView(ThinkingCapsuleReasoningCanvas.self, in: host)?.hasScheduledFrame == true }
        let canvas = findView(ThinkingCapsuleReasoningCanvas.self, in: host)!
        try await Task.sleep(for: .milliseconds(600))
        let before = try await capture("05-capsule-light")
        let clock = canvas.animation.clock
        fixture.source += " 新的文字继续到达。"
        try await Task.sleep(for: .milliseconds(600))
        let after = try await capture("06-capsule-append")
        try require(canvas.animation.clock > clock, "Same-segment append retains the native contour clock")
        try require(before != after && ink(after) > 80, "Capsule contour produces naturally moving visible glyphs")
        fixture.paused = true
        try await wait("paused contour") { !canvas.hasScheduledFrame }
        let pausedClock = canvas.animation.clock
        try await Task.sleep(for: .milliseconds(300))
        try require(canvas.animation.clock == pausedClock, "Pause freezes the contour without clearing its reader")
        fixture.paused = false
        try await wait { canvas.hasScheduledFrame }
        fixture.scene.setInputOpen(true)
        try await wait { canvas.animation.content == nil && !canvas.hasScheduledFrame }
        try await Task.sleep(for: .milliseconds(600))
        _ = try await capture("07-production-composer")
        fixture.scene.setInputOpen(false)
        try await wait { canvas.hasScheduledFrame }
        fixture.role = .tool
        try await wait { canvas.animation.content == nil && !canvas.hasScheduledFrame }
        checks.append("Production composer and tool ownership retire the contour")
        fixture.role = .reasoning; fixture.dark = true
        try await wait { canvas.hasScheduledFrame }
        try await Task.sleep(for: .milliseconds(600))
        _ = try await capture("08-capsule-dark")
        // Floating auxiliary windows can decline AppKit's minimize action.
        // Exercise the ordinary window lifecycle at its normal level.
        window.level = .normal
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        window.performMiniaturize(nil)
        try await Task.sleep(for: .milliseconds(350))
        if window.isMiniaturized {
            try await wait("minimized contour") { !canvas.hasScheduledFrame }
            window.deminiaturize(nil)
            checks.append("Actual miniaturization stops the contour schedule")
        } else {
            checks.append("SKIP: AppKit did not perform programmatic miniaturization; no minimize claim")
            window.orderOut(nil)
            try await wait("hidden contour") { !canvas.hasScheduledFrame }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        try await wait("restored contour") { canvas.hasScheduledFrame }
        window.level = .floating
        checks.append("Hidden native window pauses and visible window resumes the display owner")
        fixture.role = .idle
        try await wait { canvas.animation.content == nil && !canvas.hasScheduledFrame }
        checks.append("Ending thinking clears text and cancels its schedule")
        fixture.study = .arc; fixture.dark = false; fixture.shortText()
        try await wait("new arc reader") {
            guard let current = productionArc(in: host)?.controller else { return false }
            return current.hasScheduledFrame && current.currentReasoning?.segmentKey == fixture.content.segmentKey
        }
        let arc = productionArc(in: host)!.controller
        try await Task.sleep(for: .milliseconds(600))
        let arcPixels = try await capture("09-capsule-arc-short")
        let settledGlyphs = arc.reasoningAnimation.glyphs
        try await Task.sleep(for: .milliseconds(350))
        try require(!arc.reasoningAnimation.needsFrames && settledGlyphs == arc.reasoningAnimation.glyphs,
                    "Capsule arc settles after input instead of continuously orbiting")
        try require(ink(arcPixels) > 80, "Capsule arc renders legible short text")
        let arcClock = arc.reasoningAnimation.clock
        fixture.source += " 先检查已有实现，再比较两种阅读节奏，保留胶囊形态，让新的文字沿圆弧慢慢进入。"
        try await Task.sleep(for: .milliseconds(800))
        _ = try await capture("10-capsule-arc-light")
        try require(arc.reasoningAnimation.clock > arcClock, "Arc appends retain the current reader clock")
        fixture.dark = true
        try await Task.sleep(for: .milliseconds(500))
        _ = try await capture("11-capsule-arc-dark")
        try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: \(checks.count) native checks; evidence: \(output.path)")
    } catch {
        try? JSONSerialization.data(withJSONObject: ["ok": false, "error": String(describing: error), "checks": checks], options: [.prettyPrinted])
            .write(to: output.appendingPathComponent("result.json"))
        print("FAIL: \(error)")
    }
    NSApp.terminate(nil)
}
