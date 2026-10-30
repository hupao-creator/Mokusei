import Foundation
import CoreText
import Markdown
import MokuseiCore
import SwiftUI

/// Bounded, literal Markdown preview. Buffer scheduling and reveal state stay in
/// this leaf so streaming output never drives the card grid's animation clock.
public struct ThreadCardExcerpt: View {
    public let content: String
    public let messageId: JSONText?
    public let messageText: String?
    @Environment(\.lineLimit) private var inheritedLineLimit
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.threadCardTextReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @State private var buffer = ExcerptBuffer()
    @State private var placeholder: String
    @State private var display: ExcerptDisplay?
    @State private var settledKey: ExcerptKey?
    @State private var reveal: ExcerptReveal?
    @State private var revealProgress: CGFloat = 0

    private var isVisible: Bool { scenePhase != .background && (visibility?.isVisible ?? true) }
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    public init(content: String, messageId: JSONText? = nil, messageText: String? = nil) {
        self.content = content; self.messageId = messageId; self.messageText = messageText
        _placeholder = State(initialValue: content)
    }

    public var body: some View {
        let activeReveal = reveal
        let hold = holdSchedule
        let update = ExcerptUpdate(input: .init(content: content, id: messageId, text: messageText ?? content),
                                   visible: isVisible, animates: !reduceMotion)
        text(display?.text ?? placeholder)
            // The first pass still lays out the raw snapshot at full line-limit
            // height (never collapsed), but stays invisible until the lifecycle
            // installs the processed preview, so the unprocessed placeholder
            // text is never shown and no artificial delay is introduced.
            .opacity(display != nil && reveal == nil ? 1 : 0)
            .overlay(alignment: .topLeading) {
                if let reveal {
                    ZStack(alignment: .topLeading) {
                        text(reveal.incoming)
                            .fixedSize(horizontal: false, vertical: true)
                            .mask(ExcerptInkMask(progress: revealProgress, outgoing: false))
                        text(reveal.previous)
                            .fixedSize(horizontal: false, vertical: true)
                            .mask(ExcerptInkMask(progress: revealProgress, outgoing: true))
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            // Offscreen visual work pauses, but semantic first content still
            // replaces loading. Use the authoritative bounded excerpt without
            // parsing or exposing the full message buffer to accessibility.
            .accessibilityLabel(isVisible ? display?.text ?? placeholder : content)
            .accessibilityHidden(isVisible && display == nil)
            .onAppear {
                // A retained hosting view may reappear without an input edge.
                // The active guard also keeps initial onChange from reparsing.
                if !buffer.active { updatePresentation(update) }
            }
            .onChange(of: update, initial: true) { _, update in
                updatePresentation(update)
            }
            .onDisappear { suspend() }
            .task(id: activeReveal?.key) {
                guard !Task.isCancelled, let active = activeReveal, reveal?.key == active.key else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { revealProgress = 0 }
                await Task.yield()
                guard !Task.isCancelled, buffer.active, buffer.animates, reveal?.key == active.key else { return }
                withAnimation(.linear(duration: 0.28)) { revealProgress = 1 }
                do { try await Task.sleep(for: .milliseconds(280)) } catch { return }

                guard !Task.isCancelled, buffer.active, reveal?.key == active.key else { return }
                reveal = nil; settledKey = active.key
            }
            .task(id: hold) {
                guard !Task.isCancelled, hold == holdSchedule else { return }
                guard let schedule = hold else { buffer.held = nil; return }
                if buffer.held?.key != schedule.key { buffer.held = ExcerptHold(key: schedule.key, since: .now) }
                guard schedule.more, let held = buffer.held else { return }
                let delay = max(0, 0.8 - Date.now.timeIntervalSince(held.since))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, buffer.active, holdSchedule == schedule,
                      var next = buffer.frame, next.key == schedule.key else { return }
                next.advance(to: schedule.absoluteEnd)
                buffer.frame = next
                install(next, animates: buffer.animates)
            }
    }

    private func text(_ value: String) -> some View {
        Text(verbatim: value)
            .cardFont(size: 11.5, lineSpacing: ExcerptTextStyle.lineSpacing)
            .foregroundStyle(NativePalette.pair(0x10110f, 0xe0e5da, alpha: 0.56).swiftUI)
            .lineLimit(inheritedLineLimit ?? 5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var holdSchedule: ExcerptHoldSchedule? {
        guard isVisible, let display, settledKey == display.key else { return nil }
        return display.hold
    }

    private func updatePresentation(_ update: ExcerptUpdate) {
        let changed = buffer.latest != update.input
        buffer.latest = update.input
        buffer.animates = update.animates
        guard update.visible else { suspend(); return }
        guard buffer.active, var next = buffer.frame else {
            buffer.active = true
            let next = ExcerptFrame(content: update.input.content, id: update.input.id, text: update.input.text)
            buffer.frame = next
            // Returning to a retained card shows the current tail immediately;
            // hidden output is never replayed as a backlog of animated batches.
            install(next, animates: false)
            return
        }
        if changed {
            next.update(content: update.input.content, id: update.input.id, text: update.input.text)
            buffer.frame = next
        }
        install(next, animates: update.animates)
    }

    private func suspend() {
        guard buffer.active else { return }
        buffer.active = false
        buffer.frame = nil
        buffer.held = nil
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { reveal = nil; revealProgress = 0; settledKey = display?.key }
    }

    private func install(_ next: ExcerptFrame, animates: Bool) {
        let snapshot = ExcerptDisplay(frame: next)
        if animates, let display, next.key != display.key, next.visible != display.text {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                revealProgress = 0
                reveal = ExcerptReveal(key: next.key, previous: display.text, incoming: next.visible)
                settledKey = nil
            }
        } else if !animates || display == nil || next.key != display?.key {
            if reveal != nil || revealProgress != 0 || settledKey != next.key {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { reveal = nil; revealProgress = 0; settledKey = next.key }
            }
        } else if var active = reveal, active.key == next.key,
                  !active.incoming.utf16.elementsEqual(next.visible.utf16) {
            // Appending to an unfinished batch updates its incoming text without
            // restarting the reveal that already owns this window.
            active.incoming = next.visible
            reveal = active
        }
        // Buffer appends beyond a full window do not invalidate the rendering
        // state; a false→true `more` edge still starts its existing hold schedule.
        if display != snapshot { display = snapshot }
    }
}

/// Source accumulation is deliberately not observable. Only display facts and
/// scheduling edges enter SwiftUI state; hidden input needs no parsing or visual work.
@MainActor private final class ExcerptBuffer {
    var latest: ExcerptInput?
    var active = false
    var animates = true
    var frame: ExcerptFrame?
    var held: ExcerptHold?
}

private struct ExcerptUpdate: Equatable { let input: ExcerptInput; let visible: Bool; let animates: Bool }
private struct ExcerptDisplay: Equatable {
    let key: ExcerptKey
    let text: String
    let hold: ExcerptHoldSchedule?

    init(frame: ExcerptFrame) {
        key = frame.key; text = frame.visible
        hold = frame.hasMessage && !frame.initial && frame.batch.count == ExcerptFrame.batchSize
            ? ExcerptHoldSchedule(key: frame.key, absoluteEnd: frame.origin + frame.batch.end,
                                  more: frame.batch.end < frame.source.length) : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.hold == rhs.hold && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }
}

private struct ExcerptHoldSchedule: Equatable { let key: ExcerptKey; let absoluteEnd: Int; let more: Bool }

private struct ExcerptInput: Equatable {
    let content: String
    let id: JSONText?
    let text: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.content.utf16.elementsEqual(rhs.content.utf16)
            && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }
}
private struct ExcerptKey: Equatable { let session: UUID; let id: JSONText?; let revision: Int; let offset: Int }
private struct ExcerptReveal { let key: ExcerptKey; let previous: String; var incoming: String }
private struct ExcerptHold { let key: ExcerptKey; let since: Date }
private struct ExcerptBatch { let text: String; let end: Int; let count: Int }

@MainActor private enum ExcerptTextStyle {
    static let lineSpacing: CGFloat = {
        NativeTypography.registerFonts()
        let font = CTFontCreateWithName("Inter-Regular" as CFString, 11.5, nil)
        return max(0, 17.825 - (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
    }()
}

private struct ExcerptFrame {
    static let batchSize = 600
    let session = UUID()
    var id: JSONText?
    var source: NSString
    var origin = 0
    var offset: Int
    var revision = 0
    var initial = true
    let snapshot: String
    var visible = ""
    var batch: ExcerptBatch
    var hasMessage: Bool { id?.codeUnits.isEmpty == false }
    var key: ExcerptKey { ExcerptKey(session: session, id: id, revision: revision, offset: origin + offset) }

    init(content: String, id: JSONText?, text: String) {
        self.id = id; source = text as NSString; snapshot = content
        offset = Self.tailStart(source)
        batch = Self.batchAt(source, start: offset)
        refresh(content: content)
    }

    mutating func update(content: String, id: JSONText?, text: String) {
        let next = text as NSString
        if self.id != id || source.length != next.length || source.compare(text, options: .literal) != .orderedSame {
            let sameMessage = self.id == id
            let append = sameMessage && next.length >= source.length
                && next.compare(source as String, options: .literal,
                                range: NSRange(location: 0, length: source.length)) == .orderedSame
            // A proven append cannot change the full displayed window or any
            // Markdown context before it. Partial batches, rewrites and shifted
            // transport windows still prepare their new preview normally.
            let reusePreview = append && hasMessage && !initial && batch.count == Self.batchSize
            let shift = sameMessage && !append ? Self.windowShift(source, next) : 0
            let rewrite = !append && shift == 0
            offset = rewrite ? 0 : shift > offset ? Self.tailStart(next) : offset - shift
            origin = rewrite ? 0 : origin + shift
            revision += rewrite ? 1 : 0
            self.id = id; source = next; initial = false
            if reusePreview { return }
            batch = Self.batchAt(source, start: offset)
        }
        refresh(content: content)
    }

    mutating func advance(to absoluteEnd: Int) {
        offset = absoluteEnd - origin
        batch = Self.batchAt(source, start: offset)
        refresh(content: snapshot)
    }

    private mutating func refresh(content: String) {
        let raw = !hasMessage ? content : initial ? snapshot : batch.text
        var contextOffset = hasMessage ? offset : 0
        var tailMarker = false
        if hasMessage && initial {
            let marked = snapshot.hasPrefix("…")
            let snapshotText = marked ? String(snapshot.dropFirst()) : snapshot
            let match = source.range(of: snapshotText, options: marked ? [.backwards, .literal] : [.literal])
            let found = match.location != NSNotFound
            contextOffset = found ? match.location : 0
            tailMarker = marked && found
        }
        let literal = tailMarker ? String(raw.dropFirst()) : raw
        // Do not copy an unbounded prefix just to discover that preview parsing
        // is over budget. UTF-16 offsets match the renderer's context budget.
        if contextOffset + (literal as NSString).length > ExcerptPreview.budget {
            visible = raw
        } else {
            visible = (tailMarker ? "…" : "") + ExcerptPreview.make(literal, preceding: source.substring(to: contextOffset))
        }
    }

    private static func batchAt(_ text: NSString, start: Int) -> ExcerptBatch {
        var end = start; var count = 0
        while end < text.length && count < batchSize {
            let unit = text.character(at: end)
            end += (0xd800...0xdbff).contains(unit) && end + 1 < text.length
                && (0xdc00...0xdfff).contains(text.character(at: end + 1)) ? 2 : 1
            count += 1
        }
        return ExcerptBatch(text: text.substring(with: NSRange(location: start, length: end - start)), end: end, count: count)
    }

    private static func tailStart(_ text: NSString) -> Int {
        var start = text.length
        for _ in 0..<batchSize {
            guard start > 0 else { break }
            start -= 1
            if (0xdc00...0xdfff).contains(text.character(at: start)), start > 0,
               (0xd800...0xdbff).contains(text.character(at: start - 1)) { start -= 1 }
        }
        return start
    }

    /// Linear overlap search also stays linear for repetitive model output.
    private static func windowShift(_ previous: NSString, _ next: NSString) -> Int {
        guard previous.length > batchSize, next.length >= batchSize else { return 0 }
        var prefix = [Int](repeating: 0, count: next.length)
        var matched = 0
        for index in 1..<next.length {
            while matched > 0 && next.character(at: index) != next.character(at: matched) { matched = prefix[matched - 1] }
            if next.character(at: index) == next.character(at: matched) { matched += 1 }
            prefix[index] = matched
        }
        matched = 0
        // Discard at least one old UTF-16 unit; a full match before the end must
        // fall back before looking up the next character.
        for index in 1..<previous.length {
            while matched > 0 && (matched == next.length || previous.character(at: index) != next.character(at: matched)) {
                matched = prefix[matched - 1]
            }
            if previous.character(at: index) == next.character(at: matched) { matched += 1 }
        }
        return matched >= batchSize ? previous.length - matched : 0
    }
}

/// The original 240%-wide masks travel from x=0 to x=-140% in 280ms. Text
/// remains stationary, with the outgoing ink tail above the incoming layer.
private struct ExcerptInkMask: View, @MainActor Animatable {
    var progress: CGFloat
    let outgoing: Bool
    var animatableData: CGFloat { get { progress } set { progress = newValue } }

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(stops: outgoing ? [
                .init(color: .white, location: 0.45),
                .init(color: .white.opacity(0.36), location: 0.53),
                .init(color: .white.opacity(0.20), location: 0.56),
                .init(color: .clear, location: 0.58),
            ] : [
                .init(color: .clear, location: 0.45),
                .init(color: .white, location: 0.55),
            ], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 2.4, height: geometry.size.height)
                .offset(x: -geometry.size.width * 1.4 * progress)
        }
    }
}

private enum ExcerptPreview {
    static let budget = 16_384
    private static let tokens = try! NSRegularExpression(
        pattern: #"\\[^\r\n]|(?<!!)\[([^\[\]\r\n]+)\]\((?:\\[^\r\n]|[^()\\\r\n]|\([^()\r\n]*\))*\)|(?<!\*)\*\*([^*`\r\n]+)\*\*(?!\*)"#)

    static func make(_ source: String, preceding: String) -> String {
        let boundary = (preceding as NSString).length
        guard boundary + (source as NSString).length <= budget else { return source }
        let input = preceding + source
        let ns = input as NSString
        let positions = SourcePositions(input)
        var code: [NSRange] = []
        func collect(_ node: any Markup) {
            if node is CodeBlock || node is InlineCode {
                if let range = node.range, let start = positions.offset(range.lowerBound), let end = positions.offset(range.upperBound), end >= start {
                    let protectedEnd = node is InlineCode ? inlineCodeEnd(ns, start: start, fallback: end) : end
                    code.append(NSRange(location: start, length: protectedEnd - start))
                }
                return
            }
            node.children.forEach(collect)
        }
        collect(Document(parsing: input, options: [.disableSmartOpts]))
        var result = ""
        func emit(_ start: Int, _ end: Int, replacement: String? = nil) {
            guard end > boundary else { return }
            let lower = max(boundary, start)
            result += start < boundary ? ns.substring(with: NSRange(location: lower, length: end - lower))
                : replacement ?? ns.substring(with: NSRange(location: start, length: end - start))
        }
        func prose(_ start: Int, _ end: Int) {
            guard start < end else { return }
            // Match in a standalone prose slice: lookbehind must not see code.
            let part = ns.substring(with: NSRange(location: start, length: end - start)) as NSString
            var cursor = 0
            for token in tokens.matches(in: part as String, range: NSRange(location: 0, length: part.length)) {
                emit(start + cursor, start + token.range.location)
                let replacement = token.range(at: 1).location != NSNotFound ? token.range(at: 1) : token.range(at: 2)
                emit(start + token.range.location, start + NSMaxRange(token.range),
                     replacement: replacement.location == NSNotFound ? nil : shorten(part.substring(with: replacement)))
                cursor = NSMaxRange(token.range)
            }
            emit(start + cursor, end)
        }
        var cursor = 0
        for span in code.sorted(by: { $0.location < $1.location }) {
            guard NSMaxRange(span) > cursor else { continue }
            prose(cursor, max(cursor, span.location))
            emit(max(cursor, span.location), NSMaxRange(span))
            cursor = NSMaxRange(span)
        }
        prose(cursor, ns.length)
        return result
    }

    private static func inlineCodeEnd(_ source: NSString, start: Int, fallback: Int) -> Int {
        // cmark can omit quote/list prefix width from the final source column
        // of multiline inline code. The AST has already established that this
        // is code; recover its exact end using its matching backtick run.
        guard start < source.length, source.character(at: start) == 0x60 else { return fallback }
        var openingEnd = start
        while openingEnd < source.length, source.character(at: openingEnd) == 0x60 { openingEnd += 1 }
        let delimiterWidth = openingEnd - start
        var cursor = openingEnd
        while cursor < source.length {
            guard source.character(at: cursor) == 0x60 else { cursor += 1; continue }
            let runStart = cursor
            while cursor < source.length, source.character(at: cursor) == 0x60 { cursor += 1 }
            if cursor - runStart == delimiterWidth { return cursor }
        }
        // Keep unresolvable AST source literal instead of guessing prose.
        return source.length
    }

    private static func shorten(_ source: String) -> String {
        let ns = source as NSString
        var result = ""; var cursor = 0
        for token in tokens.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
            let replacement = token.range(at: 1).location != NSNotFound ? token.range(at: 1) : token.range(at: 2)
            result += replacement.location == NSNotFound ? ns.substring(with: token.range) : shorten(ns.substring(with: replacement))
            cursor = NSMaxRange(token.range)
        }
        return result + ns.substring(from: cursor)
    }

    /// swift-markdown source columns count UTF-8 bytes, while NSString and the
    /// renderer count UTF-16 units. Build one bounded map, including CRLF lines.
    private struct SourcePositions {
        let lines: [Int]
        let utf16: [Int]

        init(_ source: String) {
            let bytes = Array(source.utf8)
            var lines = [0]; var index = 0
            while index < bytes.count {
                if bytes[index] == 13 {
                    index += index + 1 < bytes.count && bytes[index + 1] == 10 ? 2 : 1
                    lines.append(index)
                } else {
                    if bytes[index] == 10 { lines.append(index + 1) }
                    index += 1
                }
            }
            var map = [Int](repeating: 0, count: bytes.count + 1)
            var byteOffset = 0; var unitOffset = 0
            for scalar in source.unicodeScalars {
                let width = scalar.utf8.count
                for offset in 0..<width { map[byteOffset + offset] = unitOffset }
                byteOffset += width; unitOffset += scalar.value > 0xffff ? 2 : 1
            }
            map[bytes.count] = unitOffset
            self.lines = lines; utf16 = map
        }

        func offset(_ location: SourceLocation) -> Int? {
            guard location.line > 0, location.line <= lines.count, location.column > 0 else { return nil }
            let byte = lines[location.line - 1] + location.column - 1
            guard utf16.indices.contains(byte) else { return nil }
            return utf16[byte]
        }
    }
}
