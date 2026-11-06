import AppKit
import Observation
import SwiftUI

public extension EnvironmentValues {
    /// Agent reader admission only; other Markdown consumers keep their normal drawing.
    @Entry var nativeThreadContentReveal = false
    /// Keep parse/admission readiness even when existing content needs no ink entrance.
    @Entry var nativeThreadContentRevealAnimated = true
}
extension EnvironmentValues {
    @Entry var nativeThreadReveal: NativeThreadContentReveal? = nil
}

/// Readable content and unfinished ink are independent: a loaded row may still
/// be parsing Markdown or revealing its last line. Only the active reader exports
/// this preference; retained history and Sidecards cannot admit its composer.
public struct NativeReadingContentRevealStatus: Equatable, Sendable {
    var hasContent = false
    var revealing = false
    public init() {}
    public var complete: Bool { hasContent && !revealing }
}

public struct NativeReadingContentRevealStatusKey: PreferenceKey {
    public static let defaultValue = NativeReadingContentRevealStatus()
    public static func reduce(value: inout NativeReadingContentRevealStatus,
                              nextValue: () -> NativeReadingContentRevealStatus) {
        let next = nextValue()
        value.hasContent = value.hasContent || next.hasContent
        value.revealing = value.revealing || next.revealing
    }
}

/// One mounted execution owns its first content entrance, never its data or
/// subscriptions. Later streaming updates and newly disclosed work stay immediate.
@MainActor @Observable
final class NativeThreadContentReveal: NSObject, @preconcurrency CAAnimationDelegate {
    // Scale only entrance choreography; layout/readiness waits keep their own timing.
    private static let revealSpeed = 1.32

    private final class WeakText {
        weak var view: MarkdownTextView?
        init(_ view: MarkdownTextView) { self.view = view }
    }
    private final class WeakRow {
        weak var view: ThreadRevealRowView?
        init(_ view: ThreadRevealRowView) { self.view = view }
    }
    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    // Native registration is bookkeeping, not SwiftUI presentation state.
    // Observing it invalidates previously mounted readers as siblings register.
    @ObservationIgnored private var texts: [ObjectIdentifier: WeakText] = [:]
    @ObservationIgnored private var rows: [ObjectIdentifier: WeakRow] = [:]
    @ObservationIgnored private var documents: [UUID: Bool] = [:]
    @ObservationIgnored private var masks: [(WeakView, CALayer)] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var admitted = false
    @ObservationIgnored private var started = false
    private var finished = false
    private var cancelled = false
    var settled: Bool { finished || cancelled }
    private(set) var footerVisible = false
    private(set) var bottomUp = false
    private(set) var animatedLineCount = 0
    private(set) var initialDrawingProtected = false
    @ObservationIgnored private var reducedMotion = false

