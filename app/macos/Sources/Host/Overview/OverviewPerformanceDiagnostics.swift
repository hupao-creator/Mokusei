#if OVERVIEW_PERF_DIAGNOSTICS
import CoreGraphics
import Foundation
import Synchronization

/// Verification-only counters for the Overview scale harness. This file is
/// inert unless the probe build defines OVERVIEW_PERF_DIAGNOSTICS; it must not
/// publish observable state or alter production decisions.
enum OverviewPerformanceDiagnostics {
    struct Snapshot: Sendable {
        let shellTicks: Int
        let semanticTicks: Int
        let motionSamples: Int
        let zeroTravelSamples: Int
        let activeMotions: Int
        let motionStarts: Int
        let itemsChanges: Int
        let lastItemsChangeUptime: UInt64
        let canvasBodies: Int
        let shellCardBuilds: Int
        let semanticCardBuilds: Int
        let shellFrameBodies: Int
        let semanticFrameBodies: Int
        let swiftUICardBodies: Int
        let workspaceCardBodies: Int
        let layoutValidatePairs: Int
        let layoutIntersectCalls: Int
        let layoutStraightPairs: Int
        let harnessProjectionMisses: Int
        let harnessProjectionHits: Int
        let snapshotCount: Int
        let harnessCacheCount: Int
        let layoutRevisionCount: Int
        let pruneCalls: Int
    }

    struct PresentEvent: Sendable {
        let at: UInt64
        let items: Int
        let outgoing: Int
        let animations: Int
        let animated: Bool
        let repack: Bool
        let initial: Bool
        let replacesScene: Bool
    }

    private static let shellTicks = Atomic<Int>(0)
    private static let semanticTicks = Atomic<Int>(0)
    private static let motionSamples = Atomic<Int>(0)
    private static let zeroTravelSamples = Atomic<Int>(0)
    private static let activeMotions = Atomic<Int>(0)
    private static let motionStarts = Atomic<Int>(0)
    private static let itemsChanges = Atomic<Int>(0)
    private static let lastItemsChangeUptime = Atomic<UInt64>(0)
    private static let canvasBodies = Atomic<Int>(0)
    private static let shellCardBuilds = Atomic<Int>(0)
    private static let semanticCardBuilds = Atomic<Int>(0)
    private static let shellFrameBodies = Atomic<Int>(0)
    private static let semanticFrameBodies = Atomic<Int>(0)
    private static let swiftUICardBodies = Atomic<Int>(0)
    private static let workspaceCardBodies = Atomic<Int>(0)
    private static let layoutValidatePairs = Atomic<Int>(0)
    private static let layoutIntersectCalls = Atomic<Int>(0)
    private static let layoutStraightPairs = Atomic<Int>(0)
    private static let harnessProjectionMisses = Atomic<Int>(0)
    private static let harnessProjectionHits = Atomic<Int>(0)
    private static let snapshotCount = Atomic<Int>(0)
    private static let harnessCacheCount = Atomic<Int>(0)
    private static let layoutRevisionCount = Atomic<Int>(0)
    private static let pruneCalls = Atomic<Int>(0)
    private static let presentEvents = Mutex<[PresentEvent]>([])
    private static let workspaceBodies = Mutex<[String: Int]>([:])
    private static let workspaceTitles = Mutex<[String: String]>([:])
    private static let workspacePresentations = Mutex<[String: String]>([:])
    private static let workspaceCompleted = Mutex<[String: Bool]>([:])
    private static let workspaceLocales = Mutex<[String: String]>([:])
    private static let shellBodies = Mutex<[String: Int]>([:])
    private static let semanticBodies = Mutex<[String: Int]>([:])

