import AppKit
import QuartzCore
import Observation
import SwiftUI
import MokuseiPluginUI

struct HandoffStage: NSViewRepresentable {
    let model: PreviewModel
    func makeNSView(context: Context) -> HandoffStageView { HandoffStageView(model: model) }
    func updateNSView(_ view: HandoffStageView, context: Context) {
        view.configure(revision: model.revision, play: model.playRequested,
            longResult: model.longResult, reduced: model.reduceMotion, slow: model.slow,
            dark: model.dark)
    }
    static func dismantleNSView(_ view: HandoffStageView, coordinator: ()) { view.cancel() }
}

private final class FlippedSeat: NSView {
    override var isFlipped: Bool { true }
}

private final class ReaderMotionSeat: NSView {
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        for child in subviews { child.frame = bounds }
    }
}

@MainActor @Observable private final class ReaderAdmission {
    var enabled = false
}

private struct ReaderSeat: View {
    let document: ExecutionDocument
    let admission: ReaderAdmission
    var body: some View {
        document.allowsHitTesting(admission.enabled).accessibilityHidden(!admission.enabled)
    }
}

/// Core Animation owns travel on plain AppKit seats. Model frames stay visible
/// during travel: moving them offscreen makes TextKit cull ink before landing.
@MainActor final class HandoffStageView: NSView {
    override var isFlipped: Bool { true }
    private weak var model: PreviewModel?
    private let mainShell = FlippedSeat()
    private let sideShell = FlippedSeat()
    private var previous: ReaderMotionSeat!
    private var latest: ReaderMotionSeat!
    private var side: ReaderMotionSeat!
    private var revision = -1
    private var generation = UUID()
    private var longResult = false
    private var reduced = false
    private var slow = false
    private var playing = false
    private var landed = false
    private var ready = Set<String>()
    private var preparation: Task<Void, Never>?
    private var geometrySize = CGSize.zero
    private var mainRect = CGRect.zero
    private var sideRect = CGRect.zero
    private var fullRect = CGRect.zero
    private var pageWidth: CGFloat = 0
    private var admissions: [String: ReaderAdmission] = [:]

    init(model: PreviewModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        for shell in [mainShell, sideShell] {
            shell.wantsLayer = true
            shell.layer?.anchorPoint = .zero
            shell.layer?.cornerRadius = 22
            shell.layer?.masksToBounds = true
            shell.layer?.borderWidth = 0.6
            addSubview(shell)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(revision: Int, play: Bool, longResult: Bool, reduced: Bool, slow: Bool, dark: Bool) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            for shell in [mainShell, sideShell] {
                shell.layer?.backgroundColor = NSColor(NativePalette.thread.canvas.swiftUI).cgColor
                shell.layer?.borderColor = NSColor(NativePalette.thread.line.swiftUI).cgColor
            }
        }
        // System Reduce Motion is never overridden by the preview switch.
        let newlyReduced = reduced && !self.reduced
        self.reduced = reduced; self.slow = slow
        guard revision != self.revision else {
            if newlyReduced && playing { settle() }
            return
        }
        let sameResult = self.longResult == longResult
        self.revision = revision; self.longResult = longResult
        if play && previous != nil && !playing && !landed && sameResult {
            // Completion must retain the already visible reader and its scroll
            // position. Only the source's execution status/content changes.
            playing = true; updateAdmission(); ready.remove("side")
            side.removeFromSuperview()
            side = host(latest: true, sidecard: true, completed: true, key: "side", visit: generation)
            sideShell.addSubview(side); side.frame = sideShell.bounds
            report("准备结果 · 等待原生正文排版", busy: true)
        } else {
            rebuild(play: play)
        }
    }

    private func rebuild(play: Bool) {
        cancel()
        landed = false; playing = play; ready.removeAll()
        admissions.removeAll()
        let visit = generation
        for old in [previous, latest, side] { old?.removeFromSuperview() }
        previous = host(latest: false, sidecard: false, completed: true, key: "previous", visit: visit)
        latest = host(latest: true, sidecard: false, completed: true, key: "latest", visit: visit)
        side = host(latest: true, sidecard: true, completed: play, key: "side", visit: visit)
        mainShell.addSubview(previous); mainShell.addSubview(latest); sideShell.addSubview(side)
        geometrySize = .zero
        needsLayout = true; layoutSubtreeIfNeeded()
        report(play ? "准备结果 · 等待原生正文排版" : "上一轮仍在主 detail · 新 execution 在右侧运行", busy: play)
    }

