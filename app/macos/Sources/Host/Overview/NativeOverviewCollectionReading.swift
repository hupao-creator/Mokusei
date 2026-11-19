import Foundation
import MokuseiPluginAPI

/// Evidence belongs to the report, including foreground visits through a unique source Thread.
public struct ApplicationCollectionReading: Codable, Equatable, Sendable {
    static let idleInterval: TimeInterval = 86_400
    public var lastClosedAt: Double?
    var lastQualifiedAt: Double?
    var lastForegroundClose: Double?
    var staysCollected: Bool?

    public init(lastClosedAt: Double? = nil) { self.lastClosedAt = lastClosedAt }

    var valid: Bool {
        [lastClosedAt, lastQualifiedAt, lastForegroundClose].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    func isIdle(createdAt: Double, now: Double) -> Bool {
        staysCollected == true || now >= (lastClosedAt ?? createdAt) + Self.idleInterval
    }

    func visitThreshold(estimate: TimeInterval, openedAt: Double) -> TimeInterval {
        let repeated = lastForegroundClose.map { openedAt >= $0 && openedAt - $0 < Self.idleInterval } ?? false
        return repeated ? 0 : Self.threshold(estimate)
    }

    static func threshold(_ estimate: TimeInterval) -> TimeInterval { min(45, max(5, estimate / 4)) }
}

/// The shell resolves related routes to one owner before advancing this clock.
struct NativeOverviewCollectionVisit {
    let reference: ApplicationThreadRef
    let openedAt: Double
    let threshold: TimeInterval
    private(set) var elapsed: TimeInterval = 0
    private var foregroundSince: TimeInterval?
    private(set) var qualified = false

    init(reference: ApplicationThreadRef, openedAt: Double, estimate: TimeInterval,
         createdAt: Double, evidence: inout ApplicationCollectionReading) {
        self.reference = reference
        self.openedAt = openedAt
        threshold = evidence.visitThreshold(estimate: estimate, openedAt: openedAt)
        evidence.staysCollected = evidence.isIdle(createdAt: createdAt, now: openedAt)
    }

    mutating func advance(visible: Bool, uptime: TimeInterval) {
        if let since = foregroundSince { elapsed += max(0, uptime - since) }
        foregroundSince = visible ? uptime : nil
        qualified = elapsed > 0 && elapsed >= threshold
    }

    func promote(_ evidence: inout ApplicationCollectionReading) {
        evidence.staysCollected = false
        evidence.lastQualifiedAt = openedAt
    }

    func close(at time: Double, evidence: inout ApplicationCollectionReading) {
        evidence.lastClosedAt = time
        if qualified { evidence.lastQualifiedAt = time }
        if elapsed > 0 { evidence.lastForegroundClose = time }
    }
}