    static func reset() {
        shellTicks.store(0, ordering: .relaxed)
        semanticTicks.store(0, ordering: .relaxed)
        motionSamples.store(0, ordering: .relaxed)
        zeroTravelSamples.store(0, ordering: .relaxed)
        activeMotions.store(0, ordering: .relaxed)
        motionStarts.store(0, ordering: .relaxed)
        itemsChanges.store(0, ordering: .relaxed)
        lastItemsChangeUptime.store(0, ordering: .relaxed)
        canvasBodies.store(0, ordering: .relaxed)
        shellCardBuilds.store(0, ordering: .relaxed)
        semanticCardBuilds.store(0, ordering: .relaxed)
        shellFrameBodies.store(0, ordering: .relaxed)
        semanticFrameBodies.store(0, ordering: .relaxed)
        swiftUICardBodies.store(0, ordering: .relaxed)
        workspaceCardBodies.store(0, ordering: .relaxed)
        layoutValidatePairs.store(0, ordering: .relaxed)
        layoutIntersectCalls.store(0, ordering: .relaxed)
        layoutStraightPairs.store(0, ordering: .relaxed)
        harnessProjectionMisses.store(0, ordering: .relaxed)
        harnessProjectionHits.store(0, ordering: .relaxed)
        snapshotCount.store(0, ordering: .relaxed)
        harnessCacheCount.store(0, ordering: .relaxed)
        layoutRevisionCount.store(0, ordering: .relaxed)
        pruneCalls.store(0, ordering: .relaxed)
        presentEvents.withLock { $0.removeAll() }
        workspaceBodies.withLock { $0.removeAll() }
        workspaceTitles.withLock { $0.removeAll() }
        workspacePresentations.withLock { $0.removeAll() }
        workspaceCompleted.withLock { $0.removeAll() }
        workspaceLocales.withLock { $0.removeAll() }
        shellBodies.withLock { $0.removeAll() }
        semanticBodies.withLock { $0.removeAll() }
    }

    static func cardFrameTick(layer: String) {
        if layer == "shell" { shellTicks.add(1, ordering: .relaxed) }
        else { semanticTicks.add(1, ordering: .relaxed) }
    }

    static func motionSample(from: CGRect, to: CGRect) {
        motionSamples.add(1, ordering: .relaxed)
        if from == to { zeroTravelSamples.add(1, ordering: .relaxed) }
    }

    static func motionStarted() {
        activeMotions.add(1, ordering: .relaxed)
        motionStarts.add(1, ordering: .relaxed)
    }

    static func motionFinished() {
        // A cancelled or replaced Canvas may legitimately finish below zero;
        // clamping keeps the gauge diagnostic rather than a failure source.
        activeMotions.add(-1, ordering: .relaxed)
    }

    static func motionsRemoved() { activeMotions.store(0, ordering: .relaxed) }

    static func itemsChanged() {
        itemsChanges.add(1, ordering: .relaxed)
        lastItemsChangeUptime.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
    }

    static func canvasBody() { canvasBodies.add(1, ordering: .relaxed) }
    static func cardBuild(layer: String) {
        if layer == "shell" { shellCardBuilds.add(1, ordering: .relaxed) }
        else { semanticCardBuilds.add(1, ordering: .relaxed) }
    }

    static func frameBody(layer: String) {
        if layer == "shell" { shellFrameBodies.add(1, ordering: .relaxed) }
        else { semanticFrameBodies.add(1, ordering: .relaxed) }
    }

    static func swiftUICardBody() { swiftUICardBodies.add(1, ordering: .relaxed) }
    static func workspaceCardBody() { workspaceCardBodies.add(1, ordering: .relaxed) }

    static func shellBody(itemID: String, completed: Bool) {
        shellBodies.withLock { $0[itemID, default: 0] += 1 }
    }

    static func semanticBody(itemID: String) {
        semanticBodies.withLock { $0[itemID, default: 0] += 1 }
    }

    static func workspaceCard(itemID: String, title: String, presentationID: String,
                              completed: Bool, locale: String) {
        workspaceBodies.withLock { $0[itemID, default: 0] += 1 }
        workspaceTitles.withLock { $0[itemID] = title }
        workspacePresentations.withLock { $0[itemID] = presentationID }
        workspaceCompleted.withLock { $0[itemID] = completed }
        workspaceLocales.withLock { $0[itemID] = locale }
    }