    private func host(latest: Bool, sidecard: Bool, completed: Bool, key: String, visit: UUID) -> ReaderMotionSeat {
        let root = ExecutionDocument(latest: latest, longResult: longResult, sidecard: sidecard,
            completed: completed, token: visit.uuidString + key, ready: { [weak self] in
                // Markdown may publish during a hosting update. Deliver only to
                // the matching visit, outside that SwiftUI update transaction.
                DispatchQueue.main.async { [weak self] in self?.documentReady(key, visit: visit) }
            })
        let admission = ReaderAdmission()
        admission.enabled = !playing && key != "latest"
        admissions[key] = admission
        let host = NSHostingView(rootView: AnyView(ReaderSeat(document: root, admission: admission)))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        let seat = ReaderMotionSeat()
        seat.wantsLayer = true; seat.addSubview(host)
        return seat
    }

    private func documentReady(_ key: String, visit: UUID) {
        guard generation == visit else { return }
        ready.insert(key)
        guard playing, ready.isSuperset(of: ["previous", "latest", "side"]), preparation == nil else { return }
        preparation = Task { [weak self] in
            // A short completed-state hold makes the result legible before the
            // shared movement. Content readiness above remains the admission gate.
            do { try await Task.sleep(for: .milliseconds(self?.reduced == true ? 0 : 220)) }
            catch { return }
            guard let self, generation == visit, playing else { return }
            layoutSubtreeIfNeeded()
            if reduced { settle() } else { turnPage(visit: visit) }
        }
    }

