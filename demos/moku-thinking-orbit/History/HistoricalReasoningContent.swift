// Restored from b478a1f0e; Electron design provenance and adaptations: ../README.md.
@testable import MokuseiUI
import Foundation

/// Preserve the execution/segment identity and source window that back the
/// bounded display tail. The resident reader can then keep its FIFO cursor when
/// older display text is trimmed or a new reasoning segment begins.
public struct HistoricalReasoningContent: Equatable, Sendable {
    public var text: String
    public var sourceText: String?
    public var sourceOffset: Int
    public var segmentKey: String
    public var options: HistoricalResidentReasoningOptions
    public init(text: String, sourceText: String? = nil, sourceOffset: Int = 0,
                segmentKey: String, options: HistoricalResidentReasoningOptions = .init()) {
        self.text = text; self.sourceText = sourceText; self.sourceOffset = max(0, sourceOffset)
        self.segmentKey = segmentKey; self.options = options
    }
}
