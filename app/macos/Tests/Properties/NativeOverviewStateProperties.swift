import AppKit
import Foundation
import Testing
@testable import MokuseiUI

/// Random point in the mounted production Canvas's input schedule. Events are
/// replayed against the real workspace view machinery, not a simulated planner.
private enum StateEvent: Codable, CustomStringConvertible {
    case insert(String, Int, Int)
    case remove(String)
    case footprint(String, Int, Int)
    case resize(Double, Double)
    case clearances(toolbar: Double, dock: Double)
    case pause(Bool)
    case visible(Bool)
    case manual
    case automatic
    case content(String, Int)

    var description: String {
        switch self {
        case .insert(let id, let columns, let rows): "insert(\(id),\(columns)x\(rows))"
        case .remove(let id): "remove(\(id))"
        case .footprint(let id, let columns, let rows): "footprint(\(id),\(columns)x\(rows))"
        case .resize(let width, let height): "resize(\(width)x\(height))"
        case .clearances(let toolbar, let dock): "clearances(toolbar=\(toolbar),dock=\(dock))"
        case .pause(let value): "pause(\(value))"
        case .visible(let value): "visible(\(value))"
        case .manual: "manual pan"
        case .automatic: "automatic"
        case .content(let id, let revision): "content(\(id),\(revision))"
        }
    }
}

private struct StateTrace: Codable, CustomStringConvertible {
    var seed: UInt64
    var events: [StateEvent]
    var description: String { "seed=\(seed) events=[\n  " + events.map(\.description).joined(separator: ",\n  ") + "\n]" }
}

private struct StateGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x2545_F491_4F6C_DD1D }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func coin() -> Bool { pick(0...1) == 1 }
}

private func generateTrace(seed: UInt64, length: Int = 18) -> StateTrace {
    var random = StateGenerator(seed: seed)
    var events: [StateEvent] = [.clearances(toolbar: Double(random.pick(0...120)), dock: Double(random.pick(0...180)))]
    var live = Set<String>()
    var nextID = 0
    if seed.isMultiple(of: 4) {
        for _ in 0..<random.pick(8...14) {
            let id = "card-\(nextID)"
            nextID += 1
            live.insert(id)
            events.append(.insert(id, 1, random.pick(1...2)))
        }
    }
    for _ in 0..<length {
        switch random.pick(0...8) {
        case 0, 1:
            let id = "card-\(nextID)"; nextID += 1
            live.insert(id)
            events.append(.insert(id, random.pick(1...2), random.pick(1...2)))
        case 2:
            guard let id = live.sorted().randomElement(using: &random) else { continue }
            live.remove(id)
            events.append(.remove(id))
        case 3:
            guard let id = live.sorted().randomElement(using: &random) else { continue }
            events.append(.footprint(id, random.pick(1...2), random.pick(1...2)))
        case 4:
            events.append(.resize(Double(random.pick(500...1500)), Double(random.pick(500...1000))))
        case 5:
            events.append(.pause(random.coin()))
        case 6:
            events.append(.visible(random.coin()))
        case 7:
            events.append(random.coin() ? .manual : .automatic)
        default:
            guard let id = live.sorted().randomElement(using: &random) else { continue }
            events.append(.content(id, random.pick(0...5)))
        }
    }
    return StateTrace(seed: seed, events: events)
}

/// Checked-in reduced trace used as the reproducible regression case. The
/// generator is disabled here; `replay` is the same production-mounted path.
private let reducedInterleavingTrace = StateTrace(seed: 0, events: [
    .insert("a", 1, 1),
    .insert("b", 2, 2),
    .resize(1292, 858),
    .pause(true),
    .insert("c", 1, 2),
    .automatic,
    .visible(false),
    .visible(true),
    .pause(false),
    .content("a", 3),
    .footprint("b", 1, 1),
    .remove("a"),
])

@MainActor
@Suite(.serialized)
struct NativeOverviewStateProperties {
    // PBT-OVERVIEW-STATE: Sources/Host/Overview/README.md
    @Test func randomInterleavingsConvergeToTheLatestSnapshot() async throws {
        guard !NSScreen.screens.isEmpty else {
            print("PBT CAPABILITY: WindowServer/display required")
            throw PropertyFailure("WindowServer/display required")
        }
        let budget = try PropertyBudget(defaultCases: 8)
        let stored = try propertyReplay(StateTrace.self)
        let traces = stored.map { [$0] } ?? [reducedInterleavingTrace] + (0..<budget.cases).map {
            generateTrace(seed: budget.seed &+ UInt64($0))
        }
        for trace in traces {
            if let failure = await replay(trace) {
                try propertyEvidence(trace, name: "original.json")
                print("PBT FAIL PBT-OVERVIEW-STATE original \(trace) failure=\(failure)")
                let reduced = await shrink(trace, failure: failure, seconds: budget.shrinkSeconds)
                try propertyEvidence(reduced, name: "reduced.json")
                Issue.record(Comment(rawValue: "PBT-OVERVIEW-STATE original \(trace) failure=\(failure) reduced \(reduced)"))
                return
            }
        }
        print("PBT PASS PBT-OVERVIEW-STATE seed=\(budget.seed) traces=\(traces.count) replay=\(stored != nil)")
    }

