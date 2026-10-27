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
        probe.snapshot.card(actions: HarnessThreadActions(interrupt: {}, respond: { _ in },
            invokeHarnessExtension: { _, _ in .null }, forkThread: { _ in "unused" },
            openExternal: { _ in }, openFollowUp: { _ in }), openThread: {})
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
        let probe = try ProjectedUsageProbe()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProjectedUsageHost(probe: probe))
        window.orderFront(nil)
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        var root = try #require(window.contentView)
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
            if let path = ProcessInfo.processInfo.environment["MOKUSEI_ROLLING_NUMBER_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent(name + ".png"))
            }
            return png
        }
        try await Task.sleep(for: .milliseconds(350))
        var before = try pixels("initial")
        // Increase, decrease, grow/shrink, compact-unit change, then an update
        // before its predecessor finishes. Numeric totals also change.
        for (index, tokens) in [9, 10, 957, 111, 999, 1_200, 128].enumerated() {
            let oldSnapshot = probe.snapshot
            try probe.update(tokens)
            #expect(probe.snapshot !== oldSnapshot)
            #expect(probe.snapshot.envelope.structureKey == oldSnapshot.envelope.structureKey)
            try await Task.sleep(for: .milliseconds(65))
            let during = try pixels("\(index)-during")
            try await Task.sleep(for: .milliseconds(330))
            let settled = try pixels("\(index)-settled")
            #expect(before != during && during != settled && before != settled, "Usage update \(tokens) must have an intermediate frame")
            before = settled
        }
        try probe.update(456)
        try await Task.sleep(for: .milliseconds(40))
        try probe.update(789)
        try await Task.sleep(for: .milliseconds(400))
        let interrupted = try pixels("interrupted-settled")
        // Remount only the reference: the updated card must converge to the
        // same authoritative rendering without a stale task restoring a digit.
        let reference = NSHostingView(rootView: ProjectedUsageHost(probe: probe))
        reference.frame = root.bounds
        window.contentView = reference
        root = reference
        try await Task.sleep(for: .milliseconds(350))
        #expect(interrupted == (try pixels("reference")))
        #expect(probe.appearances == 2)
    }
}

extension RollingNumberCellTests {
    @Test func incomingDigitsMoveDownFromAbove() async throws {
        let probe = UsageRollProbe()
        probe.value = "111"
        // Read Observation in a mounted View, rather than capturing its initial value.
        let host = NSHostingView(rootView: DirectionRollHost(probe: probe))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 160, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func inkRows() throws -> [Double] {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return (0..<bitmap.pixelsHigh).map { y in
                (0..<bitmap.pixelsWide).reduce(0.0) { total, x in
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    return total + 1 - Double(color?.redComponent ?? 1)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        probe.value = "888"
        try await Task.sleep(for: .milliseconds(65))
        let during = try inkRows()
        try await Task.sleep(for: .milliseconds(330))
        let settled = try inkRows()
        // Correlate captured glyph ink with the settled incoming digits. In
        // bitmap coordinates, a negative displacement is above the final row.
        let scale = Double(during.count) / 80
        let shifts = Array(-Int(20 * scale)...Int(20 * scale))
        let bestShift = try #require(shifts.max { left, right in
            func correlation(_ shift: Int) -> Double {
                during.indices.reduce(0) { sum, y in
                    let source = y - shift
                    return sum + (settled.indices.contains(source) ? during[y] * settled[source] : 0)
                }
            }
            return correlation(left) < correlation(right)
        })
        #expect(bestShift < 0, "Incoming glyphs must approach their baseline from above")
    }
}

private struct DirectionRollHost: View {
    let probe: UsageRollProbe
    var body: some View {
        RollingNumberText(value: probe.value, fontSize: 40, color: .black)
            .frame(width: 160, height: 80).background(Color.white)
    }
}
