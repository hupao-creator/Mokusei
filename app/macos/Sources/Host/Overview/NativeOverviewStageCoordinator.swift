import Foundation
import Observation

/// One FIFO for spatial effects. The overview owner shares this instance with Moku;
/// card revisions and camera moves cannot run over each other's physical geometry.
/// A layout retains its stage while expanding its adjacent shrink/move/grow beats.
@MainActor @Observable
public final class NativeOverviewStageCoordinator {
    public private(set) var activeOwner: String?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var queue: [Reservation] = []

    private struct Reservation {
        let id: UUID
        let owner: String
        let continuation: CheckedContinuation<NativeOverviewStageLease, any Error>
    }

    public init() {}

    public func acquire(owner: String) async throws -> NativeOverviewStageLease {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if activeID == nil {
                    activeID = id
                    activeOwner = owner
                    continuation.resume(returning: NativeOverviewStageLease(id: id, coordinator: self))
                } else {
                    queue.append(Reservation(id: id, owner: owner, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    fileprivate func release(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        activeOwner = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        activeID = next.id
        activeOwner = next.owner
        next.continuation.resume(returning: NativeOverviewStageLease(id: next.id, coordinator: self))
    }

    private func cancel(_ id: UUID) {
        if activeID == id { release(id); return }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
public final class NativeOverviewStageLease {
    private let id: UUID
    private weak var coordinator: NativeOverviewStageCoordinator?
    fileprivate init(id: UUID, coordinator: NativeOverviewStageCoordinator) {
        self.id = id
        self.coordinator = coordinator
    }
    public func release() {
        coordinator?.release(id)
        coordinator = nil
    }
}
