import Foundation

enum MokuReasoningStreamStyle: String, Sendable {
    case direct
    case glide
}

public struct MokuReasoningGlyph: Equatable, Sendable {
    public let value: String
    public let position: Double
    public let opacity: Double
}

/// Source-position FIFO for the thinking arc. Only completely exited glyphs
/// leave the measured window; incoming batches never skip unread middle text.
/// Source offsets count UTF-16 code units, matching JavaScript string offsets.
struct MokuReasoningText: Sendable {
    private var input = ""
    private var inputOffset = 0
    private var segment: String?
    private var mode: MokuReasoningStreamStyle = .direct
    private var pending = [String]()
    private var glyphs = [String]()
    private var boundaries = [0.0]
    private var latestCount = 0
    private var trailingSpace = false
    private var offset = 0.0
    private var width = 0.0
    private var target = 0.0
    private var length = 0.0

    init() {}

    mutating func update(
        text: String,
        sourceText: String? = nil,
        sourceOffset: Int = 0,
        segmentKey: String,
        mode: MokuReasoningStreamStyle,
        length: Double,
        measure: (String) -> Double
    ) {
        let nextInput = sourceText ?? text
        let sameSegment = segment.map { $0.utf16.elementsEqual(segmentKey.utf16) } ?? false
        if sameSegment && nextInput.utf16.elementsEqual(input.utf16)
            && sourceOffset == inputOffset && mode == self.mode && length == self.length {
            return
        }

        let end = inputOffset + (input as NSString).length
        let nextEnd = sourceOffset + (nextInput as NSString).length
        let overlapStart = max(sourceOffset, inputOffset)
        let overlapEnd = min(end, nextEnd)
        let continuous = sourceOffset <= end && nextEnd >= end && Self.sameSlice(
            input, from: overlapStart - inputOffset, to: overlapEnd - inputOffset,
            nextInput, from: overlapStart - sourceOffset, to: overlapEnd - sourceOffset
        )
        let reset = !sameSegment || !continuous
        let resume = self.mode == .direct && mode != .direct
        let latest = text.map(String.init)
        latestCount = latest.count
        self.length = length
        target = (length + min(length, latest.reduce(0) { $0 + measure($1) + 1.3 })) / 2
        self.mode = mode

        if mode == .direct || (resume && !reset) {
            pending = []
            glyphs = latest
            trailingSpace = nextInput.unicodeScalars.last.map(Self.isWhitespace) ?? false
            measureGlyphs(measure)
            offset = target
        } else if reset {
            pending = []
            glyphs = []
            width = 0
            offset = 0
            trailingSpace = false
            append(nextInput)
            feed(measure: measure, limit: max(1, latest.count))
            offset = max(width, (length + width) / 2)
            feed(measure: measure)
        } else {
            append((nextInput as NSString).substring(from: end - sourceOffset))
            feed(measure: measure)
        }

        input = nextInput
        inputOffset = sourceOffset
        segment = segmentKey
    }

    mutating func advance(dt: Double, measure: (String) -> Double) {
        guard mode != .direct else { return }
        let obsolete = max(0, min(glyphs.count, glyphs.count + pending.count - latestCount))
        let destination = obsolete > 0 ? min(target, width - boundaries[1]) : target
        let distance = destination - offset
        let direction = distance == 0 ? 0.0 : (distance > 0 ? 1.0 : -1.0)
        offset += direction * min(abs(distance) * (1 - exp(-dt / 72)), 120 * dt / 1000)
        if abs(destination - offset) < 0.02 {
            offset = destination
        }
        var exited = 0
        while exited < obsolete && offset - width + boundaries[exited + 1] <= 0 {
            exited += 1
        }
        if exited > 0 {
            glyphs.removeFirst(exited)
            measureGlyphs(measure)
        }
        if !pending.isEmpty {
            feed(measure: measure)
        }
    }

    func visible() -> [MokuReasoningGlyph] {
        glyphs.enumerated().compactMap { index, glyph in
            let center = offset - width + (boundaries[index] + boundaries[index + 1]) / 2
            guard center >= 0 && center <= length else { return nil }
            let fade = min(1, center / 22, (length - center) / 22)
            return MokuReasoningGlyph(
                value: glyph,
                position: length != 0 ? center / length : 0.5,
                opacity: fade
            )
        }
    }

    var needsFrames: Bool {
        mode != .direct && (!pending.isEmpty || glyphs.count > latestCount || abs(target - offset) > 0.02)
    }

    private mutating func measureGlyphs(_ measure: (String) -> Double) {
        boundaries = [0]
        boundaries.reserveCapacity(glyphs.count + 1)
        for glyph in glyphs {
            boundaries.append(boundaries[boundaries.count - 1] + measure(glyph) + 1.3)
        }
        width = boundaries[boundaries.count - 1]
    }

    private mutating func feed(measure: (String) -> Double, limit: Int = 112) {
        let before = width
        let count = min(pending.count, max(0, limit - glyphs.count))
        glyphs.append(contentsOf: pending.prefix(count))
        pending.removeFirst(count)
        measureGlyphs(measure)
        offset += width - before
    }

    private mutating func append(_ delta: String) {
        let normalized = Self.normalizedWhitespace((trailingSpace ? " " : "") + delta)
        trailingSpace = normalized.unicodeScalars.last.map(Self.isWhitespace) ?? false
        let addition = Self.trimWhitespace(normalized, fromStart: false)
        guard !addition.isEmpty else { return }
        if let previous = pending.popLast() {
            pending.append(contentsOf: (previous + addition).map(String.init))
        } else if !glyphs.isEmpty {
            let index = glyphs.count - 1
            let joined = (glyphs[index] + addition).map(String.init)
            glyphs[index] = joined[0]
            pending.append(contentsOf: joined.dropFirst())
        } else {
            pending.append(contentsOf: Self.trimWhitespace(addition, fromStart: true).map(String.init))
        }
    }

    /// String equality in the source compares code units, not canonical Unicode forms.
    private static func sameSlice(
        _ lhs: String, from lhsStart: Int, to lhsEnd: Int,
        _ rhs: String, from rhsStart: Int, to rhsEnd: Int
    ) -> Bool {
        let left = lhs.utf16.dropFirst(lhsStart).prefix(lhsEnd - lhsStart)
        let right = rhs.utf16.dropFirst(rhsStart).prefix(rhsEnd - rhsStart)
        return left.elementsEqual(right)
    }

    /// ECMAScript's whitespace set differs from Foundation's whitespace classes.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    static func normalizedWhitespace(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        var wasWhitespace = false
        for scalar in value.unicodeScalars {
            if isWhitespace(scalar) {
                if !wasWhitespace {
                    result.append(" ")
                }
                wasWhitespace = true
            } else {
                result.append(scalar)
                wasWhitespace = false
            }
        }
        return String(result)
    }

    static func trimWhitespace(_ value: String, fromStart: Bool) -> String {
        if fromStart {
            return String(String.UnicodeScalarView(value.unicodeScalars.drop(while: isWhitespace)))
        }
        var scalars = value.unicodeScalars
        while let last = scalars.last, isWhitespace(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }
}
