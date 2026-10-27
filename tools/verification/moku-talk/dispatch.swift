import AppKit
import MokuseiCore
@testable import MokuseiUI
import SwiftUI
import Vision

private struct DispatchCaptureFailure: Error, CustomStringConvertible { let description: String }

@MainActor func replayDispatch(fixture: Fixture, host: NSView, window: NSWindow, records: [JSONValue],
                               capture: (String) async throws -> Void) async throws {
    fixture.voiceVisible = false
    fixture.scheme = .light; window.appearance = NSAppearance(named: .aqua)
    let phases: [NativeMokuDispatch.Phase] = [.dispatching, .started, .dispatching, .failed]
    func verifyRow(_ captureName: String, thinking: String? = nil) throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(captureName + ".png")
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: path))!
        let image = bitmap.cgImage!
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        func bounds(_ token: String) throws -> CGRect? {
            for candidate in text {
                if let range = candidate.string.range(of: token, options: .caseInsensitive),
                   let box = try candidate.boundingBox(for: range) { return box.boundingBox }
            }
            return nil
        }
        // The fixed 92pt field intentionally truncates the middle of a model
        // when effort is present. Its visible prefix is still real model ink.
        let model = try bounds("moc"), status = try bounds("Thread") ?? bounds("派发")
        if model == nil || status == nil { print("OCR", text.map(\.string)) }
        try require(model != nil && status != nil, "WindowServer pixels do not show dispatch model/status")
        try require(model!.width * CGFloat(image.width) > 15, "Model collapsed instead of rendering")
        try require(status!.maxX <= model!.minX && abs(status!.midY - model!.midY) * CGFloat(image.height) <= 12,
                    "Status/configuration overlap or no longer share a single row")
        if let thinking {
            let effort = try bounds(thinking)
            if effort == nil { print("OCR", text.map(\.string)) }
            try require(effort != nil && effort!.minX >= model!.maxX, "Effort missing from rendered configuration")
        }
    }
    var callID: JSONText?
    for (index, record) in records.enumerated() {
        try fixture.install(record)
        try await wait("Dispatch lifecycle did not reach production Dock \(index)") {
            fixture.state.talkPresentation.message?.dispatch?.phase == phases[index] && fixture.state.talkPresentation.presented
        }
        let message = fixture.state.talkPresentation.message!
        if index == 1 { try require(callID == message.id, "Result replaced operation identity") }
        callID = message.id
        try require(message.dispatch?.prompt?.contains("输入内容，不是任务标题。\n") == true,
                    "Original input lost during audit projection")
        try require(!message.text.contains("输入内容"), "Prompt was disguised as title")
        try await Task.sleep(for: .milliseconds(550))
        try require(fixture.state.capsuleFrame.width == 400 && fixture.state.capsuleFrame.height == 58,
                    "Dispatch did not use approved 400×58 surface")
        try require(find(host, NativeMokuTalkScrollView.self) == nil && !fixture.state.inputOpen,
                    "Dispatch used multiline talk/input instead of approved row")
        try await capture("dispatch-text-\(index)")
        try verifyRow("dispatch-text-\(index)")
    }

    // Reuse exact real audits with new identities to represent a second delivery
    // while the ordinary production voice-mode admission is active.
    @discardableResult func deliver(_ record: JSONValue, suffix: String) throws -> JSONValue {
        var record = record.objectValue!, items = record["transcript"]!.arrayValue!
        var operation = items.last!.objectValue!
        operation["id"] = .text("dispatch-\(suffix)")
        // Explicit public thinking fixture supplements the mock Harness's
        // real model-only schema; never infer effort from host defaults.
        var arguments = operation["arguments"]!.objectValue!, options = arguments["options"]!.objectValue!
        options["thinking"] = .object(["mode": .text("effort"), "effort": .text("xhigh")])
        arguments["options"] = .object(options); operation["arguments"] = .object(arguments)
        items[items.count - 1] = .object(operation); record["transcript"] = .array(items)
        let delivery = JSONValue.object(record)
        try fixture.install(delivery)
        return delivery
    }
    fixture.voiceActive = true; fixture.voiceVisible = true
    try deliver(records[0], suffix: "voice")
    try await wait("Voice dispatch not visible") { fixture.state.talkPresentation.message?.dispatch?.phase == .dispatching }
    try deliver(records[1], suffix: "voice")
    try await wait("Voice dispatch result not visible") { fixture.state.talkPresentation.message?.dispatch?.phase == .started }
    try await Task.sleep(for: .milliseconds(550))
    try require(fixture.state.talkPresentation.presented && !fixture.state.inputOpen, "Voice mode suppressed dispatch")
    try require(fixture.state.capsuleFrame.size == CGSize(width: 400, height: 58), "Voice status resized dispatch")
    try await capture("dispatch-voice-started")
    try verifyRow("dispatch-voice-started", thinking: "xhigh")
    func cloudPixels(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name + ".png")
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: path))?.cgImage else {
            throw DispatchCaptureFailure(description: "Missing own-window cloud capture")
        }
        // A strip above the single text row excludes eyes, logo and voice
        // controls, so their animation cannot stand in for cloud movement.
        var rect = fixture.state.capsuleFrame
        rect.origin.x += 90; rect.size.width -= 150
        rect.origin.y += 8; rect.size.height = 7
        if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
        let inWindow = host.convert(rect, to: nil)
        let sx = CGFloat(image.width) / window.frame.width, sy = CGFloat(image.height) / window.frame.height
        let crop = CGRect(x: inWindow.minX * sx, y: (window.frame.height - inWindow.maxY) * sy,
                          width: inWindow.width * sx, height: inWindow.height * sy).integral
        guard let sample = image.cropping(to: crop) else { throw DispatchCaptureFailure(description: "Cloud strip is outside the fixture window") }
        var bytes = [UInt8](repeating: 0, count: sample.width * sample.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let cg = CGContext(data: buffer.baseAddress, width: sample.width, height: sample.height, bitsPerComponent: 8,
                bytesPerRow: sample.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
        }
        return bytes
    }
    let initial = try cloudPixels("dispatch-voice-started")
    var movement = 0.0
    for index in 0..<3 {
        try await Task.sleep(for: .milliseconds(350))
        let name = "dispatch-voice-cloud-\(index)"
        try await capture(name)
        let next = try cloudPixels(name)
        try require(next.count == initial.count && !initial.isEmpty, "Dispatch cloud capture changed dimensions")
        let delta = initial.indices.filter { $0 % 4 != 3 }.reduce(0.0) { $0 + abs(Double(initial[$1]) - Double(next[$1])) }
        movement = max(movement, delta / Double(initial.count / 4 * 3))
    }
    try require(movement > 0.5, "Dispatch row froze or covered the production voice cloud: \(movement)")
    print("PASS dispatch/production voice cloud coexistence; mean RGB delta \(movement)")

    fixture.scheme = .dark; window.appearance = NSAppearance(named: .darkAqua)
    window.setContentSize(CGSize(width: 380, height: 500))
    try await Task.sleep(for: .milliseconds(550))
    try require(fixture.state.capsuleFrame.width == 332 && fixture.state.capsuleFrame.height == 58,
                "Dispatch did not adapt to compact viewport")
    try await capture("dispatch-voice-dark-compact")
    try verifyRow("dispatch-voice-dark-compact", thinking: "xhigh")
    window.setContentSize(CGSize(width: 900, height: 620))
    try await Task.sleep(for: .milliseconds(550))

    let pendingA = try deliver(records[0], suffix: "detail-a")
    try await wait("Pending detail A not visible") { fixture.state.talkPresentation.message?.dispatch?.phase == .dispatching }
    let selectedID = fixture.state.talkPresentation.message!.id
    try await Task.sleep(for: .milliseconds(550))

    // Real native mouse events to the production SwiftUI Button, not a direct
    // assignment to a fixture detail flag. Never post events to the live app.
    let eye = find(host, NativeMokuCapsuleEyeCanvas.self)!
    let eyeFrame = eye.convert(eye.bounds, to: nil)
    let point = CGPoint(x: eyeFrame.maxX + 65, y: eyeFrame.midY)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        window.sendEvent(event)
    }
    try await wait("Production dispatch detail click did not open sheet") { window.attachedSheet != nil }
    try await Task.sleep(for: .milliseconds(350))
    try await capture("dispatch-clicked-input-sheet")
    func capturedText(_ name: String) throws -> String {
        let path = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name + ".png")
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: path))!
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    try require(try capturedText("dispatch-clicked-input-sheet").contains("正在派发任务"),
                "Sheet pixels did not show selected pending A")
    var current = pendingA.objectValue!, items = current["transcript"]!.arrayValue!
    let aIndex = items.count - 1
    var newer = items[aIndex].objectValue!
    newer["id"] = .text("dispatch-detail-b")
    items.append(.object(newer)); current["transcript"] = .array(items)
    try fixture.install(.object(current))
    try await wait("Newer B did not become latest") { fixture.presentation.talkMessage?.id != selectedID }
    var failedA = items[aIndex].objectValue!
    failedA["completedAt"] = .number(3); failedA["isError"] = .bool(true)
    failedA["result"] = .object(["error": .text("Pending A failed after B")])
    items[aIndex] = .object(failedA); current["transcript"] = .array(items)
    try fixture.install(.object(current))
    try await Task.sleep(for: .milliseconds(550))
    try await capture("dispatch-detail-updated-after-newer-b")
    let detailText = try capturedText("dispatch-detail-updated-after-newer-b")
    try require(detailText.contains("派发失败") && detailText.contains("Pending A failed after B"),
                "Selected A sheet pixels stayed stale after B arrived and A failed: \(detailText)")
    try require(fixture.presentation.talkMessage?.id != selectedID, "Refreshing A replaced newer B on the Dock")
    print("PASS selected pending A detail updates to failure after newer B without replacing B")
    if let sheet = window.attachedSheet {
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        sheet.sendEvent(escape)
    }
    try await wait("Input detail did not dismiss with Escape") { window.attachedSheet == nil }
    fixture.state.dismissTalk(); fixture.presentation.refresh()
    try await Task.sleep(for: .milliseconds(500))
    try require(fixture.state.talkPresentation.message == nil && fixture.state.capsuleFrame.width == 136,
                "Dismissed dispatch replayed on refresh")
}
