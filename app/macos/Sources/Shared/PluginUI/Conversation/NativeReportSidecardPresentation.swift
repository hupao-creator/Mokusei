import MokuseiPluginAPI
import Observation
import SwiftUI

/// Destination geometry and the exact execution shown by the Report reader.
/// The host owns the resident composer; the application contributes no input.
public struct NativeReportExecutionInput: Equatable, Sendable {
    public let reference: ApplicationExecutionRef
    public let frame: CGRect
    public let ready: Bool
    public init(reference: ApplicationExecutionRef, frame: CGRect, ready: Bool = true) {
        self.reference = reference; self.frame = frame; self.ready = ready
    }
}

public struct NativeReportExecutionInputKey: PreferenceKey {
    public static let defaultValue: NativeReportExecutionInput? = nil
    public static func reduce(value: inout NativeReportExecutionInput?, nextValue: () -> NativeReportExecutionInput?) {
        if let next = nextValue() { value = next }
    }
}

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
    public private(set) var selectedExecution: ApplicationExecutionRef?
    public private(set) var executionVisit = UUID()
    public private(set) var continuedExecution = false
    public private(set) var executionReady = false
    @ObservationIgnored private var document: NativeApplicationHTMLReadiness?
    @ObservationIgnored private var layoutReady = false
    @ObservationIgnored private var suppressed = false
    @ObservationIgnored public private(set) var retainingForReturn = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var admission: Task<Void, Never>?
    @ObservationIgnored public var onExecutionSelection: ((ApplicationExecutionRef?) -> Void)?

    public init() {}

    public func selectExecution(_ reference: ApplicationExecutionRef?) {
        guard !retainingForReturn else { return }
        selectionID = UUID(); executionVisit = UUID()
        selectedExecution = reference; continuedExecution = false; executionReady = false
        publishExecutionSelection()
    }

    public func continueExecution(_ reference: ApplicationExecutionRef, from source: ApplicationExecutionRef, selection: UUID) {
        guard !retainingForReturn, !suppressed, active == .relatedExecutions,
              selectionID == selection, selectedExecution == source, reference != source else { return }
        selectExecution(reference)
        continuedExecution = true
    }

    public func admitExecution(visit: UUID) {
        guard executionVisit == visit, selectedExecution != nil else { return }
        executionReady = true
    }

    public func updateDocument(_ next: NativeApplicationHTMLReadiness?) {
        guard !retainingForReturn, document != next else { return }
        document = next
        invalidateAdmission()
        admitWhenReady()
    }

    public func updateLayout(ready: Bool, suppressed: Bool, retainingForReturn: Bool = false) {
        if retainingForReturn {
            // Close preparation must revoke admission/input without folding the
            // visible selection. Unmounting the completed visit calls cancel().
            self.retainingForReturn = true
            generation = UUID(); admission?.cancel(); admission = nil
            return
        }
        let wasReturning = self.retainingForReturn
        self.retainingForReturn = false
        guard wasReturning || layoutReady != ready || self.suppressed != suppressed else { return }
        layoutReady = ready; self.suppressed = suppressed
        if suppressed { active = nil; pending = nil }
        if !ready || suppressed { invalidateAdmission() }
        admitWhenReady()
    }

    public func toggle(_ card: Card) {
        guard !suppressed, !retainingForReturn else { return }
        if active == card || pending == card { close(); return }
        open(card)
    }

    public func open(_ card: Card) {
        guard !suppressed, !retainingForReturn else { return }
        if active == card || pending == card { return }
        selectionID = UUID()
        if admitted { pending = nil; active = card }
        else { active = nil; pending = card }
        publishExecutionSelection()
    }

    public func close() {
        guard !retainingForReturn else { return }
        selectionID = UUID(); active = nil; pending = nil
        publishExecutionSelection()
    }

    public func cancel() {
        retainingForReturn = false
        selectExecution(nil)
        close(); invalidateAdmission(); document = nil; layoutReady = false
    }

    private func invalidateAdmission() {
        generation = UUID(); admission?.cancel(); admission = nil; admitted = false
        selectionID = UUID()
        pending = active ?? pending; active = nil
    }

    private func publishExecutionSelection() {
        onExecutionSelection?(active == .relatedExecutions || pending == .relatedExecutions ? selectedExecution : nil)
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
            publishExecutionSelection()
        }
    }
}
