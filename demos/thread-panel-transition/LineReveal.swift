import AppKit
import SwiftUI
@testable import MokuseiPluginUI

/// Demo-only observer: reveal the actual TextKit line fragments without
/// replacing Markdown, attributed text, selection or the reader's layout.
struct DemoLineReveal: NSViewRepresentable {
    let owner: UUID
    let bottomUp: Bool
    let slow: Bool
    let reducedMotion: Bool
    let onLastLine: @MainActor () -> Void
    func makeNSView(context: Context) -> RevealProbe {
        RevealProbe(owner: owner, bottomUp: bottomUp, slow: slow, reducedMotion: reducedMotion, onLastLine: onLastLine)
    }
    func updateNSView(_ view: RevealProbe, context: Context) {
        if reducedMotion {
            Task { @MainActor [weak view] in view?.admitFooter(); view?.cleanUp() }
        }
    }
    static func dismantleNSView(_ view: RevealProbe, coordinator: ()) { view.cleanUp() }
}

final class RevealProbe: NSView {
    static var revealedLineCount = 0
    static var admittedBeforeFirstPaint = false
    static var revealOrder: [CGFloat] = []
    let owner: UUID
    let bottomUp: Bool
    let slow: Bool
    let reducedMotion: Bool
    let onLastLine: @MainActor () -> Void
    private var lastRegion: CGRect?
    private var started = false
    private var footerAdmitted = false
    private var masks: [(NSTextView, CALayer)] = []
    private var cleanup: Task<Void, Never>?
    init(owner: UUID, bottomUp: Bool, slow: Bool, reducedMotion: Bool, onLastLine: @escaping @MainActor () -> Void) {
        self.owner = owner; self.bottomUp = bottomUp
        self.slow = slow; self.reducedMotion = reducedMotion; self.onLastLine = onLastLine
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize, !masks.isEmpty { admitFooter(); cleanUp() }
        super.setFrameSize(newSize)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !started, window != nil, !reducedMotion else { return }
        started = true
        cleanup = Task { @MainActor [weak self] in
            // Wait for the sibling TextKit representables to finish mounting.
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self, self.window != nil else { return }
                if self.reveal() { return }
            }
            self?.restorePendingText()
            self?.admitFooter()
        }
    }
    private func reveal() -> Bool {
        guard bounds.width > 0, let root = window?.contentView else { return false }
        let region = convert(bounds, to: root)
        if bottomUp, lastRegion != region { lastRegion = region; return false }
        var fragments: [(NSTextView, CGRect)] = []
        func visit(_ node: NSView) {
            if let text = node as? MarkdownTextView, text.lineRevealOwner == owner,
               region.intersects(text.convert(text.bounds, to: root)),
               !text.isHiddenOrHasHiddenAncestor,
               let layout = text.layoutManager, let container = text.textContainer {
                layout.ensureLayout(for: container)
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in
                    fragments.append((text, rect.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)))
                }
            }
            for child in node.subviews { visit(child) }
        }
        visit(root)
        fragments.sort {
            let a = $0.0.convert($0.1, to: root), b = $1.0.convert($1.1, to: root)
            return root.isFlipped ? a.minY < b.minY : a.maxY > b.maxY
        }
        if bottomUp { fragments.reverse() }
        guard !fragments.isEmpty else { return false }
        Self.revealOrder = fragments.map {
            let rect = $0.0.convert($0.1, to: root)
            return root.isFlipped ? rect.minY : -rect.maxY
        }
        Self.revealedLineCount = fragments.count
        Self.admittedBeforeFirstPaint = fragments.allSatisfy {
            guard let text = $0.0 as? MarkdownTextView else { return false }
            return text.awaitsLineReveal
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let duration = slow ? 0.65 : 0.28
        let beat = slow ? 0.14 : 0.045
        let start = CACurrentMediaTime()
        for (index, fragment) in fragments.enumerated() {
            let (text, rect) = fragment
            let mask: CALayer
            if let existing = masks.first(where: { $0.0 === text }) { mask = existing.1 }
            else {
                text.wantsLayer = true
                guard text.layer?.mask == nil else { continue }
                mask = CALayer(); mask.frame = text.bounds
                text.layer?.mask = mask
                masks.append((text, mask))
            }
            let line = CALayer()
            line.frame = rect.insetBy(dx: -2, dy: 0)
            line.backgroundColor = NSColor.white.cgColor
            mask.addSublayer(line)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            fade.beginTime = start + Double(min(index, 24)) * beat
            fade.duration = duration; fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            line.add(fade, forKey: "line-reveal")
        }
        // Masks and visibility commit together. No unmasked text can reach
        // the compositor between native view attachment and the first reveal.
        for (view, _) in masks { (view as? MarkdownTextView)?.admitLineReveal() }
        CATransaction.commit()
        cleanup = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(min(fragments.count, 25)) * beat))
            guard !Task.isCancelled else { return }
            self?.admitFooter()
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.cleanUp()
        }
        return true
    }
    func admitFooter() {
        guard !footerAdmitted else { return }
        footerAdmitted = true
        onLastLine()
    }
    private func restorePendingText() {
        guard let root = window?.contentView else { return }
        let region = convert(bounds, to: root)
        func visit(_ node: NSView) {
            if let text = node as? MarkdownTextView, text.lineRevealOwner == owner, text.awaitsLineReveal,
               region.intersects(text.convert(text.bounds, to: root)) { text.admitLineReveal() }
            node.subviews.forEach(visit)
        }
        visit(root)
    }
    func cleanUp() {
        cleanup?.cancel(); cleanup = nil
        restorePendingText()
        for (view, mask) in masks where view.layer?.mask === mask { view.layer?.mask = nil }
        masks.removeAll()
    }
}


struct DemoLoadingSkeleton: View {
    let reducedMotion: Bool
    @State private var pulse = false
    private let widths: [CGFloat] = [0.32, 0.96, 0.88, 0.65, 0.4, 0.92, 0.78]
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 15) {
                ForEach(widths.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.primary.opacity(index == 0 || index == 4 ? 0.12 : 0.07))
                        .frame(width: geometry.size.width * widths[index], height: index == 0 ? 15 : 10)
                        .padding(.top, index == 1 || index == 4 ? 12 : 0)
                }
            }
            .opacity(reducedMotion ? 1 : pulse ? 0.55 : 1)
        }
        .frame(height: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在载入正文")
        .onAppear {
            guard !reducedMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