    func beginDocument(_ id: UUID) {
        guard !cancelled, !finished, !started else { return }
        if documents[id] == nil { documents[id] = false }
    }
    func documentReady(_ id: UUID) {
        guard !cancelled, !finished, !started else { return }
        documents[id] = true; schedule()
    }
    func endDocument(_ id: UUID) { documents[id] = nil; schedule() }
    func contentChanged(_ view: NSView) {
        if started, masks.contains(where: { $0.0.view === view }) { finish() }
    }
    func register(_ view: MarkdownTextView) {
        guard !cancelled, !finished, !started else { return }
        texts[ObjectIdentifier(view)] = WeakText(view)
        view.awaitsLineReveal = true
        schedule()
    }
    func unregister(_ view: MarkdownTextView) {
        texts[ObjectIdentifier(view)] = nil
        view.admitLineReveal()
    }
    func register(_ view: ThreadRevealRowView) {
        guard !cancelled, !finished, !started else { return }
        rows[ObjectIdentifier(view)] = WeakRow(view)
        view.awaitsLineReveal = true
        schedule()
    }
    func unregister(_ view: ThreadRevealRowView) {
        rows[ObjectIdentifier(view)] = nil
        view.awaitsLineReveal = false
    }
    func begin(bottomUp: Bool, reducedMotion: Bool) {
        guard !cancelled, !finished else { return }
        admitted = true
        self.bottomUp = bottomUp; self.reducedMotion = reducedMotion
        if started && reducedMotion { finish(); return }
        schedule()
    }
    private func schedule() {
        guard admitted, !cancelled, !finished, !started else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            // Coalesce asynchronous Markdown block mounting and the reader's
            // follow-to-latest layout before sampling actual line fragments.
            do { try await Task.sleep(for: .milliseconds(48)) } catch { return }
            guard let self else { return }
            // Parsing owns readiness; no guessed timeout may admit an empty
            // document and consume its entrance before its text arrives.
            guard !documents.values.contains(false) else { return }
            // Reduced motion removes ink travel, not data/parse readiness.
            if reducedMotion { finish(); return }
            for _ in 0..<12 {
                if animate() { return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            finish()
        }
    }
    private func animate() -> Bool {
        let live = texts.values.compactMap(\.view)
        let liveRows = rows.values.compactMap(\.view)
        guard let window = live.first?.window ?? liveRows.first?.window, let root = window.contentView else { return false }
        var lines: [(NSView, CGRect, CGFloat)] = []
        for text in live where text.window === window {
            guard text.bounds.width > 0, let layout = text.layoutManager, let container = text.textContainer else { return false }
            layout.ensureLayout(for: container)
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in
                let local = rect.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                let global = text.convert(local, to: root)
                lines.append((text, local, root.isFlipped ? global.minY : -global.maxY))
            }
        }
        for row in liveRows where row.window === window {
            guard row.bounds.width > 0, row.bounds.height > 0 else { return false }
            let global = row.convert(row.bounds, to: root)
            lines.append((row, row.bounds, root.isFlipped ? global.minY : -global.maxY))
        }
        guard !lines.isEmpty else { return false }
        started = true
        animatedLineCount = lines.count
        initialDrawingProtected = live.allSatisfy(\.awaitsLineReveal) && liveRows.allSatisfy(\.awaitsLineReveal)
        lines.sort { bottomUp ? $0.2 > $1.2 : $0.2 < $1.2 }
        let beat = min(0.045, 0.6 / Double(max(1, lines.count - 1))) / Self.revealSpeed
        let fadeDuration = 0.28 / Self.revealSpeed
        let now = CACurrentMediaTime()
        var animations: [(CALayer, CABasicAnimation)] = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, line) in lines.enumerated() {
            let (text, rect, _) = line
            let mask: CALayer
            if let existing = masks.first(where: { $0.0.view === text }) { mask = existing.1 }
            else {
                text.wantsLayer = true
                // Another presentation owner always wins; never replace its mask.
                guard text.layer?.mask == nil else { continue }
                mask = CALayer(); mask.frame = text.bounds
                text.layer?.mask = mask; masks.append((WeakView(text), mask))
            }
            let row = CALayer(); row.frame = rect.insetBy(dx: -2, dy: 0)
            row.backgroundColor = NSColor.white.cgColor; mask.addSublayer(row)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            fade.beginTime = now + Double(index) * beat; fade.duration = fadeDuration
            fade.fillMode = .backwards; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animations.append((row, fade))
        }
        // Assign the delegate to the last animation actually installed, including
        // when another owner keeps a text view's mask. The fade's *end* owns the
        // boundary; neither line count nor the start of its last beat does.
        animations.last?.1.delegate = self
        for (row, fade) in animations { row.add(fade, forKey: "thread.line.entrance") }
        live.forEach { $0.admitLineReveal() }
        liveRows.forEach { $0.awaitsLineReveal = false }
        CATransaction.commit()
        if animations.isEmpty { finish() }
        return true
    }
    func animationDidStop(_ anim: CAAnimation, finished _: Bool) {
        guard !cancelled, !finished else { return }
        // A still-mounted view can lose native animation on suspension or layer
        // replacement. Restore full drawing instead of waiting for a dead clock.
        finish()
    }
    func finish() {
        guard !cancelled else { return }
        finished = true; footerVisible = true
        restoreDrawing()
    }
    func cancel() {
        // Teardown restores paint but must not publish successful completion into
        // a retained/replacement visit while its native callbacks are retiring.
        cancelled = true
        footerVisible = true
        restoreDrawing()
    }
    private func restoreDrawing() {
        task?.cancel(); task = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for text in texts.values { text.view?.admitLineReveal() }
        for row in rows.values { row.view?.awaitsLineReveal = false }
        for (reference, mask) in masks where reference.view?.layer?.mask === mask { reference.view?.layer?.mask = nil }
        masks.removeAll(); texts.removeAll(); rows.removeAll(); documents.removeAll()
        CATransaction.commit()
    }
}

/// Shared loading skeleton used by scoped row loading and initial admission.
public struct NativeThreadLoadingSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.locale) private var locale
    @State private var pulse = false
    private let widths: [CGFloat] = [0.32, 0.96, 0.88, 0.65, 0.4, 0.92, 0.78]
    public init() {}
    public var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 15) {
                ForEach(widths.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(NativePalette.thread.ink.swiftUI.opacity(index == 0 || index == 4 ? 0.12 : 0.07))
                        .frame(width: geometry.size.width * widths[index], height: index == 0 ? 15 : 10)
                        .padding(.top, index == 1 || index == 4 ? 12 : 0)
                }
            }.opacity(reducedMotion ? 1 : pulse ? 0.55 : 1)
        }
        .frame(height: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locale.language.languageCode?.identifier == "zh" ? "正在载入正文" : "Loading content")
        .onAppear {
            guard !reducedMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
