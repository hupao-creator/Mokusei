import MokuseiPluginAPI
import Observation
import SwiftUI

/// A document observation, scoped to the current HTML read/retry and WebKit view.
public struct NativeApplicationHTMLReadiness: Equatable, Sendable {
    public let source: ApplicationHTMLSource
    public let thread: ApplicationThreadRef
    public let generation: UUID
    public let ready: Bool

    public init(source: ApplicationHTMLSource, thread: ApplicationThreadRef, generation: UUID, ready: Bool) {
        self.source = source; self.thread = thread; self.generation = generation; self.ready = ready
    }
}

public struct NativeApplicationHTMLReadinessKey: PreferenceKey {
    public static let defaultValue: NativeApplicationHTMLReadiness? = nil
    public static func reduce(value: inout NativeApplicationHTMLReadiness?, nextValue: () -> NativeApplicationHTMLReadiness?) {
        if let next = nextValue() { value = next }
    }
}

public extension EnvironmentValues {
    @Entry var nativeReportSidecards: NativeReportSidecardPresentation? = nil
}

/// Report and its linked Browser share one selection. The admission task never
/// captures a card: the latest user choice (including closing) wins at completion.
@MainActor @Observable
public final class NativeReportSidecardPresentation {
    public enum Card { case relatedExecutions, browser }
    public private(set) var active: Card?
    public private(set) var pending: Card? = .relatedExecutions
    public private(set) var admitted = false
    public private(set) var selectionID = UUID()
    @ObservationIgnored private var document: NativeApplicationHTMLReadiness?
    @ObservationIgnored private var layoutReady = false
    @ObservationIgnored private var suppressed = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var admission: Task<Void, Never>?

    public init() {}

    public func updateDocument(_ next: NativeApplicationHTMLReadiness?) {
        guard document != next else { return }
        document = next
        invalidateAdmission()
        admitWhenReady()
    }

    public func updateLayout(ready: Bool, suppressed: Bool) {
        guard layoutReady != ready || self.suppressed != suppressed else { return }
        layoutReady = ready; self.suppressed = suppressed
        if suppressed { active = nil; pending = nil }
        if !ready || suppressed { invalidateAdmission() }
        admitWhenReady()
    }

    public func toggle(_ card: Card) {
        guard !suppressed else { return }
        if active == card || pending == card { close(); return }
        open(card)
    }

    public func open(_ card: Card) {
        guard !suppressed else { return }
        if active == card || pending == card { return }
        selectionID = UUID()
        if admitted { pending = nil; active = card }
        else { active = nil; pending = card }
    }

    public func close() { selectionID = UUID(); active = nil; pending = nil }

    public func cancel() {
        close(); invalidateAdmission(); document = nil; layoutReady = false
    }

    private func invalidateAdmission() {
        generation = UUID(); admission?.cancel(); admission = nil; admitted = false
        selectionID = UUID()
        pending = active ?? pending; active = nil
    }

    private func admitWhenReady() {
        guard document?.ready == true, layoutReady, !suppressed, !admitted, admission == nil else { return }
        let token = generation
        admission = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let self, !Task.isCancelled, generation == token,
                  document?.ready == true, layoutReady, !suppressed else { return }
            admitted = true; admission = nil
            selectionID = UUID()
            active = pending; pending = nil
        }
    }
}
