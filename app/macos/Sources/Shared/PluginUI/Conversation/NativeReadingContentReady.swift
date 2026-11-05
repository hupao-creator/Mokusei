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
    @Entry public var nativeReadingContentPreparation: NativeReadingContentPreparation?
}

/// A handoff needs both an admitted row (or readable error) and its Markdown.
/// This is visit-local bookkeeping, not another content loader or timeout.
@MainActor public final class NativeReadingContentPreparation {
    private var requirements: [UUID: Bool] = [:]
    private var ready: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?
    private var finished = false

    public init() {}
    func require(_ id: UUID, ready: Bool) { requirements[id] = ready; schedule() }
    func remove(_ id: UUID) { requirements[id] = nil; schedule() }
    func admit(_ ready: @escaping @MainActor () -> Void) { self.ready = ready; schedule() }
    public func cancel() { finished = true; task?.cancel(); task = nil; ready = nil }

    private func schedule() {
        guard !finished else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            // Let newly admitted row children register before accepting an
            // empty document set. Markdown parsing completes independently.
            await Task.yield()
            guard let self, !Task.isCancelled, !finished, let ready,
                  !requirements.values.contains(false) else { return }
            finished = true; self.ready = nil
            ready()
        }
    }
}

extension View {
    public func nativeReadingContentReady() -> some View { modifier(NativeReadingContentReady()) }
    /// The opaque content owner confirms termination independently of the
    /// catalog. A warm running snapshot cannot acknowledge a completed result.
    public func nativeReadingExecutionReady(_ id: JSONText, settled: Bool) -> some View {
        modifier(NativeReadingExecutionReady(executionID: id, settled: settled))
    }
}

private struct NativeReadingExecutionReady: ViewModifier {
    let executionID: JSONText
    let settled: Bool
    @State private var requirement = UUID()
    @Environment(\.nativeReadingContentHandoff) private var handoff
    @Environment(\.nativeReadingContentReady) private var ready
    @Environment(\.nativeReadingContentPreparation) private var preparation

    func body(content: Content) -> some View {
        content
            .onChange(of: Visit(id: handoff?.id, settled: settled), initial: true) { _, _ in
                guard handoff?.executionID == executionID, let preparation else { return }
                preparation.require(requirement, ready: settled)
                if settled, let ready { preparation.admit(ready) }
            }
            .onDisappear { preparation?.remove(requirement) }
    }
    private struct Visit: Equatable { let id: UUID?; let settled: Bool }
}

private struct NativeReadingContentReady: ViewModifier {
    @Environment(\.nativeReadingContentHandoff) private var handoff
    @Environment(\.nativeReadingContentReady) private var ready
    @Environment(\.nativeReadingContentPreparation) private var preparation
    func body(content: Content) -> some View {
        content
            .transformPreference(NativeReadingContentRevealStatusKey.self) { $0.hasContent = true }
            .task(id: handoff?.id) {
                guard let ready else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let preparation { preparation.admit(ready) }
                else { ready() }
            }
    }
}
