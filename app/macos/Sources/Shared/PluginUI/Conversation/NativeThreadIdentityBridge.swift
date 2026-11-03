import AppKit
import Observation
import SwiftUI

public extension EnvironmentValues {
    @Entry var nativeThreadIdentityRegistry: NativeThreadIdentityRegistry? = nil
    @Entry var nativeThreadIdentityKey: String? = nil
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
    let source: [String: Leaf]
    private(set) var pending = true
    private(set) var usedMeasuredDestination = false
    @ObservationIgnored var target: [String: Leaf] = [:]
    @ObservationIgnored var onTargetsChange: (() -> Void)?
    init(source: [String: Leaf]) { self.source = source }
    fileprivate func update(_ element: String, anchor: ThreadIdentityAnchorView) {
        guard pending, let value = anchor.snapshot() else { return }
        if let previous = target[element], previous.frame == value.frame, previous.text == value.text,
           previous.window === value.window { return }
        target[element] = value; onTargetsChange?()
    }
    func finish(measured: Bool = false) { usedMeasuredDestination = usedMeasuredDestination || measured; pending = false; onTargetsChange = nil; target.removeAll() }
}

struct ThreadIdentityBridgeModifier: ViewModifier {
    let element: String
    let detail: Bool
    let text: String
    @Environment(\.nativeThreadIdentityRegistry) private var registry
    @Environment(\.nativeThreadIdentityKey) private var key
    @Environment(\.nativeThreadIdentityVisit) private var visit
    func body(content: Content) -> some View {
        content
            .background {
                if detail, let visit, visit.pending {
                    ThreadIdentityAnchor(registry: nil, key: nil, visit: visit, element: element, text: text)
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
    func makeNSView(context: Context) -> ThreadIdentityAnchorView { ThreadIdentityAnchorView() }
    func updateNSView(_ view: ThreadIdentityAnchorView, context: Context) {
        view.detach()
        view.registry = registry; view.key = key; view.visit = visit
        view.element = element; view.text = text
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
/// deferred. It follows panel travel, then hands off at the real mounted heading
/// (including sidebar width and scroll positioning), rather than guessing a grid.
@MainActor
final class NativeThreadIdentityFlight {
    private let visit: NativeThreadIdentityVisit
    private weak var surface: NSView?
    private let overlay = ThreadIdentityInkHost()
    private var layers: [String: CATextLayer] = [:]
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    init(visit: NativeThreadIdentityVisit, surface: NSView, source: CGRect) {
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
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.retire()
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
        guard visit.pending, visit.target["title"] != nil, visit.target["emoji"] != nil else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(48)) } catch { return }
            guard let self, let surface else { return }
            for (element, layer) in layers {
                guard let leaf = visit.target[element], leaf.window === surface.window else { continue }
                let destination = surface.convert(leaf.frame, from: nil)
                let from = layer.presentation()?.position ?? layer.position
                let scale = layer.presentation()?.transform ?? layer.transform
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.bounds = CGRect(origin: .zero, size: destination.size)
                layer.isWrapped = element == "title"
                layer.position = destination.origin; layer.transform = CATransform3DIdentity
                CATransaction.commit()
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = NSValue(point: from); position.toValue = NSValue(point: destination.origin)
                let size = CABasicAnimation(keyPath: "transform")
                size.fromValue = NSValue(caTransform3D: scale); size.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                for animation in [position, size] {
                    animation.duration = 0.2; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                }
                layer.add(position, forKey: "identity.position"); layer.add(size, forKey: "identity.size")
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            retire(measured: true)
        }
    }
    func retire(measured: Bool = false) {
        task?.cancel(); timeout?.cancel(); task = nil; timeout = nil
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