    /// Replay one trace and return its first failed assertion description.
    private func replay(_ trace: StateTrace) async -> String? {
        var items = [NativeOverviewItem]()
        let fixture = OverviewReplayFixture()
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1180, height: 780)
        defer {
            window.close()
            fixture.state.camera.dispose()
        }
        for event in trace.events {
            switch event {
            case .insert(let id, let columns, let rows):
                items.append(.init(id: id, columns: columns, rows: rows))
                fixture.install(items)
            case .remove(let id):
                items.removeAll { $0.id == id }
                fixture.install(items)
            case .footprint(let id, let columns, let rows):
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].columns = columns
                items[index].rows = rows
                fixture.install(items)
            case .resize(let width, let height):
                fixture.size = .init(width: width, height: height)
            case .clearances(let toolbar, let dock):
                fixture.toolbarBottom = toolbar
                fixture.bottomReservedHeight = dock
            case .pause(let value):
                fixture.layoutPaused = value
            case .visible(let value):
                fixture.visible = value
            case .manual:
                fixture.state.camera.pan(deltaX: -120, deltaY: 80)
            case .automatic:
                fixture.state.camera.returnToAuto()
            case .content(let id, let revision):
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].presentationID = "stream-\(revision)"
                fixture.install(items)
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        // Let every pending pause/visibility/manual branch release before the
        // final observation. The trace itself owns the interleaving.
        fixture.layoutPaused = false
        fixture.visible = true
        if fixture.state.camera.manual { fixture.state.camera.returnToAuto() }
        do {
            try await OverviewReplay.settle(fixture, in: window)
        } catch {
            return "did not settle: " + summary(fixture)
        }
        let ids = Set(items.map(\.id))
        if Set(fixture.state.presentedPlacements.map(\.id)) != ids {
            return "presented membership differs: " + summary(fixture)
        }
        if Set(fixture.frames.keys) != ids { return "rendered frames differ: " + summary(fixture) }
        if fixture.projectionError > 1 / window.backingScaleFactor {
            return "camera/card projection differs: " + summary(fixture)
        }
        if !items.isEmpty {
            let usable = fixture.usable
            let world = fixture.worldBounds
            let raw = min(usable.width / world.width, usable.height / world.height)
            let expected = max(1, min(NativeOverviewCameraGeometry.scaleCap, raw))
            if abs(fixture.state.camera.liveTransform.scale - expected) > 1e-6 {
                return "scale does not match FitAll: " + summary(fixture)
            }
            // Equal top/bottom space when the Dock is taller. A taller toolbar
            // keeps half the excess clearance above the center of the cards.
            let center = CGPoint(x: fixture.size.width / 2,
                                 y: (fixture.size.height + max(0, fixture.toolbarBottom - fixture.bottomReservedHeight)) / 2)
            let envelope = fixture.renderedEnvelope
            let pixel = 1 / window.backingScaleFactor
            if abs(envelope.midX - center.x) > pixel || abs(envelope.midY - center.y) > pixel {
                return "automatic center differs: expected=\(center) rendered=\(envelope) " + summary(fixture)
            }
        }
        return nil
    }

    private func shrink(_ trace: StateTrace, failure: String, seconds: Int) async -> StateTrace {
        var best = trace
        var changed = true
        let deadline = ContinuousClock.now + .seconds(seconds)
        while changed && ContinuousClock.now < deadline {
            changed = false
            for index in best.events.indices {
                if ContinuousClock.now >= deadline { return best }
                var candidate = best
                candidate.events.remove(at: index)
                if let next = await replay(candidate), next.components(separatedBy: ": ")[0] == failure.components(separatedBy: ": ")[0] {
                    best = candidate
                    changed = true
                    break
                }
            }
        }
        return best
    }

    private func summary(_ fixture: OverviewReplayFixture) -> String {
        "finalItems=\(fixture.items.map(\.id)) presented=\(fixture.state.presentedPlacements.map(\.id)) "
            + "frames=\(fixture.frames.keys.sorted()) manual=\(fixture.state.camera.manual) "
            + "animating=\(fixture.state.camera.isAnimating) pending=\(fixture.state.camera.hasPendingAutomaticFit) "
            + "layingOut=\(fixture.state.isLayingOut) error=\(fixture.state.layoutError ?? "nil")"
    }
}
