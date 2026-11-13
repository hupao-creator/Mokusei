import AppKit
import SwiftUI

/// The clock still updates once per elapsed second. Its short glyph fades run
/// on the compositor, without keeping SwiftUI's text/layout graph animating.
struct ThreadCardClock: View {
    let value: String
    let dimColon: Bool
    let ticking: Bool
    @Environment(\.self) private var environment

    var body: some View {
        ClockRowLayout(count: value.count) {
            // Reuse the production cell for exact width, height and baseline;
            // its input is constant across clock ticks.
            RollingNumberText(value: "0", clock: true).hidden().accessibilityHidden(true)
            ClockInk(value: value, dimColon: dimColon, ticking: ticking, environment: environment)
        }
        .fixedSize()
        .clipped()
        .animation(.easeOut(duration: 0.18), value: value.count)
    }
}

private struct ClockRowLayout: Layout {
    let count: Int
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cell = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: cell.width * CGFloat(count), height: cell.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: .unspecified)
        subviews[1].place(at: bounds.origin, proposal: .init(bounds.size))
    }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        return subviews[0].dimensions(in: .unspecified)[guide]
    }
}

private struct ClockInk: NSViewRepresentable {
    let value: String
    let dimColon: Bool
    let ticking: Bool
    let environment: EnvironmentValues
    func makeNSView(context: Context) -> ClockInkView { ClockInkView() }
    func updateNSView(_ view: ClockInkView, context: Context) {
        view.install(value: value, dimColon: dimColon, ticking: ticking, environment: environment)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClockInkView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Only immutable glyphs are shared. No card, timer, accessibility element or
/// animation owner is retained in the cache.
@MainActor private final class ClockGlyphs {
    struct Key: Equatable {
        let color: Color.Resolved
        let displayScale: CGFloat
        let rasterScale: CGFloat
        let legibility: LegibilityWeight?
    }
    private static var cache: [(Key, ClockGlyphs)] = []
    let key: Key
    let images: [Character: CGImage]
    let scale: CGFloat
    let size: CGSize
    let bytes: Int

    static func resolve(in environment: EnvironmentValues) -> ClockGlyphs {
        let raster = environment.threadCardTextRasterScale
        let key = Key(color: NativePalette.overview.muted.swiftUI.resolve(in: environment),
                      displayScale: environment.displayScale,
                      rasterScale: raster.isFinite ? min(32, max(1, raster)) : 1,
                      legibility: environment.legibilityWeight)
        if let index = cache.firstIndex(where: { $0.0 == key }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.1
        }
        let glyphs = ClockGlyphs(key: key, environment: environment)
        cache.append((key, glyphs))
        // Keep one oversized tier, but do not accumulate previous zoom tiers.
        while cache.count > 1 && (cache.count > 4 || cache.reduce(0, { $0 + $1.1.bytes }) > 32 * 1_024 * 1_024) {
            cache.removeFirst()
        }
        return glyphs
    }

    private init(key: Key, environment: EnvironmentValues) {
        self.key = key
        scale = key.displayScale * key.rasterScale
        var images: [Character: CGImage] = [:]
        var cellSize = CGSize.zero
        for character in "0123456789:" {
            let cell = RollingNumberText(value: String(character), clock: true,
                color: Color(key.color))
                // NSViewRepresentable rounds its seat to backing pixels. Give
                // the source glyph the same seat, avoiding a vertical stretch.
                .frame(height: ceil(11 * 1.25 * key.displayScale) / key.displayScale)
                .environment(\.self, environment)
            let renderer = ImageRenderer(content: cell)
            renderer.scale = scale
            renderer.render { size, _ in cellSize = size }
            images[character] = renderer.cgImage
        }
        self.images = images
        size = cellSize
        bytes = images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }
}

@MainActor private final class ClockInkView: NSView {
    private var glyphs: ClockGlyphs?
    private var cells: [Int: CALayer] = [:]
    private var characters: [Character] = []
    private var rightToLeft = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func install(value: String, dimColon: Bool, ticking: Bool, environment: EnvironmentValues) {
        let next = ClockGlyphs.resolve(in: environment)
        let sameStyle = glyphs?.key == next.key
        let previous = Array(characters.reversed())
        characters = Array(value)
        glyphs = next
        rightToLeft = environment.layoutDirection == .rightToLeft
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (offset, character) in characters.reversed().enumerated() {
            let inserted = cells[offset] == nil
            let cell = cells[offset] ?? CALayer()
            if inserted { layer?.addSublayer(cell); cells[offset] = cell }
            let changed = offset < previous.count && previous[offset] != character
            if sameStyle && changed {
                let fade = CATransition()
                fade.type = .fade; fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cell.add(fade, forKey: "glyph")
            } else if !sameStyle { cell.removeAllAnimations() }
            cell.contents = next.images[character]
            cell.contentsScale = next.scale
            if let image = next.images[character] {
                // ImageRenderer rounds bitmap dimensions up to whole pixels.
                // Crop that padding instead of squeezing the glyph into a cell.
                cell.contentsRect = CGRect(x: 0, y: 0, width: next.size.width * next.scale / CGFloat(image.width),
                                           height: next.size.height * next.scale / CGFloat(image.height))
            }
            let opacity: Float = character == ":" && dimColon ? 0.28 : 1
            if !ticking { cell.removeAnimation(forKey: "colon") }
            if sameStyle && ((ticking && cell.opacity != opacity) || inserted) {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = inserted ? 0 : (cell.presentation()?.opacity ?? cell.opacity)
                fade.toValue = opacity; fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cell.add(fade, forKey: inserted ? "addition" : "colon")
            }
            cell.opacity = opacity
        }
        for offset in cells.keys.filter({ $0 >= characters.count }) {
            guard let cell = cells.removeValue(forKey: offset) else { continue }
            if sameStyle {
                CATransaction.begin()
                CATransaction.setCompletionBlock { cell.removeFromSuperlayer() }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = cell.presentation()?.opacity ?? cell.opacity
                fade.toValue = 0; fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cell.add(fade, forKey: "removal")
                cell.opacity = 0
                CATransaction.commit()
            } else { cell.removeFromSuperlayer() }
        }
        placeCells()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeCells()
        CATransaction.commit()
    }
    private func placeCells() {
        guard let glyphs else { return }
        let width = glyphs.size.width
        for (offset, cell) in cells {
            let x = rightToLeft ? CGFloat(offset) * width : bounds.width - CGFloat(offset + 1) * width
            cell.frame = CGRect(x: x, y: (bounds.height - glyphs.size.height) / 2, width: width, height: glyphs.size.height)
        }
    }
}
