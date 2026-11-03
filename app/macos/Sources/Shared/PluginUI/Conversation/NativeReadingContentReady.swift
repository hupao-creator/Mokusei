import Foundation
import MokuseiCore
import SwiftUI

/// A mounted destination acknowledges content (including readable errors), so
/// a retained source can cover loading without guessing from elapsed time.
public struct NativeReadingContentHandoff {
    public let id: UUID
    public let executionID: JSONText
    public let ready: @MainActor () -> Void
    public init(id: UUID, executionID: JSONText, ready: @escaping @MainActor () -> Void) {
        self.id = id; self.executionID = executionID; self.ready = ready
    }
}

extension EnvironmentValues {
    @Entry public var nativeReadingContentHandoff: NativeReadingContentHandoff?
    @Entry public var nativeReadingContentReady: (@MainActor () -> Void)?
}

extension View {
    public func nativeReadingContentReady() -> some View { modifier(NativeReadingContentReady()) }
}

private struct NativeReadingContentReady: ViewModifier {
    @Environment(\.nativeReadingContentHandoff) private var handoff
    @Environment(\.nativeReadingContentReady) private var ready
    func body(content: Content) -> some View {
        content.task(id: handoff?.id) {
            guard let ready else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            ready()
        }
    }
}
