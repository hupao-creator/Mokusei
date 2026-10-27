import Foundation

/// One initial application launch, from main to the first mounted workspace content.
/// These are logical UI milestones, not compositor presentation or physical first paint.
@MainActor
public final class NativeStartupPerformance {
    private let startedAt: UInt64
    private var recordingID: UUID?
    private var attached = false
    private var terminal = false
    private var shellAt: UInt64?
    private var dataAt: UInt64?

    /// Capture this before constructing NSApplication and its delegate.
    public init(startedAt: UInt64 = NativePerformance.now()) { self.startedAt = startedAt }

    /// Bind once after the recorder is configured. Never stitch different log sessions together.
    public func attachToRecording() {
        guard !attached else { return }
        attached = true
        recordingID = NativePerformance.recordingID
    }

    public func shellReady() {
        guard canRecord, shellAt == nil else { return }
        let now = NativePerformance.now()
        shellAt = now
        record(.startupShellReady, at: now)
    }

    public func dataReady() {
        guard canRecord, dataAt == nil else { return }
        let now = NativePerformance.now()
        dataAt = now
        record(.startupDataReady, at: now)
    }

    public func contentAppeared() {
        guard canRecord, let dataAt else { return }
        let now = NativePerformance.now()
        var values = ["afterDataMs": elapsed(from: dataAt, to: now)]
        if let shellAt { values["afterShellMs"] = elapsed(from: shellAt, to: now) }
        record(.startupTimeToReady, at: now, values: values)
        terminal = true
    }

    public func fail() { finish(.startupFailed) }
    public func cancel() { finish(.startupCancelled) }

    private var canRecord: Bool {
        guard !terminal, attached else { return false }
        guard let recordingID, recordingID == NativePerformance.recordingID else {
            terminal = true
            return false
        }
        return true
    }

    private func finish(_ metric: NativePerformance.Metric) {
        guard canRecord else { return }
        record(metric, at: NativePerformance.now())
        terminal = true
    }

    private func record(_ metric: NativePerformance.Metric, at time: UInt64, values: [String: Double] = [:]) {
        NativePerformance.sample(metric, milliseconds: elapsed(from: startedAt, to: time), values: values)
    }

    private func elapsed(from start: UInt64, to end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }
}
