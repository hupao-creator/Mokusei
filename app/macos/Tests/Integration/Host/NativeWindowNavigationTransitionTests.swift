import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class NavigationTransitionFixture {
    var action: ThreadDetailBackAction?
    var hidden = false
}
private struct NavigationTransitionReplay: View {
    let fixture: NavigationTransitionFixture
    var body: some View {
        Color.white.overlay(alignment: .topLeading) {
            NativeWindowNavigationView(action: fixture.action, hidden: fixture.hidden)
        }
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeWindowNavigationTransitionTests {
    private func capsule(in view: NSView) -> NSView? {
        let frame = view.frame
        if abs(frame.minX - 12) < 0.1, abs(frame.minY - 16) < 0.1, abs(frame.height - 42) < 0.1 {
            return view
        }
        return view.subviews.lazy.compactMap { capsule(in: $0) }.first
    }

    private func samples(in root: NSView) async throws -> [CGFloat] {
        var widths: [CGFloat] = []
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(40))
            root.layoutSubtreeIfNeeded()
            // Measure rendered native glass, not SwiftUI's target layout size.
            widths.append(capsule(in: root)?.frame.width ?? NativeWindowNavigationGeometry.closedWidth)
        }
        return widths
    }

    @Test func expandsAndClosesThroughIntermediateWidthsAndCanReverse() async throws {
        let fixture = NavigationTransitionFixture()
        let window = SwiftUIReplay.window(NavigationTransitionReplay(fixture: fixture))
        defer { window.close() }
        let root = try #require(window.contentView)
        let closed = NativeWindowNavigationGeometry.closedWidth
        let open = NativeWindowNavigationGeometry.openWidth
        try await Task.sleep(for: .milliseconds(100))
        fixture.action = .init(label: "Return to source", onBack: {})
        let expanding = try await samples(in: root)
        #expect(expanding.contains { $0 > closed + 1 && $0 < open - 1 })
        #expect(abs(try #require(expanding.last) - open) < 0.1)
        #expect(zip(expanding, expanding.dropFirst()).allSatisfy { $0 <= $1 + 0.1 })
        fixture.action = nil
        let closing = try await samples(in: root)
        #expect(closing.contains { $0 > closed + 1 && $0 < open - 1 })
        #expect(abs(try #require(closing.last) - closed) < 0.1)
        #expect(zip(closing, closing.dropFirst()).allSatisfy { $0 >= $1 - 0.1 })
        fixture.action = .init(label: "Return to source", onBack: {})
        try await Task.sleep(for: .milliseconds(70))
        fixture.action = nil
        try await Task.sleep(for: .milliseconds(70))
        fixture.action = .init(label: "History back", onBack: {})
        try await SwiftUIReplay.wait { abs((capsule(in: root)?.frame.width ?? 0) - open) < 0.1 }
        // Changing an execution-history action must not replay the expansion.
        fixture.action = .init(label: "Return to overview", onBack: {})
        let replacing = try await samples(in: root)
        #expect(replacing.allSatisfy { abs($0 - open) < 0.1 })
        fixture.hidden = true
        try await SwiftUIReplay.wait { capsule(in: root) == nil }
        fixture.action = nil
        fixture.hidden = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(capsule(in: root) == nil || abs((capsule(in: root)?.frame.width ?? 0) - closed) < 0.1)
    }
}