    static func renderedCards() -> [String: Any] {
        ["workspaceBodiesByCard": workspaceBodies.withLock { $0 },
         "renderedTitles": workspaceTitles.withLock { $0 },
         "renderedPresentationIDs": workspacePresentations.withLock { $0 },
         "renderedCompleted": workspaceCompleted.withLock { $0 },
         "renderedLocales": workspaceLocales.withLock { $0 },
         "shellBodiesByCard": shellBodies.withLock { $0 },
         "semanticBodiesByCard": semanticBodies.withLock { $0 }]
    }

    static func layoutIntersectCheck() { layoutIntersectCalls.add(1, ordering: .relaxed) }
    static func layoutValidatePair() { layoutValidatePairs.add(1, ordering: .relaxed) }
    static func layoutStraightPair() { layoutStraightPairs.add(1, ordering: .relaxed) }

    static func harnessProjection(_ hit: Bool) {
        if hit { harnessProjectionHits.add(1, ordering: .relaxed) }
        else { harnessProjectionMisses.add(1, ordering: .relaxed) }
    }

    static func modelRetained(snapshots: Int, harnessCache: Int, revisions: Int) {
        snapshotCount.store(snapshots, ordering: .relaxed)
        harnessCacheCount.store(harnessCache, ordering: .relaxed)
        layoutRevisionCount.store(revisions, ordering: .relaxed)
    }

    static func pruneSnapshotCall() { pruneCalls.add(1, ordering: .relaxed) }

    static func present(items: Int, outgoing: Int, animations: Int, animated: Bool,
                        repack: Bool, initial: Bool, replacesScene: Bool) {
        presentEvents.withLock {
            $0.append(PresentEvent(at: DispatchTime.now().uptimeNanoseconds, items: items, outgoing: outgoing,
                animations: animations, animated: animated, repack: repack, initial: initial,
                replacesScene: replacesScene))
            if $0.count > 4_096 { $0.removeFirst($0.count - 4_096) }
        }
    }

    static func snapshot() -> Snapshot {
        snapshotsLock.lock()
        defer { snapshotsLock.unlock() }
        return Snapshot(shellTicks: shellTicks.load(ordering: .relaxed),
            semanticTicks: semanticTicks.load(ordering: .relaxed),
            motionSamples: motionSamples.load(ordering: .relaxed),
            zeroTravelSamples: zeroTravelSamples.load(ordering: .relaxed),
            activeMotions: max(0, activeMotions.load(ordering: .relaxed)),
            motionStarts: motionStarts.load(ordering: .relaxed),
            itemsChanges: itemsChanges.load(ordering: .relaxed),
            lastItemsChangeUptime: lastItemsChangeUptime.load(ordering: .relaxed),
            canvasBodies: canvasBodies.load(ordering: .relaxed),
            shellCardBuilds: shellCardBuilds.load(ordering: .relaxed),
            semanticCardBuilds: semanticCardBuilds.load(ordering: .relaxed),
            shellFrameBodies: shellFrameBodies.load(ordering: .relaxed),
            semanticFrameBodies: semanticFrameBodies.load(ordering: .relaxed),
            swiftUICardBodies: swiftUICardBodies.load(ordering: .relaxed),
            workspaceCardBodies: workspaceCardBodies.load(ordering: .relaxed),
            layoutValidatePairs: layoutValidatePairs.load(ordering: .relaxed),
            layoutIntersectCalls: layoutIntersectCalls.load(ordering: .relaxed),
            layoutStraightPairs: layoutStraightPairs.load(ordering: .relaxed),
            harnessProjectionMisses: harnessProjectionMisses.load(ordering: .relaxed),
            harnessProjectionHits: harnessProjectionHits.load(ordering: .relaxed),
            snapshotCount: snapshotCount.load(ordering: .relaxed),
            harnessCacheCount: harnessCacheCount.load(ordering: .relaxed),
            layoutRevisionCount: layoutRevisionCount.load(ordering: .relaxed),
            pruneCalls: pruneCalls.load(ordering: .relaxed))
    }

    static func takePresentEvents() -> [PresentEvent] {
        snapshotsLock.lock()
        defer { snapshotsLock.unlock() }
        return presentEvents.withLock { events in
            let result = events
            events.removeAll()
            return result
        }
    }

    // Snapshot/take are called at segment boundaries, never per frame.
    private static let snapshotsLock = NSLock()
}
#endif
