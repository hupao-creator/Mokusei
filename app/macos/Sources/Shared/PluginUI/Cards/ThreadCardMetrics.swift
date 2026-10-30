import SwiftUI

/// Numeric cells keep their identity from the right edge as the digit count grows.
/// Clocks fade in place; usage values roll down by one cell. Each digit and clock
/// colon occupies one measured "0" cell so a glyph change cannot reflow the row.
public struct RollingNumberText: View {
    public let value: String
    public let clock: Bool
    public let dimColon: Bool
    public let ticking: Bool
    public let fontSize: CGFloat
    public let color: Color?

    public init(value: String, clock: Bool = false, dimColon: Bool = false, ticking: Bool = false, fontSize: CGFloat = 11, color: Color? = nil) {
        self.value = value; self.clock = clock; self.dimColon = dimColon; self.ticking = ticking
        self.fontSize = fontSize; self.color = color
    }

    private var cellHeight: CGFloat { fontSize * 1.25 }

    public var body: some View {
        let characters = Array(value.unicodeScalars)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(characters.indices.map { characters.count - $0 }, id: \.self) { position in
                let scalar = characters[characters.count - position]
                if (48...57).contains(scalar.value) {
                    RollingNumberDigit(value: String(scalar), clock: clock, fontSize: fontSize)
                        .transition(numberTransition(clock: clock, height: cellHeight))
                } else if clock && scalar == ":" {
                    Text(":").cardFont(size: fontSize, monospaced: true)
                        .offset(y: -0.88)
                        .opacity(dimColon ? 0.28 : 1)
                        .animation(ticking ? .easeOut(duration: 0.18) : nil, value: dimColon)
                        .modifier(MonospacedDigitCell(fontSize: fontSize))
                } else {
                    Text(String(scalar)).cardFont(size: fontSize, monospaced: true).frame(height: cellHeight)
                }
            }
        }
        .font(.system(size: fontSize, weight: .regular, design: .monospaced))
        .foregroundStyle(color ?? NativePalette.overview.muted.swiftUI)
        .fixedSize()
        // A new position transitions as a whole cell, outside its inner clip.
        .clipped()
        .animation(clock ? .easeOut(duration: 0.18)
            : .timingCurve(0.2, 0.75, 0.25, 1, duration: 0.26), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value)
    }
}

private struct RollingNumberDigit: View {
    let value: String
    let clock: Bool
    let fontSize: CGFloat
    private var cellHeight: CGFloat { fontSize * 1.25 }
    var body: some View {
        ZStack {
            Text(value).cardFont(size: fontSize, monospaced: true)
                // Retain outgoing glyphs without a task/yield reset that can
                // coalesce before SwiftUI renders the starting frame.
                .id(value)
                .transition(numberTransition(clock: clock, height: cellHeight))
        }
        .modifier(MonospacedDigitCell(fontSize: fontSize))
    }
}

private func numberTransition(clock: Bool, height: CGFloat) -> AnyTransition {
    clock ? .opacity : .asymmetric(
        insertion: .offset(y: -height).combined(with: .opacity),
        removal: .offset(y: height).combined(with: .opacity))
}

/// One monospaced "0" wide, matching the AppKit cell the SwiftUI migration dropped.
/// Glyph ink is centered and clipped so a wider rasterized digit cannot reflow its neighbors.
private struct MonospacedDigitCell: ViewModifier {
    let fontSize: CGFloat
    private var cellHeight: CGFloat { fontSize * 1.25 }

    func body(content: Content) -> some View {
        DigitCellLayout(height: cellHeight) {
            Text("0").cardFont(size: fontSize, monospaced: true).hidden().accessibilityHidden(true)
            content
        }
        .clipped()
    }
}

private struct DigitCellLayout: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let strut = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: strut.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let strut = subviews.first else { return }
        let strutSize = strut.sizeThatFits(.unspecified)
        strut.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                    proposal: ProposedViewSize(width: strutSize.width, height: strutSize.height))
        for view in subviews.dropFirst() {
            let size = view.sizeThatFits(.unspecified)
            view.place(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                       anchor: .topLeading, proposal: .unspecified)
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let strut = subviews.first else { return nil }
        let dimensions = strut.dimensions(in: .unspecified)
        return bounds.midY - dimensions.height / 2 + dimensions[VerticalAlignment.firstTextBaseline]
    }
}

/// Millisecond timestamps match the plugin transport. Only this leaf ticks, and
/// each wake-up is aligned to the run's next elapsed second to avoid timer drift.
public struct ThreadCardRuntime: View {
    public let startedAt: Double
    public let endedAt: Double?
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @State private var now = Date().timeIntervalSince1970 * 1_000

    private var isVisible: Bool { scenePhase != .background && (visibility?.isVisible ?? true) }

    public init(startedAt: Double, endedAt: Double? = nil) {
        self.startedAt = startedAt; self.endedAt = endedAt
    }

    public var body: some View {
        let elapsed = max(0, (endedAt ?? now) - startedAt)
        let seconds = elapsed.isFinite ? Int(min(floor(elapsed / 1_000), Double(Int.max / 2))) : 0
        let duration = [seconds / 3_600, (seconds / 60) % 60, seconds % 60]
            .map { $0 < 10 ? "0\($0)" : String($0) }.joined(separator: ":")
        let label = locale.language.languageCode?.identifier == "zh" ? "用时：\(duration)" : "Duration: \(duration)"
        RollingNumberText(value: duration, clock: true, dimColon: endedAt == nil && seconds % 2 == 1,
                          ticking: endedAt == nil && isVisible)
            .help(label)
            .focusable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .task(id: RuntimeSchedule(startedAt: startedAt, endedAt: endedAt, isVisible: isVisible)) {
                guard isVisible, endedAt == nil else { return }
                while !Task.isCancelled {
                    // Retained cards do not tick while hidden. Resuming samples
                    // wall time directly instead of replaying missed seconds.
                    let current = Date().timeIntervalSince1970 * 1_000
                    now = current
                    let elapsed = max(0, current - startedAt)
                    let delay = elapsed.isFinite ? 1_000 - elapsed.truncatingRemainder(dividingBy: 1_000) : 1_000
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                }
            }
    }

    private struct RuntimeSchedule: Equatable {
        let startedAt: Double
        let endedAt: Double?
        let isVisible: Bool
    }
}
