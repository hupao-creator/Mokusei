import AppKit
import Observation
import MokuseiCore
import SwiftUI

public extension EnvironmentValues {
    @Entry var nativeThreadIdentityRegistry: NativeThreadIdentityRegistry? = nil
    @Entry var nativeThreadIdentityKey: String? = nil
    @Entry var nativeThreadPreparing = false
    @Entry var nativeThreadStableOrigin = false
    @Entry var nativeThreadIdentityVisit: NativeThreadIdentityVisit? = nil
}

/// Window-local anchors. Capturing a visit copies geometry and text only; it
/// never retains a card, reader or plugin session across navigation.
@MainActor
public final class NativeThreadIdentityRegistry {
    private final class WeakAnchor {
        weak var value: ThreadIdentityAnchorView?
        init(_ value: ThreadIdentityAnchorView) { self.value = value }
    }
    private var anchors: [String: [String: WeakAnchor]] = [:]
    public init() {}
    fileprivate func register(_ view: ThreadIdentityAnchorView, key: String, element: String) {
        anchors[key, default: [:]][element] = WeakAnchor(view)
    }
    fileprivate func unregister(_ view: ThreadIdentityAnchorView, key: String, element: String) {
        if anchors[key]?[element]?.value === view { anchors[key]?[element] = nil }
        if anchors[key]?.isEmpty == true { anchors[key] = nil }
    }
    public func capture(_ key: String) -> NativeThreadIdentityVisit? {
        let leaves = (anchors[key] ?? [:]).compactMapValues { $0.value?.snapshot() }
        guard leaves["title"] != nil, leaves["emoji"] != nil else { return nil }
        return NativeThreadIdentityVisit(source: leaves)
    }
}

@MainActor @Observable
public final class NativeThreadIdentityVisit {
    struct Leaf {
        let text: String
        let frame: CGRect
        let localSize: CGSize
        weak var window: NSWindow?
    }
    private final class WeakTarget {
        weak var view: ThreadIdentityAnchorView?
        init(_ view: ThreadIdentityAnchorView) { self.view = view }
    }
    @ObservationIgnored private var openingAnchors: [String: WeakTarget] = [:]
    @ObservationIgnored private var targetAnchors: [String: WeakTarget] = [:]
    var measuredTargets: [String: Leaf] { targetAnchors.compactMapValues { $0.view?.snapshot() } }
    func freezeOpeningTargets() { openingTarget = openingAnchors.compactMapValues { $0.view?.snapshot() } }
    let source: [String: Leaf]
    private(set) var pending = true
    private(set) var usedMeasuredDestination = false
    private(set) var openingFinished = false
    private(set) var handoffDistance: CGFloat = 0
    @ObservationIgnored var openingTarget: [String: Leaf] = [:]
    @ObservationIgnored var onOpeningTargetsChange: (() -> Void)?
    @ObservationIgnored var target: [String: Leaf] = [:]
    @ObservationIgnored var onTargetsChange: (() -> Void)?
    init(source: [String: Leaf]) { self.source = source }
    fileprivate func update(_ element: String, anchor: ThreadIdentityAnchorView) {
        guard let value = anchor.snapshot() else { return }
        if anchor.preparing { openingAnchors[element] = WeakTarget(anchor) }
        else { targetAnchors[element] = WeakTarget(anchor) }
        let previousTarget = anchor.preparing ? openingTarget : target
        if let previous = previousTarget[element], previous.frame == value.frame, previous.text == value.text,
           previous.window === value.window { return }
        if anchor.preparing { openingTarget[element] = value; onOpeningTargetsChange?() }
        else { target[element] = value; onTargetsChange?() }
    }
    func completeOpening() { openingFinished = true }
    func recordHandoffDistance(_ value: CGFloat) { handoffDistance = max(handoffDistance, value) }
    func finish(measured: Bool = false) { usedMeasuredDestination = usedMeasuredDestination || measured; pending = false; onTargetsChange = nil; onOpeningTargetsChange = nil }
}

