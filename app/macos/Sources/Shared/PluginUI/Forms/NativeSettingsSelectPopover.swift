import AppKit
import MokuseiCore
import SwiftUI

/// Source sf-select styling, including its opaque, anchor-width option list.
public struct NativeSettingsSelectPopover: View {
    @Binding private var selection: JSONText
    private let options: [NativeSettingsOption]
    private let accessibilityLabel: String
    private let accessibilityDescription: String?
    private let invalid: Bool
    public init(selection: Binding<JSONText>, options: [NativeSettingsOption], accessibilityLabel: String,
                accessibilityDescription: String? = nil, invalid: Bool = false) {
        _selection = selection; self.options = options; self.accessibilityLabel = accessibilityLabel
        self.accessibilityDescription = accessibilityDescription; self.invalid = invalid
    }
    public var body: some View {
        SettingsSelectRepresentation(selection: $selection, options: options, label: accessibilityLabel,
                                     description: accessibilityDescription, invalid: invalid)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            .background(NativeSettingsControlRegistration(descriptor: .object([
                "kind": .text("select"), "label": .text(accessibilityLabel), "value": .string(selection),
                "invalid": .bool(invalid), "operations": .array([.text("select")]),
                "options": .array(options.map { .object(["id": .string($0.id), "label": .text($0.label), "enabled": .bool(!$0.disabled)]) })
            ])) { _, value in
                guard case .string(let id) = value, options.contains(where: { $0.id == id && !$0.disabled }) else {
                    throw NativeSettingsControlError("invalid_request", "Select requires an available option ID")
                }
                NativeSettingsChangeContext.withDiscreteChange { selection = id }
            })
    }
}

private struct SettingsSelectRepresentation: NSViewRepresentable {
    @Binding var selection: JSONText
    let options: [NativeSettingsOption]
    let label: String
    let description: String?
    let invalid: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.nativeSettingsField) private var field

    func makeNSView(context: Context) -> SettingsSelectControl { SettingsSelectControl() }
    func updateNSView(_ view: SettingsSelectControl, context: Context) {
        view.configure(label: label, description: description, options: options,
                       selectedIndex: options.firstIndex { $0.id == selection }, fallbackTitle: selection.string,
                       enabled: isEnabled, invalid: invalid) { index in
            guard options.indices.contains(index), !options[index].disabled else { return }
            NativeSettingsChangeContext.withDiscreteChange { selection = options[index].id }
        }
        view.installActivation(field.activation)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsSelectControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: max(34, proposal.height ?? 34))
    }
    static func dismantleNSView(_ view: SettingsSelectControl, coordinator: ()) { view.dispose() }
}

