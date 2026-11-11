import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct NativeReportCollection: View {
    let props: [ApplicationThreadProps<NativeReportView>]
    let active: Bool
    let slow: Bool
    let onSelection: (ApplicationThreadRef) -> Void
    let openThread: (ApplicationThreadRef) -> Void
    @State private var selection: ApplicationThreadRef
    @State private var direction = 1
    @State private var interacting = false
    @State private var outgoingID: ApplicationThreadRef?
    @State private var progress = 1.0
    @State private var motionEpoch = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardAnimationVisibility) private var visibility

    init(props: [ApplicationThreadProps<NativeReportView>], initialSelection: ApplicationThreadRef? = nil,
         active: Bool, slow: Bool = false, onSelection: @escaping (ApplicationThreadRef) -> Void,
         openThread: @escaping (ApplicationThreadRef) -> Void) {
        self.props = props; self.active = active; self.slow = slow
        self.onSelection = onSelection; self.openThread = openThread
        _selection = State(initialValue: initialSelection.flatMap { ref in props.contains { $0.entry.ref == ref } ? ref : nil } ?? props[0].entry.ref)
    }
    private var members: [ApplicationThreadRef] { props.map { $0.entry.ref } }
    private var selected: ApplicationThreadRef { members.contains(selection) ? selection : members[0] }
    private var page: Int { members.firstIndex(of: selected) ?? 0 }
    private var playing: Bool { active && visibility?.isVisible != false && !interacting }
    private struct ClockKey: Hashable {
        let selection: ApplicationThreadRef
        let members: [ApplicationThreadRef]
        let playing: Bool
    }
    private var clockKey: ClockKey { .init(selection: selected, members: members, playing: playing) }
    private var locale: JSONText { props[0].context.locale }
    // Keep at most four WebKit covers alive: visible, retiring, and neighbors.
    // An arbitrarily large collection must not mount one browser per report.
    private var rendered: [ApplicationThreadProps<NativeReportView>] {
        let adjacent = [members[(page + 1) % members.count], members[(page + members.count - 1) % members.count]]
        return props.filter { $0.entry.ref == selected || $0.entry.ref == outgoingID || adjacent.contains($0.entry.ref) }
    }
    private func step(_ value: Int) {
        select(members[(page + value + members.count) % members.count], direction: value)
    }
    private func select(_ id: ApplicationThreadRef, direction: Int) {
        guard active, outgoingID == nil, id != selected else { return }
        self.direction = direction
        // Cover and ink retain the old identity on one shared clock.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingID = reduceMotion ? nil : selected
            progress = reduceMotion ? 1 : 0
            motionEpoch = UUID()
            selection = id
        }
        onSelection(id)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 4) {
                    // Preload covers in their own clipped viewport. Metadata never
                    // inherits these horizontal offsets or cover clipping bounds.
                    ZStack {
                        ForEach(rendered, id: \.entry.ref) { member in
                            cover(member)
                                .frame(width: geometry.size.width, height: 308)
                                .modifier(NativeReportCollectionCoverOffset(direction: Double(direction), incoming: member.entry.ref != outgoingID,
                                    moving: outgoingID != nil, width: geometry.size.width, progress: progress))
                                .opacity(member.entry.ref == selected || member.entry.ref == outgoingID ? 1 : 0)
                        }
                    }.frame(height: 308).clipped().allowsHitTesting(false).accessibilityHidden(true)
                    NativeReportCollectionBody(props: rendered, selected: selected, outgoingID: outgoingID,
                        direction: direction, progress: progress, visualEpoch: motionEpoch, active: active,
                        allowsActions: { active && outgoingID == nil && $0 == selected }, openThread: openThread)
                        .frame(maxHeight: .infinity).clipped()
                }
                NativeReportCarouselInput(step: step, open: { if active && outgoingID == nil { openThread(selected) } }, interacting: { interacting = $0 })
                    .frame(height: 308).nativeCanvasNavigationRegion().accessibilityHidden(true).zIndex(3)
                GlassEffectContainer(spacing: 12) {
                    VStack {
                        HStack {
                            Spacer()
                            Text(applicationText(locale, "\(members.count) 篇", "\(members.count) reports")).font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .glassEffect(.regular, in: Capsule())
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            Button { step(-1) } label: {
                                Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
                            }.accessibilityLabel(applicationText(locale, "上一个 Super Thread", "Previous Super Thread"))
                            if props.count <= 7 {
                                HStack(spacing: 7) {
                                    ForEach(Array(props.enumerated()), id: \.element.entry.ref) { index, member in
                                        Button { select(member.entry.ref, direction: index >= page ? 1 : -1) } label: {
                                            Capsule().fill(member.entry.ref == selected
                                                ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                                .frame(width: member.entry.ref == selected ? 16 : 5, height: 5)
                                                .frame(minWidth: 16, minHeight: 28).contentShape(Rectangle())
                                        }.accessibilityLabel(member.entry.title.string)
                                            .accessibilityAddTraits(member.entry.ref == selected ? .isSelected : [])
                                    }
                                }
                            }
                            Menu {
                                ForEach(Array(props.enumerated()), id: \.element.entry.ref) { index, member in
                                    Button(member.entry.title.string) { select(member.entry.ref, direction: index >= page ? 1 : -1) }
                                }
                            } label: {
                                Text("\(page + 1) / \(members.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                            }.menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel(applicationText(locale, "选择 Super Thread", "Select Super Thread"))
                            Button { step(1) } label: {
                                Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Rectangle())
                            }.accessibilityLabel(applicationText(locale, "下一个 Super Thread", "Next Super Thread"))
                        }.modifier(NativeReportCarouselChrome(blocked: !active || outgoingID != nil))
                    }.foregroundStyle(.primary).padding(14).frame(height: 308)
                }.zIndex(4)
            }
            .background {
                // Cover, gap and metadata share one continuous plate. The opaque
                // cover hides its upper portion; ink/page masks never clip it.
                Color.clear.nativeRegularCardGlass(in: RoundedRectangle(cornerRadius: 22),
                    opaque: NativePalette.overview.surface.swiftUI)
            }
        }
        .onAppear { onSelection(selected) }
        .onChange(of: members) { _, next in
            settle()
            if !next.contains(selection) { selection = next[0] }
            onSelection(selected)
        }
        .onChange(of: active) { _, value in
            if !value { settle() }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { settle() }
        }
        .onChange(of: visibility?.isVisible) { _, visible in
            if visible == false { settle() }
        }
        .task(id: motionEpoch) {
            guard outgoingID != nil else { return }
            do {
                // Commit the initial pair of native pages before animating it.
                try await Task.sleep(for: .milliseconds(20))
                let duration = 0.46 * (slow ? 3 : 1)
                withAnimation(.easeInOut(duration: duration)) { progress = 1 }
                try await Task.sleep(for: .seconds(duration))
                try Task.checkCancellation()
                outgoingID = nil
            } catch { /* View identity owns and cancels this transition. */ }
        }
        .task(id: clockKey) {
            guard playing else { return }
            do {
                try await Task.sleep(for: .seconds(10))
                try Task.checkCancellation()
                step(1)
            } catch { /* Leaving the view or manual input cancels this page's dwell. */ }
        }
    }
    private func settle() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingID = nil; progress = 1; interacting = false
            motionEpoch = UUID()
        }
    }
    @ViewBuilder private func cover(_ member: ApplicationThreadProps<NativeReportView>) -> some View {
        if member.entry.view.hasCover { NativeReportCover(props: member) }
        else {
            ZStack {
                NativePalette.overview.surface.swiftUI
                Text(member.entry.view.emoji.string).font(.system(size: 72))
            }
        }
    }

}