struct ThreadIdentityBridgeModifier: ViewModifier {
    let element: String
    let detail: Bool
    let text: String
    @Environment(\.nativeThreadIdentityRegistry) private var registry
    @Environment(\.nativeThreadIdentityKey) private var key
    @Environment(\.nativeThreadIdentityVisit) private var visit
    @Environment(\.nativeThreadPreparing) private var preparing
    func body(content: Content) -> some View {
        content
            .background {
                if detail, let visit {
                    ThreadIdentityAnchor(registry: nil, key: nil, visit: visit, element: element, text: text, preparing: preparing)
                } else if !detail, let registry, let key {
                    ThreadIdentityAnchor(registry: registry, key: key, visit: nil, element: element, text: text)
                }
            }
            .opacity(detail && visit?.pending == true ? 0 : 1)
    }
}

private struct ThreadIdentityAnchor: NSViewRepresentable {
    let registry: NativeThreadIdentityRegistry?
    let key: String?
    let visit: NativeThreadIdentityVisit?
    let element: String
    let text: String
    var preparing = false
    func makeNSView(context: Context) -> ThreadIdentityAnchorView { ThreadIdentityAnchorView() }
    func updateNSView(_ view: ThreadIdentityAnchorView, context: Context) {
        view.detach()
        view.registry = registry; view.key = key; view.visit = visit
        view.element = element; view.text = text; view.preparing = preparing
        if let registry, let key { registry.register(view, key: key, element: element) }
        view.publish()
    }
    static func dismantleNSView(_ view: ThreadIdentityAnchorView, coordinator: ()) { view.detach() }
}

private final class ThreadIdentityAnchorView: NSView {
    weak var registry: NativeThreadIdentityRegistry?
    var key: String?
    weak var visit: NativeThreadIdentityVisit?
    var element = ""
    var text = ""
    var preparing = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); publish() }
    override func layout() { super.layout(); publish() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); publish() }
    func snapshot() -> NativeThreadIdentityVisit.Leaf? {
        guard let window, bounds.width > 0, bounds.height > 0 else { return nil }
        return .init(text: text, frame: convert(bounds, to: nil), localSize: bounds.size, window: window)
    }
    func publish() {
        guard visit != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            visit?.update(element, anchor: self)
        }
    }
    func detach() {
        if let key { registry?.unregister(self, key: key, element: element) }
        registry = nil; visit = nil
    }
}

