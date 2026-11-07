import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiPluginUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiHarnessCodex

@MainActor @Observable private final class UsageRollProbe { var value = "128" }
private struct UsageRollHost: View {
    let probe: UsageRollProbe
    var body: some View {
        ThreadCardUsage(usage: .init(parts: [
            .init(suffix: "tokens", description: "tokens", id: "total", value: probe.value, numericValue: 128)
        ]))
        .padding(16)
        .frame(width: 180, height: 56, alignment: .leading)
        .background(Color.white)
        .environment(\.threadCardTextRasterScale, 2)
    }
}

/// Keeps the historical stable-cell layout and the requested downward motion,
/// including at the overview's raster tier.
@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct RollingNumberCellTests {
    @Test func threadCardUsageRollsInsideStableCells() async throws {
        let probe = UsageRollProbe()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 180, height: 56), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let root = NSHostingView(rootView: UsageRollHost(probe: probe))
        window.contentView = root
        window.orderFront(nil)
        defer { window.close() }
        func pixels() throws -> Data {
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            return try #require(image.representation(using: .png, properties: [:]))
        }
        func fittingWidth(_ value: String) -> CGFloat {
            let host = NSHostingView(rootView: RollingNumberText(value: value)
                .environment(\.threadCardTextRasterScale, 2).fixedSize())
            host.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        try await Task.sleep(for: .milliseconds(180))
        let initial = try pixels()
        let widthBefore = root.fittingSize.width
        probe.value = "957"
        try await Task.sleep(for: .milliseconds(80))
        let during = try pixels()
        let widthDuring = root.fittingSize.width
        try await Task.sleep(for: .milliseconds(320))
        let settled = try pixels()
        #expect(initial != during && during != settled && initial != settled)
        #expect(widthBefore == widthDuring)
        #expect(fittingWidth("0") == fittingWidth("1"))
        #expect(fittingWidth("000") == fittingWidth("181"))
    }
}

@MainActor @Observable private final class ProjectedUsageProbe {
    let plugin = AnyHarnessPlugin(CodexHarnessPlugin())
    var snapshot: HarnessOverviewSnapshot
    var appearances = 0

    init() throws { snapshot = try plugin.projectOverview(input: Self.input(128), availableColumns: 3) }

    func update(_ tokens: Int) throws {
        snapshot = try plugin.projectOverview(input: Self.input(tokens), availableColumns: 3)
    }

    private static func input(_ tokens: Int) throws -> HarnessThreadInput {
        let turn: JSONValue = .object([
            "executionId": .text("usage-execution"), "status": .text("running"),
            "createdAt": .number(1), "updatedAt": .number(2),
            "answer": .text(""), "reasoning": .text(""),
            "messages": .array([]), "timeline": .array([]), "activities": .array([]),
            "interactions": .array([]), "plan": .array([]), "notices": .array([]),
            "usage": .object(["inputTokens": .integer(tokens), "outputTokens": .integer(0)])
        ])
        let state: JSONValue = .object([
            "schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .number(2),
            "turns": .array([turn]), "backgroundTerminals": .array([])
        ])
        return HarnessThreadInput(thread: try HarnessThread(id: "usage-thread", harnessID: "codex", revision: tokens,
            sessionState: state, observation: .init(), cwd: "", settings: .null,
            createdAt: 1, updatedAt: 2, title: "Usage replay", tags: []))
    }
}

private struct ProjectedUsageHost: View {
    let probe: ProjectedUsageProbe
    var body: some View {
        probe.snapshot.card(respond: { _ in }, openThread: {})
            .onAppear { probe.appearances += 1 }
            .environment(\.threadCardTextRasterScale, 2)
            .frame(width: 360, height: 200)
            .background(Color.white)
    }
}

