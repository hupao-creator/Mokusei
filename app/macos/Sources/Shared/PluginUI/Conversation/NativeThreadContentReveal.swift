import AppKit
import Observation
import SwiftUI

public extension EnvironmentValues {
    /// Agent reader admission only; other Markdown consumers keep their normal drawing.
    @Entry var nativeThreadContentReveal = false
}
extension EnvironmentValues {
    @Entry var nativeThreadReveal: NativeThreadContentReveal? = nil
}

/// One mounted execution owns its first content entrance, never its data or
/// subscriptions. Later streaming updates and newly disclosed work stay immediate.
@MainActor @Observable
final class NativeThreadContentReveal {
    private final class WeakText {
        weak var view: MarkdownTextView?
        init(_ view: MarkdownTextView) { self.view = view }
    }
    private var texts: [ObjectIdentifier: WeakText] = [:]
    private var documents: [UUID: Bool] = [:]
    private var masks: [(WeakText, CALayer)] = []
    private var task: Task<Void, Never>?
    private var started = false
    private var finished = false
    private(set) var footerVisible = false
    private(set) var bottomUp = false
    private(set) var animatedLineCount = 0
    private(set) var initialDrawingProtected = false
    private var reducedMotion = false

    func beginDocument(_ id: UUID) {
        guard !finished, !started else { return }
        if documents[id] == nil { documents[id] = false }
    }
    func documentReady(_ id: UUID) {
        guard !finished, !started else { return }
        documents[id] = true; schedule()
    }
    func endDocument(_ id: UUID) { documents[id] = nil }
    func contentChanged(_ view: MarkdownTextView) {
        if started, masks.contains(where: { $0.0.view === view }) { finish() }
    }
    func register(_ view: MarkdownTextView) {
        guard !finished, !started else { return }
        texts[ObjectIdentifier(view)] = WeakText(view)
        view.awaitsLineReveal = true
        schedule()
    }
    func unregister(_ view: MarkdownTextView) {
        texts[ObjectIdentifier(view)] = nil
        view.admitLineReveal()
    }
    func begin(bottomUp: Bool, reducedMotion: Bool) {
        self.bottomUp = bottomUp; self.reducedMotion = reducedMotion
        if reducedMotion { finish(); return }
        schedule()
    }
    private func schedule() {
        guard !finished, !started else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            // Coalesce asynchronous Markdown block mounting and the reader's
            // follow-to-latest layout before sampling actual line fragments.
            do { try await Task.sleep(for: .milliseconds(48)) } catch { return }
            guard let self else { return }
            // Parsing owns readiness; no guessed timeout may admit an empty
            // document and consume its entrance before its text arrives.
            guard !documents.values.contains(false) else { return }
            for _ in 0..<12 {
                if animate() { return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            finish()
        }
    }
    private func animate() -> Bool {
        let live = texts.values.compactMap(\.view)
        guard !live.isEmpty else { return false }
        guard let window = live.first?.window, let root = window.contentView else { return false }
        var lines: [(MarkdownTextView, CGRect, CGFloat)] = []
        for text in live where text.window === window {
            guard text.bounds.width > 0, let layout = text.layoutManager, let container = text.textContainer else { return false }
            layout.ensureLayout(for: container)
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in
                let local = rect.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                let global = text.convert(local, to: root)
                lines.append((text, local, root.isFlipped ? global.minY : -global.maxY))
            }
        }
        guard !lines.isEmpty else { return false }
        started = true
        animatedLineCount = lines.count
        initialDrawingProtected = live.allSatisfy(\.awaitsLineReveal)
        lines.sort { bottomUp ? $0.2 > $1.2 : $0.2 < $1.2 }
        let beat = min(0.045, 0.6 / Double(max(1, lines.count - 1)))
        let fadeDuration = 0.28
        let now = CACurrentMediaTime()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, line) in lines.enumerated() {
            let (text, rect, _) = line
            let mask: CALayer
            if let existing = masks.first(where: { $0.0.view === text }) { mask = existing.1 }
            else {
                text.wantsLayer = true
                // Another presentation owner always wins; never replace its mask.
                guard text.layer?.mask == nil else { text.admitLineReveal(); continue }
                mask = CALayer(); mask.frame = text.bounds
                text.layer?.mask = mask; masks.append((WeakText(text), mask))
            }
            let row = CALayer(); row.frame = rect.insetBy(dx: -2, dy: 0)
            row.backgroundColor = NSColor.white.cgColor; mask.addSublayer(row)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            fade.beginTime = now + Double(index) * beat; fade.duration = fadeDuration
            fade.fillMode = .backwards; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            row.add(fade, forKey: "thread.line.entrance")
        }
        live.forEach { $0.admitLineReveal() }
        CATransaction.commit()
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Double(lines.count) * beat)) } catch { return }
            guard let self else { return }
            withAnimation(.easeOut(duration: fadeDuration)) { footerVisible = true }
            do { try await Task.sleep(for: .seconds(fadeDuration)) } catch { return }
            finish()
        }
        return true
    }
    func finish() {
        task?.cancel(); task = nil
        finished = true; footerVisible = true
        for text in texts.values { text.view?.admitLineReveal() }
        for (reference, mask) in masks where reference.view?.layer?.mask === mask { reference.view?.layer?.mask = nil }
        masks.removeAll(); texts.removeAll(); documents.removeAll()
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