@MainActor private final class SettingsSelectControl: NSControl, NSWindowDelegate {
    private var titles: [String] = []
    private var options: [NativeSettingsOption] = []
    private var selectedIndex: Int?
    private var fallbackTitle = ""
    private var invalid = false
    private var choose: ((Int) -> Void)?
    private var popup: SettingsSelectPanel?
    private var pointerInside = false
    private var keyboardFocus = false
    private var tracking: NSTrackingArea?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var activation: NativeSettingsFieldActivation?
    private let activationOwner = UUID()
    private var paintFrom: SettingsSelectPaint?
    private var paintTo: SettingsSelectPaint?
    private var paintStarted: TimeInterval = 0
    private var chevronFrom: CGFloat = 0
    private var chevronTo: CGFloat = 0
    private var chevronStarted: TimeInterval = 0
    private var animationTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled && !titles.isEmpty }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }
    override var wantsDefaultClipping: Bool { false }

    func installActivation(_ activation: NativeSettingsFieldActivation?) {
        if self.activation !== activation { self.activation?.remove(owner: activationOwner); self.activation = activation }
        activation?.install(owner: activationOwner) { [weak self] in _ = self?.accessibilityPerformPress() }
    }

    func dispose() {
        dismiss(restoreFocus: false); activation?.remove(owner: activationOwner); activation = nil
        animationTimer?.invalidate(); animationTimer = nil
    }

    func configure(label: String, description: String?, options: [NativeSettingsOption], selectedIndex: Int?, fallbackTitle: String,
                   enabled: Bool, invalid: Bool, choose: @escaping (Int) -> Void) {
        let changedOptions = self.options != options
        self.options = options; titles = options.map(\.label)
        self.selectedIndex = selectedIndex; self.choose = choose; self.fallbackTitle = fallbackTitle; self.invalid = invalid
        isEnabled = enabled && !titles.isEmpty
        alphaValue = isEnabled ? 1 : 0.5
        setAccessibilityLabel(label)
        setAccessibilityHelp(description)
        setAccessibilityValue(selectedIndex.map { titles[$0] } ?? fallbackTitle)
        setAccessibilityEnabled(isEnabled)
        if !isEnabled || changedOptions { dismiss(restoreFocus: false) }
        if let menu = popup?.contentView as? SettingsSelectMenu { menu.updateSelection(selectedIndex) }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { keyboardFocus = true; needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismiss(restoreFocus: false) }
        if newWindow == nil { animationTimer?.invalidate(); animationTimer = nil }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        popup?.appearance = effectiveAppearance; popup?.updateShadowAppearance()
        popup?.contentView?.needsDisplay = true; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = ProcessInfo.processInfo.systemUptime
        updateVisualTargets(at: now)
        let paint = presentationPaint(at: now)!
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        paint.background.setFill(); shape.fill()
        paint.border.setStroke()
        shape.lineWidth = 1; shape.stroke()
        if isFocusVisible {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -3), xRadius: 9, yRadius: 9)
            SettingsSelectStyle.tint(0.22, dark: 0.25).setStroke(); outline.lineWidth = 2; outline.stroke()
        }
        let title = selectedIndex.map { titles[$0] } ?? fallbackTitle
        SettingsSelectStyle.text(title).draw(in: NSRect(x: 12, y: (bounds.height - 18.2) / 2, width: max(0, bounds.width - 48), height: 18.2))
        let progress = presentationChevron(at: now)
        let center = NSPoint(x: bounds.maxX - 17, y: bounds.midY - 1.5 + 3 * progress)
        let angle = (45 + 180 * progress) * .pi / 180
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
        let chevron = NSBezierPath()
        // The CSS icon is the right and bottom edges of a 6 × 6 box.
        chevron.move(to: point(3, -3)); chevron.line(to: point(3, 3)); chevron.line(to: point(-3, 3))
        chevron.lineWidth = 1.3; chevron.lineCapStyle = .butt; chevron.lineJoinStyle = .miter
        NativePlatformPalette.settings.muted.setStroke(); chevron.stroke()
    }

    private var isFocusVisible: Bool {
        isEnabled && keyboardFocus && (window?.isKeyWindow == true || popup?.isKeyWindow == true) && window?.firstResponder === self
    }

    private func presentationPaint(at now: TimeInterval) -> SettingsSelectPaint? {
        guard let paintFrom, let paintTo else { return nil }
        return paintFrom.mixed(with: paintTo, fraction: SettingsSelectTiming.ease((now - paintStarted) / 0.12))
    }

    private func presentationChevron(at now: TimeInterval) -> CGFloat {
        chevronFrom + (chevronTo - chevronFrom) * SettingsSelectTiming.ease((now - chevronStarted) / 0.14)
    }

    private func updateVisualTargets(at now: TimeInterval) {
        let active = isEnabled && (pointerInside || popup != nil)
        var target: SettingsSelectPaint!
        effectiveAppearance.performAsCurrentDrawingAppearance {
            target = SettingsSelectPaint(background: SettingsSelectStyle.tint(active ? 0.05 : 0.025),
                                         border: invalid ? NativePlatformPalette.settings.danger : isFocusVisible ? SettingsSelectStyle.tint(0.24) : active ? SettingsSelectStyle.tint(0.16) : NativePlatformPalette.settings.line)
        }
        if paintTo != target {
            paintFrom = presentationPaint(at: now) ?? target; paintTo = target; paintStarted = now
        }
        let chevronTarget: CGFloat = popup == nil ? 0 : 1
        if chevronTarget != chevronTo {
            chevronFrom = presentationChevron(at: now); chevronTo = chevronTarget; chevronStarted = now
        }
        if window == nil {
            paintFrom = paintTo; chevronFrom = chevronTo
            paintStarted = now - 0.12; chevronStarted = now - 0.14
        }
        let animating = paintFrom != paintTo && now - paintStarted < 0.12 || chevronFrom != chevronTo && now - chevronStarted < 0.14
        guard animating else { animationTimer?.invalidate(); animationTimer = nil; return }
        if animationTimer == nil {
            let timer = Timer(timeInterval: NativeFrameRate.interval, repeats: true) { [weak self] timer in
                let alive = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    self.updateVisualTargets(at: ProcessInfo.processInfo.systemUptime)
                    self.needsDisplay = true
                    return true
                }
                if !alive { timer.invalidate() }
            }
            animationTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self); keyboardFocus = false
        if popup != nil { dismiss() } else { present() }
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        keyboardFocus = true
        switch event.keyCode {
        case 36, 49, 76, 125, 126: present()
        default:
            if SettingsSelectMenu.isSearchEvent(event) { present(); (popup?.contentView as? SettingsSelectMenu)?.keyDown(with: event) }
            else { super.keyDown(with: event) }
        }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        if popup != nil { dismiss() } else { present() }
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard isEnabled else { return false }
        present(); return popup != nil
    }

    private func present() {
        guard popup == nil, isEnabled, !titles.isEmpty, let owner = window, let screen = owner.screen, let content = owner.contentView else { return }
        owner.makeFirstResponder(self)
        let anchor = owner.convertToScreen(convert(bounds, to: nil))
        let viewport = owner.convertToScreen(content.convert(content.bounds, to: nil)).intersection(screen.visibleFrame)
        guard !viewport.isEmpty, viewport.width > 24 else { return }
        let available = viewport.insetBy(dx: 12, dy: 0)
        let width = min(anchor.width, available.width)
        let menu = SettingsSelectMenu(options: options, selectedIndex: selectedIndex, width: width)
        menu.setAccessibilityLabel(accessibilityLabel())
        let height = min(menu.preferredHeight, min(288, viewport.height * 0.7))
        let below = anchor.minY - 5 - available.minY
        let above = available.maxY - anchor.maxY - 5
        let useBelow = below >= height || below >= above
        let fittedHeight = min(height, max(0, useBelow ? below : above))
        guard fittedHeight >= 30 else { return }
        let origin = NSPoint(x: max(available.minX, min(anchor.minX, available.maxX - width)),
                             y: useBelow ? anchor.minY - 5 - fittedHeight : anchor.maxY + 5)
        let panel = SettingsSelectPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: fittedHeight)), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = true; panel.isFloatingPanel = false; panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false; panel.level = owner.level
        panel.appearance = effectiveAppearance
        panel.contentView = menu; panel.delegate = self
        menu.commit = { [weak self, weak panel] index in
            guard let self, let panel, self.popup === panel else { return }
            let action = self.choose
            self.dismiss()
            action?(index)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        menu.cancel = { [weak self, weak panel] in
            guard let self, let panel, self.popup === panel else { return }
            self.dismiss()
        }
        menu.advanceFocus = { [weak self, weak panel] backwards in
            guard let self, let panel, self.popup === panel else { return }
            let parent = self.window
            self.dismiss()
            if backwards { parent?.selectKeyView(preceding: self) } else { parent?.selectKeyView(following: self) }
        }
        popup = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.installShadow(in: viewport)
        // A key panel gives Escape its own event.window, so the page-level
        // NativeSettingsEscapeHandler leaves this picker cancellation alone.
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(menu)
        menu.focusActive()
        setAccessibilityExpanded(true); needsDisplay = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let popup = self.popup, event.window !== popup else { return false }
                if event.type == .leftMouseDown, event.window === self.window,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.dismiss()
                    return true
                }
                // Parent scrolling must not leave the popup detached from its anchor.
                self.dismiss(restoreFocus: event.type == .scrollWheel && event.window === self.window)
                return false
            }
            return handled ? nil : event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        })
    }

    func dismiss(restoreFocus: Bool = true) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let panel = popup else { return }
        if let menu = panel.contentView as? SettingsSelectMenu {
            menu.commit = nil; menu.cancel = nil; menu.advanceFocus = nil
        }
        popup = nil; panel.delegate = nil
        let hadKey = panel.isKeyWindow
        panel.removeShadow()
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close()
        setAccessibilityExpanded(false); needsDisplay = true
        if restoreFocus, hadKey, NSApp.isActive { window?.makeKey(); window?.makeFirstResponder(self) }
    }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }
}