extension RollingNumberCellTests {
    /// Replaces the plugin snapshot as a live catalog revision does. A static
    /// leaf demo cannot detect lost state at the type-erased card boundary.
    @Test func projectedUsageUpdatesKeepTheirAnimation() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Observe projected usage in the native application event loop")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.unhide(nil); app.activate(ignoringOtherApps: true)
        let probe = try ProjectedUsageProbe()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProjectedUsageHost(probe: probe))
        window.center(); window.makeKeyAndOrderFront(nil)
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        var root = try #require(window.contentView)
        let evidenceRoot = ProcessInfo.processInfo.environment["MOKUSEI_ROLLING_NUMBER_ARTIFACTS"]
            ?? ProcessInfo.processInfo.environment["MOKUSEI_CI_EVIDENCE"] ?? "/tmp/mokusei-rolling-number-visual"
        let evidence = URL(fileURLWithPath: evidenceRoot, isDirectory: true)
            .appendingPathComponent("projected-usage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var measurements: [[String: Any]] = []
        var completion: [String: Any] = [:]
        var frames: [String: Data] = [:]
        var passed = true
        defer {
            let receipt: [String: Any] = ["clock": "ProcessInfo.systemUptime", "updates": measurements,
                "final": completion, "applicationRunning": app.isRunning, "applicationActive": app.isActive,
                "windowKey": window.isKeyWindow, "windowVisible": window.isVisible,
                "windowOccluded": !window.occlusionState.contains(.visible),
                "backingScale": window.backingScaleFactor, "width": root.bounds.width, "height": root.bounds.height]
            do {
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                    .write(to: evidence.appendingPathComponent("measurements.json"))
                for (name, png) in frames {
                    try png.write(to: evidence.appendingPathComponent(name + ".png"))
                }
            } catch { Issue.record(Comment(rawValue: "Could not retain projected usage evidence: \(error)")) }
            print("PROJECTED_USAGE_FLIP_EVIDENCE \(evidence.path)")
        }
        func pixels(_ name: String) throws -> Data {
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            // Compare just usage: hover/focus adornments elsewhere on the card
            // must not make a missing digit animation look like a passing frame.
            let cgImage = try #require(image.cgImage)
            let scale = CGFloat(cgImage.width) / root.bounds.width
            let crop = try #require(cgImage.cropping(to: CGRect(x: 16 * scale, y: 58 * scale,
                                                               width: 100 * scale, height: 20 * scale)))
            let png = try #require(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
            frames[name] = png
            return png
        }
        try #require(app.isRunning, "Projected usage animation requires the native AppKit event loop")
        let admissionDeadline = ContinuousClock.now + .seconds(3)
        while !(app.isActive && window.isKeyWindow && window.occlusionState.contains(.visible))
                && ContinuousClock.now < admissionDeadline {
            try await Task.sleep(for: .milliseconds(10), tolerance: .zero)
        }
        try #require(app.isActive && window.isKeyWindow && window.occlusionState.contains(.visible),
                     "Projected usage animation requires an active, visible key window")
        try await Task.sleep(for: .milliseconds(350), tolerance: .zero)
        var before = try pixels("initial")
        var beforeAt = ProcessInfo.processInfo.systemUptime
        // Increase, decrease, grow/shrink, compact-unit change, then an update
        // before its predecessor finishes. Numeric totals also change.
        for (index, tokens) in [9, 10, 957, 111, 999, 1_200, 128].enumerated() {
            var measurement: [String: Any] = ["index": index, "tokens": tokens,
                "beforeImage": index == 0 ? "initial.png" : "\(index - 1)-settled.png",
                "beforeAt": beforeAt,
                "inputAt": ProcessInfo.processInfo.systemUptime]
            defer { measurements.append(measurement) }
            let oldSnapshot = probe.snapshot
            try probe.update(tokens)
            measurement["inputFinishedAt"] = ProcessInfo.processInfo.systemUptime
            let foreground = app.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
            measurement["foregroundAtInput"] = foreground
            #expect(foreground, "Projected usage update must retain its foreground window")
            #expect(probe.snapshot !== oldSnapshot)
            #expect(probe.snapshot.envelope.structureKey == oldSnapshot.envelope.structureKey)
            passed = passed && foreground && probe.snapshot !== oldSnapshot
                && probe.snapshot.envelope.structureKey == oldSnapshot.envelope.structureKey
            // Preserve the original sampling timeline without clock-chosen
            // coalescing leeway. Actual times and all three frames survive failure.
            try await Task.sleep(for: .milliseconds(65), tolerance: .zero)
            measurement["duringStartedAt"] = ProcessInfo.processInfo.systemUptime
            let during = try pixels("\(index)-during")
            measurement["duringFinishedAt"] = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(330), tolerance: .zero)
            measurement["settledStartedAt"] = ProcessInfo.processInfo.systemUptime
            let settled = try pixels("\(index)-settled")
            let settledAt = ProcessInfo.processInfo.systemUptime
            measurement["settledFinishedAt"] = settledAt
            measurement["beforeDiffersFromDuring"] = before != during
            measurement["duringDiffersFromSettled"] = during != settled
            measurement["beforeDiffersFromSettled"] = before != settled
            #expect(before != during && during != settled && before != settled, "Usage update \(tokens) must have an intermediate frame")
            passed = passed && before != during && during != settled && before != settled
            before = settled
            beforeAt = settledAt
        }
        completion["firstInputAt"] = ProcessInfo.processInfo.systemUptime
        try probe.update(456)
        try await Task.sleep(for: .milliseconds(40), tolerance: .zero)
        completion["secondInputAt"] = ProcessInfo.processInfo.systemUptime
        try probe.update(789)
        try await Task.sleep(for: .milliseconds(400), tolerance: .zero)
        let interrupted = try pixels("interrupted-settled")
        completion["interruptedSettledAt"] = ProcessInfo.processInfo.systemUptime
        // Remount only the reference: the updated card must converge to the
        // same authoritative rendering without a stale task restoring a digit.
        let reference = NSHostingView(rootView: ProjectedUsageHost(probe: probe))
        reference.frame = root.bounds
        window.contentView = reference
        root = reference
        try await Task.sleep(for: .milliseconds(350), tolerance: .zero)
        let referencePixels = try pixels("reference")
        completion["referenceAt"] = ProcessInfo.processInfo.systemUptime
        completion["matchesReference"] = interrupted == referencePixels
        completion["appearances"] = probe.appearances
        #expect(interrupted == referencePixels)
        #expect(probe.appearances == 2)
        passed = passed && interrupted == referencePixels && probe.appearances == 2
        if passed { print("PROJECTED_USAGE_FLIP_FRAMES_CONFIRMED") }
    }
}