    override func layout() {
        super.layout()
        guard bounds.size != geometrySize, bounds.width > 0, bounds.height > 0 else { return }
        let resizing = geometrySize != .zero
        geometrySize = bounds.size
        fullRect = bounds
        let cardWidth = min(400, max(300, bounds.width * 0.33))
        mainRect = CGRect(x: 0, y: 0, width: bounds.width - cardWidth - 16, height: bounds.height)
        sideRect = CGRect(x: mainRect.maxX + 16, y: 0, width: cardWidth, height: bounds.height)
        pageWidth = mainRect.width
        if resizing && playing {
            // Resize settles travel only after admitted content is available.
            // During preparation keep the source and its readiness callbacks.
            if ready.contains("latest") {
                generation = UUID(); preparation?.cancel(); preparation = nil
                removeAnimations()
                landed = true; playing = false
                updateAdmission()
                report("调整窗口 · 已停靠到最新结果", busy: false)
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mainShell.frame = landed ? fullRect : mainRect
        sideShell.frame = sideRect
        sideShell.isHidden = landed
        sideShell.layer?.opacity = 1
        for page in [previous, latest] {
            page?.frame = CGRect(x: landed ? (fullRect.width - pageWidth) / 2 : 0, y: 0,
                width: pageWidth, height: bounds.height)
            page?.layer?.transform = CATransform3DIdentity
        }
        previous?.isHidden = landed
        // Prewarm at a visible model frame behind an opacity gate. Native text
        // must not see an offscreen viewport while its compositor seat travels.
        latest?.isHidden = false
        latest?.alphaValue = landed ? 1 : 0
        side?.frame = sideShell.bounds
        side?.alphaValue = 1
        CATransaction.commit()
    }

    private func turnPage(visit: UUID) {
        guard bounds.height > 0 else { return }
        report("向下翻到新结果 · sidecard 吸入主面板", busy: true)
        latest.isHidden = false
        let duration = NativeReadingPageTiming.duration * (slow ? 3 : 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        latest.alphaValue = 1
        CATransaction.commit()
        animate(previous.layer!, key: "transform.translation.y", from: 0, to: -bounds.height,
            duration: duration, retain: true)
        absorbSidecard(duration: duration)
        animate(latest.layer!, key: "transform.translation.y", from: bounds.height, to: 0, duration: duration) { [weak self] in
            guard let self, generation == visit, playing else { return }
            previous.isHidden = true
            sideShell.isHidden = true
            expandMain(visit: visit)
        }
    }

    private func absorbSidecard(duration: Double) {
        // Pull the retained source into the lower-right area of the arriving
        // page. Geometry stays inside the main panel, never at the launcher.
        // Scale the rendered source as a whole, preserving native text layout.
        // Presentation-only travel keeps its model viewport alive until hidden.
        let scale = 0.08
        let destination = CGPoint(x: mainRect.width * 0.72 - sideRect.width * scale / 2,
            y: mainRect.height * 0.64 - sideRect.height * scale / 2)
        let source = NSValue(point: sideShell.layer!.position)
        // A brief shared onset leaves the result legible, then the source
        // accelerates into the incoming page and disappears at the same landing.
        keyframes(sideShell.layer!, key: "position", values: [source, source, NSValue(point: destination)],
            times: [0, 0.12, 1], duration: duration)
        keyframes(sideShell.layer!, key: "transform.scale", values: [1, 1, scale],
            times: [0, 0.12, 1], duration: duration)
        keyframes(sideShell.layer!, key: "opacity", values: [1, 1, 0], times: [0, 0.62, 1], duration: duration)
        keyframes(side.layer!, key: "opacity", values: [1, 1, 0], times: [0, 0.32, 1], duration: duration)
    }

    private func expandMain(visit: UUID) {
        report("sidecard 已吸入 · 新结果停靠，主面板展开", busy: true)
        let duration = 0.30 * (slow ? 3 : 1)
        let mainPosition = mainShell.layer!.position
        let mainBounds = mainShell.layer!.bounds
        let pagePosition = latest.layer!.position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mainShell.frame = fullRect
        latest.frame.origin.x = (fullRect.width - pageWidth) / 2
        CATransaction.commit()
        animate(mainShell.layer!, key: "position", from: mainPosition, to: mainShell.layer!.position, duration: duration)
        animate(latest.layer!, key: "position", from: pagePosition, to: latest.layer!.position, duration: duration)
        animate(mainShell.layer!, key: "bounds", from: mainBounds, to: mainShell.layer!.bounds, duration: duration) { [weak self] in
            guard let self, generation == visit, playing else { return }
            settle()
        }
    }

    private func keyframes(_ layer: CALayer, key: String, values: [Any], times: [NSNumber], duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values; animation.keyTimes = times; animation.duration = duration
        animation.isRemovedOnCompletion = false; animation.fillMode = .forwards
        animation.timingFunctions = [CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.42, 0, 0.2, 1)]
        layer.add(animation, forKey: key)
    }

    private func animate(_ layer: CALayer, key: String, from: Any, to: Any, duration: Double,
                         retain: Bool = false,
                         completion: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        if let completion {
            CATransaction.setCompletionBlock { Task { @MainActor in completion() } }
        }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to
        animation.duration = duration
        if retain { animation.isRemovedOnCompletion = false; animation.fillMode = .forwards }
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        layer.add(animation, forKey: key)
        CATransaction.commit()
    }

    private func settle() {
        // Readiness is checked even when Reduce Motion changes during loading.
        guard ready.contains("latest") else { return }
        generation = UUID(); preparation?.cancel(); preparation = nil
        landed = true; playing = false
        updateAdmission()
        removeAnimations()
        geometrySize = .zero; needsLayout = true; layoutSubtreeIfNeeded()
        report(reduced ? "最新结果已接住 · 减弱动态效果" : "最新结果已接住 · 可滚动阅读，或重播比较", busy: false)
    }
    private func removeAnimations() {
        for view in [mainShell, sideShell, previous, latest, side] { view?.layer?.removeAllAnimations() }
    }
    private func updateAdmission() {
        admissions["previous"]?.enabled = !playing && !landed
        admissions["latest"]?.enabled = !playing && landed
        admissions["side"]?.enabled = !playing && !landed
    }
    func cancel() {
        generation = UUID(); preparation?.cancel(); preparation = nil
        playing = false
        removeAnimations()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { playing ? nil : super.hitTest(point) }
    private func report(_ text: String, busy: Bool) {
        let visit = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == visit else { return }
            model?.status = text; model?.busy = busy
        }
    }
}
