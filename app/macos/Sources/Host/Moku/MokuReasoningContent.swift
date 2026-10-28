import Foundation
import MokuseiPluginAPI

/// A bounded display tail and its original UTF-16 source window. Identity belongs
/// to the thread/Harness/execution/foreground segment, never to prose similarity.
public struct MokuReasoningContent: Equatable, Sendable {
    public let text: String
    public let sourceText: String
    public let sourceOffset: Int
    public let segmentKey: String

    public func sharesSegment(with other: Self) -> Bool {
        segmentKey.utf16.elementsEqual(other.segmentKey.utf16)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sharesSegment(with: rhs) && lhs.sourceOffset == rhs.sourceOffset
            && lhs.sourceText.utf16.elementsEqual(rhs.sourceText.utf16)
    }

    public init?(sourceText: String, sourceOffset: Int = 0, segmentKey: String) {
        // Harnesses validate their payloads. The renderer additionally needs a
        // representable absolute source end for FIFO slice arithmetic.
        guard sourceOffset >= 0, sourceOffset <= Int.max - sourceText.utf16.count else { return nil }
        let normalized = MokuReasoningText.trimWhitespace(
            MokuReasoningText.trimWhitespace(MokuReasoningText.normalizedWhitespace(sourceText), fromStart: true),
            fromStart: false)
        var remaining = HarnessMokuPresentation.maximumReasoningTailPoints
        var tail: [Character] = []
        for character in normalized.reversed() {
            let count = character.unicodeScalars.count
            guard count <= remaining else { break }
            remaining -= count; tail.append(character)
        }
        guard !tail.isEmpty else { return nil }
        text = String(tail.reversed())
        self.sourceText = sourceText; self.sourceOffset = sourceOffset; self.segmentKey = segmentKey
    }
}

/// The activity host supplies the only logical clock. Updating text within the
/// same segment never resets it; retiring glyph snapshots belong to that host.
@MainActor public struct MokuReasoningAnimation {
    public private(set) var content: MokuReasoningContent?
    public private(set) var clock = 0.0
    private var length = 0.0
    private var animated = true
    private var reader = MokuReasoningText()
    public var glyphs: [MokuReasoningGlyph] { reader.visible() }
    public var needsFrames: Bool { content != nil && reader.needsFrames }

    public init() {}

    public mutating func configure(_ next: MokuReasoningContent?, length: Double, animated: Bool = true) {
        guard content != next || self.length != length || self.animated != animated else { return }
        let sameSegment = content.flatMap { current in next.map { current.sharesSegment(with: $0) } } ?? false
        if !sameSegment {
            reader = MokuReasoningText(); clock = 0
        }
        content = next; self.length = length; self.animated = animated
        guard let next, length > 0 else { return }
        reader.update(text: next.text, sourceText: next.sourceText, sourceOffset: next.sourceOffset,
            segmentKey: next.segmentKey, mode: animated ? .glide : .direct, length: length,
            measure: NativeMokuReasoningArcPainter.measure)
    }

    public mutating func advance(milliseconds: Double) {
        guard content != nil else { return }
        let dt = max(0, min(64, milliseconds))
        clock += dt
        reader.advance(dt: dt, measure: NativeMokuReasoningArcPainter.measure)
    }
}