@MainActor private final class SettingsSelectPanel: NSPanel {
    private var shadowPanel: SettingsSelectShadowPanel?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func installShadow(in viewport: CGRect) {
        // CSS shadows do not participate in hit testing. A separate decorative
        // window preserves the exact interactive/AX/anchor rect of the menu.
        let shadowFrame = frame.insetBy(dx: -40, dy: -40).intersection(viewport)
        let body = CGRect(x: frame.minX - shadowFrame.minX, y: shadowFrame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let shadow = SettingsSelectShadowPanel(contentRect: shadowFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        shadow.isReleasedWhenClosed = false; shadow.isOpaque = false; shadow.backgroundColor = .clear
        shadow.hasShadow = false; shadow.ignoresMouseEvents = true; shadow.hidesOnDeactivate = true
        shadow.alphaValue = alphaValue
        shadow.animationBehavior = .none; shadow.isExcludedFromWindowsMenu = true; shadow.level = level
        shadow.appearance = appearance
        let host = NSHostingView(rootView: SettingsSelectShadow(body: body, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
        host.setAccessibilityElement(false); shadow.setAccessibilityElement(false); shadow.contentView = host
        shadowPanel = shadow; addChildWindow(shadow, ordered: .below)
        shadow.orderFront(nil)
    }

    func updateShadowAppearance() {
        guard let shadowPanel, let host = shadowPanel.contentView as? NSHostingView<SettingsSelectShadow> else { return }
        shadowPanel.appearance = appearance
        host.rootView = SettingsSelectShadow(body: host.rootView.bodyRect, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    func removeShadow() {
        guard let shadowPanel else { return }
        self.shadowPanel = nil; removeChildWindow(shadowPanel); shadowPanel.orderOut(nil); shadowPanel.close()
    }
}

@MainActor private final class SettingsSelectShadowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SettingsSelectShadow: View {
    let bodyRect: CGRect
    let dark: Bool
    init(body: CGRect, dark: Bool) { bodyRect = body; self.dark = dark }
    var body: some View {
        Canvas { context, _ in
            context.clip(to: Path(roundedRect: bodyRect, cornerRadius: 8), options: .inverse)
            // CSS paints the first listed shadow on top. Its blur radius is
            // twice Gaussian sigma; GraphicsContext.blur takes sigma.
            for (offset, sigma, alpha) in [(2.0, 2.5, 0.06), (6.0, 10.0, dark ? 0.25 : 0.1)] {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: sigma))
                    layer.fill(Path(roundedRect: bodyRect.offsetBy(dx: 0, dy: offset), cornerRadius: 8), with: .color(.black.opacity(alpha)))
                }
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}

@MainActor private final class SettingsSelectMenu: NSView {
    var commit: ((Int) -> Void)?
    var cancel: (() -> Void)?
    var advanceFocus: ((Bool) -> Void)?
    private let scroll = NativeStyledScrollView()
    private let document = SettingsSelectDocument()
    private var rows: [SettingsSelectOptionButton] = []
    private var active: Int
    private var search = ""
    private var lastSearch: TimeInterval = 0
    let preferredHeight: CGFloat

    init(options: [NativeSettingsOption], selectedIndex: Int?, width: CGFloat) {
        active = selectedIndex.flatMap { options[$0].disabled ? nil : $0 } ?? options.firstIndex { !$0.disabled } ?? -1
        let titles = options.map(\.label)
        let rowWidth = max(0, width - 10)
        let heights = titles.map { title in
            max(30, ceil(SettingsSelectStyle.text(title, wrapping: true).boundingRect(with: NSSize(width: max(1, rowWidth - 42), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 12))
        }
        preferredHeight = heights.reduce(10, +)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: preferredHeight))
        setAccessibilityElement(true); setAccessibilityRole(.menu)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        NativeScrollbarStyle.apply(to: scroll); scroll.documentView = document
        scroll.frame = bounds.insetBy(dx: 5, dy: 5); scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        var y: CGFloat = 0
        for (index, title) in titles.enumerated() {
            let row = SettingsSelectOptionButton(frame: NSRect(x: 0, y: y, width: rowWidth, height: heights[index]))
            row.title = title; row.tag = index; row.target = self; row.action = #selector(selectRow(_:))
            row.isEnabled = !options[index].disabled; row.alphaValue = row.isEnabled ? 1 : 0.5
            row.pointed = { [weak self] in self?.setActive(index) }
            row.keyPressed = { [weak self] event in self?.keyDown(with: event) }
            row.setAccessibilityLabel(title); row.setAccessibilityRole(.menuItem)
            rows.append(row); document.addSubview(row); y += heights[index]
        }
        document.frame = NSRect(x: 0, y: 0, width: rowWidth, height: y)
        setAccessibilityChildren(rows)
        updateSelection(selectedIndex); setActive(active, announce: false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); scroll.frame = bounds.insetBy(dx: 5, dy: 5) }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NativePlatformPalette.pair(0xffffff, 0x292b2f).setFill(); shape.fill()
        SettingsSelectStyle.tint(0.1, dark: 0.09).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
    func updateSelection(_ selected: Int?) {
        for (index, row) in rows.enumerated() {
            row.chosen = index == selected
            row.setAccessibilityValue(row.chosen ? 1 : 0)
            row.setAccessibilitySelected(row.chosen)
        }
        setAccessibilitySelectedChildren(rows.filter(\.chosen))
    }
    func focusActive() { setActive(active) }
    private func revealActive() { layoutSubtreeIfNeeded(); if rows.indices.contains(active) { document.scrollToVisible(rows[active].frame) } }
    private func setActive(_ index: Int, announce: Bool = true) {
        guard rows.indices.contains(index), rows[index].isEnabled else { return }
        active = index
        for (offset, row) in rows.enumerated() { row.highlightedOption = offset == index }
        revealActive()
        if let window {
            window.makeFirstResponder(rows[index])
            if announce { NSAccessibility.post(element: rows[index], notification: .focusedUIElementChanged) }
        }
    }
    @objc private func selectRow(_ sender: NSButton) { if sender.isEnabled { commit?(sender.tag) } }
    override func cancelOperation(_ sender: Any?) { cancel?() }
    override func accessibilityPerformCancel() -> Bool { cancel?(); return true }
    static func isSearchEvent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xf700...0xf8ff).contains($0.value) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel?()
        case 36, 49, 76: if rows.indices.contains(active), rows[active].isEnabled { commit?(active) }
        case 125: if let index = rows.indices.first(where: { $0 > active && rows[$0].isEnabled }) { setActive(index) }
        case 126: if let index = rows.indices.last(where: { $0 < active && rows[$0].isEnabled }) { setActive(index) }
        case 115: if let index = rows.indices.first(where: { rows[$0].isEnabled }) { setActive(index) }
        case 119: if let index = rows.indices.last(where: { rows[$0].isEnabled }) { setActive(index) }
        case 48: advanceFocus?(event.modifierFlags.contains(.shift))
        default:
            guard Self.isSearchEvent(event), let characters = event.characters, !characters.isEmpty else { super.keyDown(with: event); return }
            let now = event.timestamp
            search = now - lastSearch < 0.8 ? search + characters : characters
            lastSearch = now
            let cycle = search.count > 1 && Set(search.lowercased()).count == 1
            let prefix = cycle ? characters : search
            let start = max(0, prefix.count == 1 ? active + 1 : active)
            for offset in 0..<rows.count {
                let index = (start + offset) % rows.count
                if rows[index].isEnabled, rows[index].title.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { setActive(index); break }
            }
        }
    }
}

@MainActor private final class SettingsSelectDocument: NSView { override var isFlipped: Bool { true } }

@MainActor private final class SettingsSelectOptionButton: NSButton {
    var chosen = false { didSet { needsDisplay = true } }
    var highlightedOption = false { didSet { needsDisplay = true } }
    var pointed: (() -> Void)?
    var keyPressed: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; focusRingType = .none; setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { pointed?() }
    override func keyDown(with event: NSEvent) { keyPressed?(event) }
    override func draw(_ dirtyRect: NSRect) {
        if highlightedOption || chosen {
            SettingsSelectStyle.tint(highlightedOption ? 0.075 : 0.035, dark: highlightedOption ? 0.085 : 0.035).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        SettingsSelectStyle.text(title, wrapping: true, muted: !isEnabled).draw(in: NSRect(x: 9, y: 6, width: max(0, bounds.width - 42), height: max(0, bounds.height - 12)))
        if chosen {
            NSAttributedString(string: "✓", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NativePlatformPalette.settings.muted])
                .draw(in: NSRect(x: bounds.maxX - 21, y: (bounds.height - 16) / 2, width: 12, height: 16))
        }
    }
}

@MainActor private enum SettingsSelectStyle {
    static func tint(_ alpha: CGFloat, dark: CGFloat? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NativePlatformPalette.color(isDark ? 0xffffff : 0x232830, alpha: Double(isDark ? dark ?? alpha : alpha))
        }
    }
    static func text(_ string: String, wrapping: Bool = false, muted: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        paragraph.minimumLineHeight = 18.2; paragraph.maximumLineHeight = 18.2
        return NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: muted ? NativePlatformPalette.settings.muted : NativePlatformPalette.settings.text, .paragraphStyle: paragraph])
    }
}