/// Separate native ink keeps opening smooth while the heavyweight reader is
/// deferred. A row-free production heading supplies the destination before
/// travel. Loaded content takes ownership without a second movement.
@MainActor
final class NativeThreadIdentityFlight {
    private let visit: NativeThreadIdentityVisit
    private weak var surface: NSView?
    private let overlay = ThreadIdentityInkHost()
    private var layers: [String: CATextLayer] = [:]
    private var task: Task<Void, Never>?
    private var completion: Task<Void, Never>?
    init(visit: NativeThreadIdentityVisit, surface: NSView, source: CGRect, duration: TimeInterval, timing: CAMediaTimingFunction) {
        self.visit = visit; self.surface = surface
        overlay.wantsLayer = true; overlay.frame = surface.bounds
        overlay.layer?.masksToBounds = true
        overlay.autoresizingMask = [.width, .height]
        surface.addSubview(overlay)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (element, leaf) in visit.source {
            guard leaf.window === surface.window, let parent = surface.superview else { continue }
            let absolute = parent.convert(leaf.frame, from: nil)
            let ratio: CGFloat = element == "emoji" ? 21 / 44 : 15 / 40
            let scale = ratio * absolute.height / max(1, leaf.localSize.height)
            let size = CGSize(width: absolute.width / max(0.01, scale), height: absolute.height / max(0.01, scale))
            let layer = CATextLayer()
            layer.contentsScale = surface.window?.backingScaleFactor ?? 2
            layer.string = Self.ink(leaf.text, element: element)
            layer.alignmentMode = .left; layer.truncationMode = .end
            layer.isWrapped = false
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.anchorPoint = .zero
            layer.position = CGPoint(x: absolute.minX - source.minX, y: absolute.minY - source.minY)
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            overlay.layer?.addSublayer(layer)
            layers[element] = layer
        }
        CATransaction.commit()
        visit.onTargetsChange = { [weak self] in self?.scheduleHandoff() }
        // Both ink and paper use the same duration and curve. The reader may
        // arrive much later; arrival only swaps ownership, never moves ink.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (element, layer) in layers {
            guard let leaf = visit.openingTarget[element] else { continue }
            let destination = surface.convert(leaf.frame, from: nil)
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: layer.position)
            position.toValue = NSValue(point: destination.origin)
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: layer.transform)
            scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            layer.bounds = CGRect(origin: .zero, size: destination.size)
            layer.isWrapped = element == "title"
            layer.position = destination.origin; layer.transform = CATransform3DIdentity
            for animation in [position, scale] { animation.duration = duration; animation.timingFunction = timing }
            layer.add(position, forKey: "identity.position"); layer.add(scale, forKey: "identity.size")
        }
        CATransaction.commit()
        completion = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self else { return }
            visit.completeOpening(); scheduleHandoff()
        }
    }

    private static func ink(_ text: String, element: String) -> NSAttributedString {
        let font = element == "emoji" ? NSFont.systemFont(ofSize: 44)
            : NativeTypography.interPlatformFont(size: 40, weight: 650)
        return NSAttributedString(string: text, attributes: [
            .font: font, .kern: element == "emoji" ? 0 : -0.8,
            .foregroundColor: NativePlatformPalette.thread.inkStrong
        ])
    }
    private func scheduleHandoff() {
        guard visit.pending, visit.openingFinished,
              visit.target["title"] != nil, visit.target["emoji"] != nil else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let surface else { return }
            for (element, layer) in layers {
                guard let leaf = visit.measuredTargets[element], leaf.window === surface.window else { continue }
                let destination = surface.convert(leaf.frame, from: nil)
                visit.recordHandoffDistance(hypot(destination.minX - layer.position.x, destination.minY - layer.position.y))
            }
            retire(measured: true)
        }
    }

    func retire(measured: Bool = false) {
        task?.cancel(); completion?.cancel(); task = nil; completion = nil
        visit.finish(measured: measured)
        layers.values.forEach { $0.removeFromSuperlayer() }; layers.removeAll()
        overlay.removeFromSuperview()
    }
}

private final class ThreadIdentityInkHost: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// The same heading and timeline layout, without any Harness rows or parser.
/// Reserve the history rail across loading so data cannot shift the heading.
public struct NativeThreadOpeningContent: View {
    @Environment(\.nativeThreadIdentityVisit) private var visit
    private let showsLoading: Bool
    public init(showsLoading: Bool = false) { self.showsLoading = showsLoading }
    public var body: some View {
        ThreadConversation(threadId: "opening-heading", title: visit?.source["title"]?.text ?? "",
            icon: visit?.source["emoji"]?.text ?? "", rows: [],
            emptyState: AnyView(NativeThreadLoadingSkeleton().opacity(showsLoading ? 1 : 0)))
    }

}

struct NativeThreadHeading: View {
    let title: String
    let emoji: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(emoji).font(.system(size: 44)).threadIdentityElement("emoji", detail: true, text: emoji).accessibilityHidden(true)
            Text(title).font(NativeTypography.inter(size: 40, weight: 650))
                .tracking(-0.8).lineLimit(2).truncationMode(.tail)
                .foregroundStyle(NativePalette.thread.inkStrong.swiftUI)
                .frame(maxWidth: .infinity, alignment: .leading).help(title)
                .threadIdentityElement("title", detail: true, text: title)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

public struct NativeThreadPreparedReader<Content: View>: View {
    @Environment(\.nativeThreadPreparing) private var preparing
    private let content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    public var body: some View {
        if preparing { NativeThreadOpeningContent() } else { content() }
    }
}
