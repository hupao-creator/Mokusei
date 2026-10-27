import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiUI
import MokuseiPluginUI

@MainActor
@Observable private final class EntryFixture {
    var sceneKey = "entry"
    var selectionID: String?
    var items: [NativeOverviewItem]
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    var usesThreadCard = false
    let state: NativeOverviewCanvasState
    init(items: [NativeOverviewItem] = [], memory: NativeOverviewCameraMemory = .init()) {
        self.items = items
        state = .init(memory: memory)
    }
}

private struct EntryCanvas: View {
    let fixture: EntryFixture
    var body: some View {
        NativeOverviewCanvas(items: fixture.items, sceneKey: fixture.sceneKey, state: fixture.state, selectionID: fixture.selectionID) { item in
            Group {
            if fixture.usesThreadCard {
                let projection = ThreadCardProjection.standard(identity: .init(), extensions: item.columns > 1
                    ? [.todo(steps: [.init(step: "Working", status: .inProgress)])] : [])
                let presentation = try! composeThreadCard(projection, layoutContext: .init(availableCols: 3))
                HarnessThreadCard(identity: .init(title: "Thread", excerpt: String(repeating: "Completed work. ", count: 40)),
                                  presentation: presentation)
            } else {
                Text(item.id).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("overview-replay")) } action: { fixture.frames[item.id] = $0 }
            .onAppear { fixture.appearances[item.id, default: 0] += 1 }

        }.coordinateSpace(name: "overview-replay")
    }
}

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewEntryTests {
    private func descendant(_ view: NSView, id: String) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { descendant($0, id: id) }.first
    }

    private func window(_ fixture: EntryFixture) -> NSWindow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EntryCanvas(fixture: fixture))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ fixture: EntryFixture, ids: [String]) async throws {
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            if !fixture.state.isLayingOut, fixture.state.presentedPlacements.map(\.id).sorted() == ids.sorted() && ids.allSatisfy({ fixture.appearances[$0] != nil }) {
                return
            }
        }
        Issue.record("Canvas did not settle to \(ids)")
        throw CancellationError()
    }

    private func verifyEntry(_ fixture: EntryFixture, in window: NSWindow) async throws {
        let content = try #require(window.contentView)
        let expected = NativeOverviewCameraGeometry.fit(.init(left: 0, top: 0, width: 360, height: 200),
            viewport: .init(width: content.bounds.width, height: content.bounds.height, toolbarBottom: 58))
        fixture.items = [.init(id: "first")]
        var samples = 0
        var greatestOffset = 0.0
        var cameraMoved = false
        // Sample throughout entry and the delayed refit/restore interval. A
        // final-position-only assertion misses the upper-left flash entirely.
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            guard let rect = fixture.frames["first"], fixture.state.camera.isInitialized else { continue }
            samples += 1
            greatestOffset = max(greatestOffset, abs(rect.minX - expected.x), abs(rect.minY - expected.y))
            cameraMoved = cameraMoved || !fixture.state.camera.animationFrames.isEmpty
        }
        #expect(samples > 0)
        #expect(greatestOffset < 1)
        #expect(!cameraMoved)
        try await settle(fixture, ids: ["first"])
    }

    @Test func membershipChangesKeepTheSelectedSceneAndManualCamera() async throws {
        let fixture = EntryFixture(items: [.init(id: "first")])
        fixture.sceneKey = "members:first"
        fixture.selectionID = "semantic:design"
        let window = window(fixture)
        defer { window.close() }
        try await settle(fixture, ids: ["first"])
        let appearances = fixture.appearances["first"]
        let transform = NativeOverviewTransform(scale: fixture.state.camera.minimumScale, x: 80, y: 120)
        fixture.state.camera.setManualTransform(transform)
        let snapshots = fixture.state.sceneSnapshotCount
        fixture.sceneKey = "members:first,second"
        fixture.items.append(.init(id: "second"))
        try await settle(fixture, ids: ["first", "second"])
        #expect(fixture.appearances["first"] == appearances)
        #expect(fixture.state.camera.manual && fixture.state.camera.liveTransform == transform)
        #expect(fixture.state.sceneSnapshotCount == snapshots)
    }

    @Test(arguments: [false, true])
    func emptySceneDiscardsOldFramingBeforeFirstEntry(remembered: Bool) async throws {
        let memory = NativeOverviewCameraMemory(current: remembered
            ? (sceneKey: "entry", view: .init(transform: .identity, manual: false)) : nil)
        let fixture = EntryFixture(memory: memory)
        let window = window(fixture)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        try await settle(fixture, ids: [])
        #expect(memory.current == nil)
        try await verifyEntry(fixture, in: window)
    }

    @Test(arguments: [false, true])
    func clearingAndRecreatingCardsResetsManualFraming(switchScene: Bool) async throws {
        let fixture = EntryFixture(items: [.init(id: "previous")])
        let window = window(fixture)
        defer { window.close() }
        try await settle(fixture, ids: ["previous"])
        fixture.state.camera.setManualTransform(.identity)
        #expect(fixture.state.memory.current?.view.manual == true)
        fixture.items = []
        if switchScene { fixture.sceneKey = "empty-filter" }
        try await settle(fixture, ids: [])
        #expect(fixture.state.memory.current == nil)
        try await verifyEntry(fixture, in: window)
        // Further additions still run the existing incremental layout path.
        fixture.items.append(.init(id: "second"))
        try await settle(fixture, ids: ["first", "second"])
        #expect(fixture.state.layoutError == nil)
    }

    @Test func nonemptySceneStillRestoresManualFraming() async throws {
        let remembered = NativeOverviewCameraState(transform: .init(scale: 1.2, x: 120, y: 140), manual: true)
        let fixture = EntryFixture(items: [.init(id: "previous")],
            memory: .init(current: (sceneKey: "entry", view: remembered)))
        let window = window(fixture)
        defer { window.close() }
        try await settle(fixture, ids: ["previous"])
        #expect(fixture.state.camera.live == remembered)
    }

    @Test(arguments: [false, true])
    func removingExtensionShrinksCardAndGlass(switchScene: Bool) async throws {
        let neighbors: [NativeOverviewItem] = [.init(id: "active", columns: 2), .init(id: "report1"), .init(id: "report2"), .init(id: "report3")]
        let fixture = EntryFixture(items: neighbors + [.init(id: "thread", columns: 2, structureKey: "plan")])
        fixture.usesThreadCard = true
        let window = window(fixture)
        defer { window.close() }
        try await settle(fixture, ids: fixture.items.map(\.id))
        fixture.items = neighbors + [.init(id: "thread", structureKey: "summary", completed: true)]
        if switchScene { fixture.sceneKey = "completed-filter" }
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            if !fixture.state.isLayingOut, fixture.state.presentedPlacements.first(where: { $0.id == "thread" })?.columns == 1 { break }
        }
        try await Task.sleep(for: .milliseconds(750))
        let content = try #require(window.contentView)
        let frame = try #require(fixture.frames["thread"])
        let scale = fixture.state.camera.liveTransform.scale
        #expect(abs(frame.width - 360 * scale) < 1)
        #expect(abs(frame.height - 200 * scale) < 1)
    }
}