@MainActor private struct SettingsSelectPaint: Equatable {
    let background: NSColor
    let border: NSColor
    init(background: NSColor, border: NSColor) {
        self.background = background.usingColorSpace(.sRGB) ?? background
        self.border = border.usingColorSpace(.sRGB) ?? border
    }
    func mixed(with target: Self, fraction: CGFloat) -> Self {
        func mix(_ from: NSColor, _ to: NSColor) -> NSColor {
            let alpha = from.alphaComponent + (to.alphaComponent - from.alphaComponent) * fraction
            guard alpha > 0 else { return .clear }
            // CSS interpolates translucent colors with premultiplied alpha.
            func channel(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
                (first * from.alphaComponent * (1 - fraction) + second * to.alphaComponent * fraction) / alpha
            }
            return NSColor(srgbRed: channel(from.redComponent, to.redComponent),
                           green: channel(from.greenComponent, to.greenComponent),
                           blue: channel(from.blueComponent, to.blueComponent), alpha: alpha)
        }
        return Self(background: mix(background, target.background), border: mix(border, target.border))
    }
}

private enum SettingsSelectTiming {
    /// CSS ease is cubic-bezier(.25, .1, .25, 1); input time is its x axis.
    static func ease(_ time: TimeInterval) -> CGFloat {
        guard time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        func coordinate(_ t: Double, _ first: Double, _ second: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * first + 3 * (1 - t) * t * t * second + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let midpoint = (low + high) / 2
            if coordinate(midpoint, 0.25, 0.25) < time { low = midpoint } else { high = midpoint }
        }
        return CGFloat(coordinate((low + high) / 2, 0.1, 1))
    }
}
