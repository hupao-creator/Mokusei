import Observation
import SwiftUI

/// Window chrome receives only the active reading viewport's threshold position. It never
/// observes arbitrary ScrollViews, horizontal code panes, or private messages.
@MainActor @Observable
public final class NativeReadingNavigationState {
    public nonisolated static let hideAfter: CGFloat = 80
    public nonisolated static let showWithin: CGFloat = 40

    public struct Viewport: Equatable, Sendable {
        public enum Position: Equatable, Sendable {
            case withinShowThreshold
            case betweenThresholds
            case beyondHideThreshold
        }
        public let source: UUID
        public let position: Position

        fileprivate init(source: UUID, scrollTop: CGFloat) {
            self.source = source
            if scrollTop <= NativeReadingNavigationState.showWithin { position = .withinShowThreshold }
            else if scrollTop > NativeReadingNavigationState.hideAfter { position = .beyondHideThreshold }
            else { position = .betweenThresholds }
        }
    }
    public private(set) var viewport: Viewport?
    @ObservationIgnored private var sources: [UUID: (offset: CGFloat, order: UInt64)] = [:]
    @ObservationIgnored private var sequence: UInt64 = 0
    // Write entry points must not read the observable getter while a parent
    // hosting view is updating. That read would subscribe the message tree to
    // subsequent navigation changes. Chrome observes only source/threshold changes.
    @ObservationIgnored private var publishedViewport: Viewport?
    public init() {}

    public func update(source: UUID, scrollTop: CGFloat, active: Bool) {
        guard active else { remove(source: source); return }
        guard scrollTop.isFinite else { return }
        let offset = max(0, scrollTop)
        if sources[source]?.offset == offset, publishedViewport?.source == source { return }
        sequence &+= 1
        sources[source] = (offset, sequence)
        let next = Viewport(source: source, scrollTop: offset)
        publish(next)
    }
    public func remove(source: UUID) {
        sources[source] = nil
        guard publishedViewport?.source == source else { return }
        if let next = sources.max(by: { $0.value.order < $1.value.order }) {
            publish(Viewport(source: next.key, scrollTop: next.value.offset))
        } else { publish(nil) }
    }
    private func publish(_ next: Viewport?) {
        guard publishedViewport != next else { return }
        publishedViewport = next
        viewport = next
    }
}
private struct NativeReadingNavigationKey: EnvironmentKey {
    static let defaultValue: NativeReadingNavigationState? = nil
}
public extension EnvironmentValues {
    /// Inject on the active reading surface, not on overview or settings.
    var nativeReadingNavigation: NativeReadingNavigationState? {
        get { self[NativeReadingNavigationKey.self] }
        set { self[NativeReadingNavigationKey.self] = newValue }
    }
}
