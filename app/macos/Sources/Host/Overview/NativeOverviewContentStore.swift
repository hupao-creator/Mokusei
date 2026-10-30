import Observation
import Foundation

/// The canvas observes membership/geometry; mounted cards observe their own
/// content. A structural incarnation has its own slot so an outgoing card never
/// adopts a newer, incompatible footprint while a layout revision is queued.
@MainActor @Observable
public final class NativeOverviewContentStore {
    public private(set) var structureRevision: UInt64 = 0
    public private(set) var isEmpty = true
    @ObservationIgnored public private(set) var items: [NativeOverviewItem] = []
    @ObservationIgnored private(set) var records: [String: NativeOverviewItem] = [:]
    @ObservationIgnored private(set) var activeIDs = Set<String>()
    @ObservationIgnored private(set) var attentionIDs = Set<String>()
    @ObservationIgnored private var structure: [String] = []
    @ObservationIgnored private var slots: [String: OverviewCardContentState] = [:]
    @ObservationIgnored private var retained: [UUID: Set<String>] = [:]
    @ObservationIgnored private var observers: [UUID: (Change) -> Void] = [:]

    struct Change {
        let structure: Bool
        let carousel: Bool
        let attention: Bool
    }

    public init(items: [NativeOverviewItem] = []) { install(items) }

    /// Called at the admitted model transaction boundary, independently of
    /// SwiftUI rendering. Structural history remains in the model's FIFO.
    public func install(_ next: [NativeOverviewItem]) {
        let nextStructure = next.map(\.structuralIdentity)
        let nextRecords = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let nextAttention = Set(next.filter(\.needsAttention).map(\.id))
        let changedStructure = structure != nextStructure
        let changedCarousel = changedStructure || next.contains { records[$0.id]?.carouselEligible != $0.carouselEligible }
        let changedAttention = attentionIDs != nextAttention
        items = next
        records = nextRecords
        activeIDs = Set(nextRecords.keys)
        attentionIDs = nextAttention
        structure = nextStructure
        for item in next {
            if let existing = slots[item.structuralIdentity] { existing.install(item) }
            else { slots[item.structuralIdentity] = OverviewCardContentState(item) }
        }
        prune()
        if isEmpty != next.isEmpty { isEmpty = next.isEmpty }
        if changedStructure { structureRevision &+= 1 }
        if changedStructure || changedCarousel || changedAttention {
            let change = Change(structure: changedStructure, carousel: changedCarousel, attention: changedAttention)
            for observer in Array(observers.values) { observer(change) }
        }
    }

    func slot(for item: NativeOverviewItem) -> OverviewCardContentState {
        if let existing = slots[item.structuralIdentity] { return existing }
        // A queued historical incarnation may no longer be in the current
        // collection. Its captured snapshot remains the authority for this slot.
        let slot = OverviewCardContentState(item)
        slots[item.structuralIdentity] = slot
        return slot
    }

    func observe(owner: UUID, change: @escaping (Change) -> Void) { observers[owner] = change }

    func retain(_ keys: Set<String>, owner: UUID) {
        retained[owner] = keys
        prune()
    }

    func release(owner: UUID) {
        observers.removeValue(forKey: owner)
        retained.removeValue(forKey: owner)
        prune()
    }

    func stop() {
        observers.removeAll()
        retained.removeAll()
        install([])
    }

    /// Includes the last compatible content of cards removed from the current
    /// collection. Reading this never publishes another canvas update.
    var retainedPresentationIDs: Set<String> {
        Set(retained.values.flatMap { $0 }.compactMap { slots[$0]?.item.presentationID })
    }

    private func prune() {
        let used = Set(structure).union(retained.values.flatMap { $0 })
        slots = slots.filter { used.contains($0.key) }
    }
}

@MainActor @Observable
final class OverviewCardContentState {
    nonisolated let id: String
    nonisolated let structuralIdentity: String
    private(set) var item: NativeOverviewItem
    private(set) var completed: Bool

    init(_ item: NativeOverviewItem) {
        id = item.id; structuralIdentity = item.structuralIdentity
        self.item = item; completed = item.completed
    }

    func install(_ next: NativeOverviewItem) {
        if item != next { item = next }
        if completed != next.completed { completed = next.completed }
    }
}
