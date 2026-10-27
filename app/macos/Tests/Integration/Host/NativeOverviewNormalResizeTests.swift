import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiPluginUI
@testable import MokuseiUI

private enum NormalResizeMode: String {
    case compact, wide, tall, slots
    var presentation: ThreadCardPresentation {
        let projection: ThreadCardProjection
        if self == .slots {
            projection = .slots(layout: .init(size: .init(cols: 1, rows: 1), identitySize: .init(cols: 1, rows: 1), slots: []))
        } else {
            projection = .standard(extensions: self == .compact ? [] : [.todo(steps: [.init(step: "Working", status: .inProgress)])])
        }
        return try! composeThreadCard(projection, layoutContext: .init(availableCols: self == .tall ? 1 : 3))
    }
}

@MainActor @Observable private final class NormalResizeFixture {
    let state = NativeOverviewCanvasState()
    var mode = NormalResizeMode.compact
    @ObservationIgnored var size = CGSize.zero
    @ObservationIgnored var appearances = 0
    var item: NativeOverviewItem {
        let presentation = mode.presentation
        return .init(id: "thread", columns: presentation.size.cols, rows: presentation.size.rows,
                     structureKey: presentation.key, presentationID: mode.rawValue)
    }
}

private struct NormalResizeCanvas: View {
    let fixture: NormalResizeFixture
    var body: some View {
        NativeOverviewCanvas(items: [fixture.item], sceneKey: "normal-resize", state: fixture.state) { item in
            HarnessThreadCard(identity: .init(title: "Always visible", excerpt: "Original normal content"),
                presentation: NormalResizeMode(rawValue: item.presentationID)!.presentation,
                state: AnyView(Text(item.presentationID)))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.size = $0 }
                .onAppear { fixture.appearances += 1 }
        }
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewNormalResizeTests {
    @Test func normalContentSurvivesFootprintAndCompositionChanges() async throws {
        let fixture = NormalResizeFixture()
        let window = SwiftUIReplay.window(NormalResizeCanvas(fixture: fixture))
        defer { window.close() }
        try await SwiftUIReplay.wait { !fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 1 && fixture.appearances == 1 }
        let appearances = fixture.appearances
        for mode in [NormalResizeMode.wide, .tall, .compact, .slots, .compact] {
            fixture.mode = mode
            let size = mode.presentation.size
            let target = CGSize(width: size.cols * 376 - 16, height: size.rows * 216 - 16)
            try await SwiftUIReplay.wait { !fixture.state.isLayingOut && fixture.size == target }
            #expect(fixture.appearances == appearances)
            #expect(fixture.state.allowsActivation(cardID: "thread"))
        }
    }
}