/// Keep the metadata in its original viewport while old/new ink swaps. Disabling
/// its Button would dim the whole label independently of the mask, so input and
/// accessibility are gated separately; the action guard also covers keyboard use.
struct NativeReportCollectionBody: View {
    let props: [ApplicationThreadProps<NativeReportView>]
    let selected: ApplicationThreadRef
    let outgoingID: ApplicationThreadRef?
    let direction: Int
    let progress: Double
    let visualEpoch: UUID
    let active: Bool
    let allowsActions: (ApplicationThreadRef) -> Bool
    let openThread: (ApplicationThreadRef) -> Void

    var body: some View {
        ZStack {
            ForEach(props.filter { $0.entry.ref == selected || $0.entry.ref == outgoingID }, id: \.entry.ref) { member in
                NativeReportCard(props: member,
                    projection: .init(previewText: member.entry.view.shortDescription,
                                      relatedThreadCount: member.entry.view.relatedExecutions.count),
                    openThread: { openThread(member.entry.ref) }, showsCover: false, usesGlassBadge: true,
                    allowsActions: { allowsActions(member.entry.ref) })
                    .mask {
                        ThreadCardInkMask(progress: CGFloat(progress), outgoing: member.entry.ref == outgoingID)
                            .scaleEffect(x: direction < 0 ? -1 : 1, y: 1)
                            // Retire only the mask's animation presentation. Keep
                            // subscriptions and in-flight card actions mounted.
                            .id(visualEpoch).transition(.identity)
                    }
                    .zIndex(member.entry.ref == outgoingID ? 1 : 0)
                    .allowsHitTesting(active && outgoingID == nil && member.entry.ref == selected)
                    .accessibilityHidden(!active || outgoingID != nil || member.entry.ref != selected)
                    .disabled(!active)
            }
        }
    }
}

/// Keep WebKit identities mounted. A settled pose ignores any remaining
/// interpolated progress, so Reduce Motion/reset cannot expose a retiring offset
/// and does not reload the cover merely to cancel its presentation animation.
struct NativeReportCollectionCoverOffset: GeometryEffect {
    let direction: Double
    let incoming: Bool
    let moving: Bool
    let width: CGFloat
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = moving ? direction * width * (incoming ? 1 - progress : -progress) : 0
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// Disable the real controls (including Menu and keyboard/AX activation), but
/// keep the surrounding glass outside that environment boundary. A transient
/// input lock must not restyle the material or dim all the navigation labels.
struct NativeReportCarouselChrome: ViewModifier {
    let blocked: Bool
    func body(content: Content) -> some View {
        content.font(.system(size: 11, weight: .semibold))
            .buttonStyle(NativeReportCarouselButtonStyle())
            .disabled(blocked)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private struct NativeReportCarouselButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
