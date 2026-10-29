import AppKit
import MokuseiCore
import SwiftUI

/// A document-level Escape monitor must give its focused control's transient
/// presentation first refusal before navigating away from the document.
@MainActor public protocol NativeSettingsEscapeCancelling: AnyObject {
    func cancelSettingsPresentation() -> Bool
}

/// Model identities and the order of reasoning choices belong to the Harness.
/// This control never derives capabilities, defaults or wire values from labels.
public struct NativeModelSelector: View {
    public enum Presentation: Sendable { case models, reasoning }

    public struct ModelLink {
        let value: Binding<JSONText>
        let options: [NativeSettingsOption]
        let label: String
        public init(value: Binding<JSONText>, options: [NativeSettingsOption], label: String) {
            self.value = value; self.options = options; self.label = label
        }
    }

    @Binding private var value: JSONText
    private let options: [NativeSettingsOption]
    private let presentation: Presentation
    private let model: ModelLink?
    private let label: String?
    @Environment(\.nativeSettingsField) private var field
    @Environment(\.nativeSettingsFormPage) private var formPage
    @Environment(\.nativeSettingsCompactPresentation) private var compactPresentation

    public init(value: Binding<JSONText>, options: [NativeSettingsOption],
                presentation: Presentation = .models, model: ModelLink? = nil,
                accessibilityLabel: String? = nil) {
        _value = value; self.options = options; self.presentation = presentation
        self.model = model; label = accessibilityLabel
    }

    public var body: some View {
        if formPage || compactPresentation {
            NativeSettingsSelect(value: $value, options: options, accessibilityLabel: label)
        } else {
            embeddedSelector
        }
    }

    private var embeddedSelector: some View {
        ModelSelectorRepresentation(value: value, options: options, presentation: presentation,
                                    model: model, label: label ?? field.label, help: field.description,
                                    invalid: field.invalid) { id in
            NativeSettingsChangeContext.withDiscreteChange { value = id }
        }
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .background(NativeSettingsControlRegistration(descriptor: .object([
            "kind": .text("select"), "label": .text(label ?? field.label), "value": .string(value),
            "invalid": .bool(field.invalid), "operations": .array([.text("select")]),
            "options": .array(options.map { .object([
                "id": .string($0.id), "label": .text($0.label), "enabled": .bool(!$0.disabled)
            ]) })
        ])) { _, next in
            guard case .string(let id) = next, options.contains(where: { $0.id == id && !$0.disabled }) else {
                throw NativeSettingsControlError("invalid_request", "Select requires an available option ID")
            }
            NativeSettingsChangeContext.withDiscreteChange { value = id }
        })
    }
}

private struct ModelSelectorRepresentation: NSViewRepresentable {
    let value: JSONText
    let options: [NativeSettingsOption]
    let presentation: NativeModelSelector.Presentation
    let model: NativeModelSelector.ModelLink?
    let label: String
    let help: String?
    let invalid: Bool
    let choose: (JSONText) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeSettingsField) private var field

    func makeNSView(context: Context) -> ModelSelectorButton { ModelSelectorButton() }
    func updateNSView(_ view: ModelSelectorButton, context: Context) {
        view.configure(value: value, options: options, presentation: presentation, model: model,
                       label: label, help: help, invalid: invalid, enabled: enabled, choose: choose)
        view.installActivation(field.activation)
    }
    static func dismantleNSView(_ view: ModelSelectorButton, coordinator: ()) { view.dispose() }
}

@MainActor private final class ModelSelectorButton: NSButton, NSPopoverDelegate, NativeSettingsEscapeCancelling {
    private var value: JSONText = ""
    private var options: [NativeSettingsOption] = []
    private var presentation = NativeModelSelector.Presentation.models
    private var model: NativeModelSelector.ModelLink?
    private var modelValue: JSONText?
    private var choose: ((JSONText) -> Void)?
    private var invalid = false
    private var popover: NSPopover?
    private weak var activation: NativeSettingsFieldActivation?
    private let activationOwner = UUID()
    private var observers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?

    init() {
        super.init(frame: .zero)
        isBordered = false; alignment = .left; focusRingType = .none
        font = .systemFont(ofSize: 13)
        target = self; action = #selector(toggle)
        setAccessibilityRole(.popUpButton)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 34) }
    override var acceptsFirstResponder: Bool { isEnabled }

    func installActivation(_ next: NativeSettingsFieldActivation?) {
        if activation !== next { activation?.remove(owner: activationOwner); activation = next }
        next?.install(owner: activationOwner) { [weak self] in self?.performClick(nil) }
    }

    func configure(value: JSONText, options: [NativeSettingsOption], presentation: NativeModelSelector.Presentation,
                   model: NativeModelSelector.ModelLink?, label: String, help: String?, invalid: Bool,
                   enabled: Bool, choose: @escaping (JSONText) -> Void) {
        // Capability refresh and provider/model changes retire the old popup callbacks.
        if self.options != options || modelValue != model?.value.wrappedValue ||
            self.model?.options != model?.options || !enabled { dismiss() }
        self.value = value; self.options = options; self.presentation = presentation
        self.model = model; modelValue = model?.value.wrappedValue; self.choose = choose; self.invalid = invalid
        title = options.first { $0.id == value }?.label ?? value.string
        isEnabled = enabled && options.contains { !$0.disabled }
        setAccessibilityLabel(label); setAccessibilityHelp(help); setAccessibilityValue(title)
        setAccessibilityEnabled(isEnabled)
        (popover?.contentViewController?.view as? ModelSelectorContent)?.refresh(value: value, model: model)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 15, yRadius: 15)
        NSColor.labelColor.withAlphaComponent(isHighlighted || popover?.isShown == true ? 0.12 : 0.07).setFill(); capsule.fill()
        if invalid { NSColor.systemRed.setStroke(); capsule.lineWidth = 1; capsule.stroke() }
        if window?.isKeyWindow == true && window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke(); capsule.lineWidth = 2; capsule.stroke()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph
        ])
        text.draw(in: NSRect(x: 13, y: (bounds.height - 17) / 2, width: max(0, bounds.width - 42), height: 17))
        let chevron = NSBezierPath()
        let x = bounds.maxX - 19, y = bounds.midY
        chevron.move(to: NSPoint(x: x - 3, y: y + 2)); chevron.line(to: NSPoint(x: x, y: y - 1))
        chevron.line(to: NSPoint(x: x + 3, y: y + 2)); chevron.lineWidth = 1.4
        chevron.lineCapStyle = .round; NSColor.secondaryLabelColor.setStroke(); chevron.stroke()
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76, 125, 126: open()
        default:
            if modelSelectorSearchText(event) != nil {
                open(); (popover?.contentViewController?.view as? ModelSelectorContent)?.keyDown(with: event)
            } else { super.keyDown(with: event) }
        }
    }
    func cancelSettingsPresentation() -> Bool {
        guard popover?.isShown == true else { return false }
        dismiss(restoreFocus: true)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool { open(); return popover?.isShown == true }
    @objc private func toggle() { if popover?.isShown == true { dismiss(restoreFocus: true) } else { open() } }

    private func open() {
        guard isEnabled, popover?.isShown != true, let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return }
        dismiss()
        // Every presentation owns a new popover. An obsolete close callback must
        // never clear the controller or callbacks of a subsequent presentation.
        let popover = NSPopover()
        popover.behavior = .transient; popover.delegate = self
        self.popover = popover
        window.makeKey(); window.makeFirstResponder(self)
        let content = ModelSelectorContent(value: value, options: options, presentation: presentation,
                                           model: model, label: accessibilityLabel() ?? "")
        content.isActive = { [weak self, weak popover] in
            guard let self, let popover else { return false }
            return self.popover === popover
        }
        content.choose = { [weak self, weak popover] id in
            guard let self, let popover, self.popover === popover else { return }
            self.choose?(id)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        content.dismiss = { [weak self, weak popover] in
            guard let self, let popover, self.popover === popover else { return }
            self.dismiss(restoreFocus: true)
        }
        content.resize = { [weak self, weak popover] size in
            guard let self, let popover, self.popover === popover else { return }
            popover.contentSize = size
        }
        content.advance = { [weak self, weak popover] backwards in
            guard let self, let popover, self.popover === popover else { return }
            self.dismiss(restoreFocus: true)
            if backwards { self.window?.selectKeyView(preceding: self) }
            else { self.window?.selectKeyView(following: self) }
        }
        let controller = NSViewController(); controller.view = content
        popover.contentViewController = controller; popover.contentSize = content.frame.size
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        guard self.popover === popover, popover.isShown else { dismiss(); return }
        content.window?.makeFirstResponder(content)
        content.focusSelection()
        setAccessibilityExpanded(true); needsDisplay = true
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                // A scrolled settings row must not leave a detached popup behind.
                if event.window === self?.window { self?.dismiss() }
            }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        dismiss()
    }
    private func dismiss(restoreFocus: Bool = false) {
        let previous = popover
        popover = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        previous?.delegate = nil
        // Retire synchronously, including a close during a capability refresh.
        // Otherwise rapid reopening can encounter a still-closing native window.
        previous?.animates = false
        previous?.close()
        previous?.contentViewController = nil
        setAccessibilityExpanded(false); needsDisplay = true
        if restoreFocus, NSApp.isActive {
            window?.makeKey(); window?.makeFirstResponder(self)
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismiss() }
        super.viewWillMove(toWindow: newWindow)
    }
    func dispose() {
        dismiss(); activation?.remove(owner: activationOwner); activation = nil
        choose = nil
    }
}

@MainActor final class ModelSelectorContent: NSView, NativeSettingsEscapeCancelling {
    private var value: JSONText
    private var options: [NativeSettingsOption]
    private let presentation: NativeModelSelector.Presentation
    private var model: NativeModelSelector.ModelLink?
    private let label: String
    private var rows: [ModelSelectorRow] = []
    private var active: Int?
    private var slider: NSSlider?
    private var heading: NSTextField?
    private var showingModels = false
    private var search = ""
    private var searchTime: TimeInterval = 0
    var isActive: () -> Bool = { true }
    var choose: ((JSONText) -> Void)?
    var dismiss: (() -> Void)?
    var advance: ((Bool) -> Void)?
    var resize: ((NSSize) -> Void)?
    private var steps: [NativeSettingsOption] { options.filter { !$0.disabled && !$0.id.codeUnits.isEmpty } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(value: JSONText, options: [NativeSettingsOption], presentation: NativeModelSelector.Presentation,
         model: NativeModelSelector.ModelLink?, label: String) {
        self.value = value; self.options = options; self.presentation = presentation; self.model = model; self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(label)
        if presentation == .reasoning && !steps.isEmpty { makeReasoning() } else { makeList() }
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    private func text(_ string: String, size: CGFloat, color: NSColor, rect: NSRect) -> NSTextField {
        let view = NSTextField(labelWithString: string)
        view.font = .systemFont(ofSize: size); view.textColor = color; view.frame = rect
        view.lineBreakMode = .byTruncatingTail; addSubview(view); return view
    }

    private func makeList() {
        subviews.forEach { $0.removeFromSuperview() }; rows = []; slider = nil; heading = nil
        setAccessibilityRole(.menu)
        setAccessibilityLabel(showingModels ? model?.label ?? label : label)
        frame.size.height = min(390, CGFloat(options.count) * 36 + 46)
        _ = text(showingModels ? model?.label ?? label : label, size: 13, color: .secondaryLabelColor,
                 rect: NSRect(x: 16, y: 12, width: 268, height: 20))
        let scroller = NativeStyledScrollView(frame: NSRect(x: 6, y: 40, width: 288, height: frame.height - 46))
        scroller.hasVerticalScroller = true; scroller.drawsBackground = false
        let document = ModelSelectorList(frame: NSRect(x: 0, y: 0, width: 278, height: CGFloat(options.count) * 36))
        for (index, option) in options.enumerated() {
            let row = ModelSelectorRow(frame: NSRect(x: 0, y: CGFloat(index) * 36, width: 278, height: 36))
            row.title = option.label; row.isEnabled = !option.disabled; row.tag = index
            row.target = self; row.action = #selector(selectRow(_:))
            row.setAccessibilityLabel(option.label); row.setAccessibilityRole(.menuItem)
            row.toolTip = option.label
            row.keyPressed = { [weak self] event in self?.keyDown(with: event) }
            row.hover = { [weak self] in self?.highlight(index) }
            document.addSubview(row); rows.append(row)
        }
        scroller.documentView = document; addSubview(scroller)
        setAccessibilityChildren(rows)
        update(value: value)
        active = options.firstIndex { $0.id == value && !$0.disabled } ?? options.firstIndex { !$0.disabled }
        highlight(active)
    }

    private func makeReasoning() {
        heading = text(options.first { $0.id == value }?.label ?? value.string, size: 21, color: ModelSelectorStyle.accent,
                       rect: NSRect(x: 42, y: 15, width: 216, height: 29))
        heading?.alignment = .center
        let bolt = NSImageView(frame: NSRect(x: 17, y: 20, width: 18, height: 18))
        bolt.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        bolt.contentTintColor = .secondaryLabelColor; bolt.setAccessibilityElement(false); addSubview(bolt)
        if let reset = options.first(where: { $0.id.codeUnits.isEmpty && !$0.disabled }) {
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: reset.label)!, target: self, action: #selector(resetToDefault))
            button.isBordered = false; button.frame = NSRect(x: 261, y: 17, width: 24, height: 24)
            button.toolTip = reset.label; button.setAccessibilityLabel(reset.label); addSubview(button)
        }
        if let model {
            let button = NSButton(title: (model.options.first { $0.id == model.value.wrappedValue }?.label ?? model.value.wrappedValue.string) + " ›",
                                  target: self, action: #selector(openModels))
            button.isBordered = false; button.font = .systemFont(ofSize: 14); button.contentTintColor = .secondaryLabelColor
            button.frame = NSRect(x: 20, y: 48, width: 260, height: 24)
            button.setAccessibilityLabel(model.label); button.setAccessibilityValue(button.title); addSubview(button)
        } else {
            let subtitle = text(label, size: 12, color: .secondaryLabelColor, rect: NSRect(x: 20, y: 48, width: 260, height: 22))
            subtitle.alignment = .center
        }
        if steps.count == 1 {
            let button = NSButton(title: steps[0].label, target: self, action: #selector(selectOnlyStep))
            button.bezelStyle = .rounded; button.frame = NSRect(x: 16, y: 91, width: 268, height: 36)
            addSubview(button); return
        }
        let control = ModelReasoningSlider(value: 0, minValue: 0, maxValue: Double(max(1, steps.count - 1)), target: self, action: #selector(slide(_:)))
        control.cell = ModelReasoningSliderCell()
        control.target = self; control.action = #selector(slide(_:))
        control.leave = { [weak self] in self?.advance?(false) }
        control.cancel = { [weak self] in self?.dismiss?() }
        control.minValue = 0; control.maxValue = Double(max(1, steps.count - 1))
        control.numberOfTickMarks = steps.count; control.allowsTickMarkValuesOnly = true
        control.isContinuous = true; control.isEnabled = steps.count > 1
        control.frame = NSRect(x: 16, y: 91, width: 268, height: 36)
        control.setAccessibilityLabel(label); addSubview(control); slider = control
        update(value: value)
    }

    func refresh(value: JSONText, model: NativeModelSelector.ModelLink?) {
        // Harness bindings may capture an entire settings snapshot. Keep the model
        // callback current after an effort edit so navigation cannot restore old fields.
        self.model = model
        update(value: value)
    }

    private func update(value: JSONText) {
        if !showingModels { self.value = value }
        let value = self.value
        let title = options.first { $0.id == value }?.label ?? value.string
        heading?.stringValue = title
        if let slider {
            let index = steps.firstIndex { $0.id == value }
            slider.doubleValue = Double(index ?? 0)
            (slider.cell as? ModelReasoningSliderCell)?.hasSelection = index != nil
            slider.setAccessibilityValue(title); slider.toolTip = title; slider.needsDisplay = true
        }
        for (index, row) in rows.enumerated() {
            row.state = options[index].id == value ? .on : .off
            row.setAccessibilityValue(row.state == .on ? 1 : 0)
            row.setAccessibilitySelected(row.state == .on); row.needsDisplay = true
        }
        if !rows.isEmpty { setAccessibilitySelectedChildren(rows.filter { $0.state == .on }) }
    }

    @objc private func selectOnlyStep() {
        if let option = steps.first { commit(option.id, close: false) }
    }
    @objc private func slide(_ sender: NSSlider) {
        let index = Int(sender.doubleValue.rounded())
        guard steps.indices.contains(index) else { return }
        commit(steps[index].id, close: false)
    }
    @objc private func resetToDefault() {
        guard let option = options.first(where: { $0.id.codeUnits.isEmpty && !$0.disabled }) else { return }
        commit(option.id, close: false)
    }
    @objc private func openModels() {
        guard isActive(), let model else { return }
        showingModels = true; value = model.value.wrappedValue; options = model.options
        makeList()
        // The same native popover owns both pages; no nested transient windows.
        resize?(frame.size)
        window?.makeFirstResponder(self); focusSelection()
    }
    @objc private func selectRow(_ sender: NSButton) {
        guard options.indices.contains(sender.tag), !options[sender.tag].disabled else { return }
        commit(options[sender.tag].id, close: true)
    }
    private func commit(_ id: JSONText, close: Bool) {
        guard isActive(), options.contains(where: { $0.id == id && !$0.disabled }) else { return }
        if showingModels, let model {
            NativeSettingsChangeContext.withDiscreteChange { model.value.wrappedValue = id }
        } else if id != value { update(value: id); choose?(id) }
        if close { dismiss?() }
    }
    private func highlight(_ index: Int?) {
        active = index
        for (i, row) in rows.enumerated() { row.rowHighlighted = i == index; row.needsDisplay = true }
        if let index, rows.indices.contains(index), let window {
            window.makeFirstResponder(rows[index])
            NSAccessibility.post(element: rows[index], notification: .focusedUIElementChanged)
        }
    }
    func focusSelection() {
        highlight(active)
        if let active, rows.indices.contains(active) { rows[active].scrollToVisible(rows[active].bounds) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss?()
        case 48:
            if heading != nil && !event.modifierFlags.contains(.shift) { window?.selectNextKeyView(self) }
            else { advance?(event.modifierFlags.contains(.shift)) }
        case 36, 76, 49:
            if heading != nil && steps.count == 1 { selectOnlyStep() }
            else if let active, options.indices.contains(active) { commit(options[active].id, close: true) }
            else { dismiss?() }
        case 123, 124, 125, 126, 115, 119, 116, 121:
            let enabled = options.indices.filter { !options[$0].disabled }
            if heading != nil {
                let position = steps.firstIndex { $0.id == value }
                let delta = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
                let index = event.keyCode == 115 ? 0 : event.keyCode == 119 ? steps.count - 1 : min(steps.count - 1, max(0, position.map { $0 + delta } ?? 0))
                if steps.indices.contains(index) { commit(steps[index].id, close: false) }
            } else if !enabled.isEmpty {
                let offset = active.flatMap { enabled.firstIndex(of: $0) } ?? -1
                let delta = event.keyCode == 116 ? -8 : event.keyCode == 121 ? 8 : event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
                let next = event.keyCode == 115 ? 0 : event.keyCode == 119 ? enabled.count - 1 : min(enabled.count - 1, max(0, offset + delta))
                highlight(enabled[next]); focusSelection()
            }
        default:
            guard heading == nil, let chars = modelSelectorSearchText(event) else {
                super.keyDown(with: event); return
            }
            if event.timestamp - searchTime > 0.8 { search = "" }
            search += chars; searchTime = event.timestamp
            let cycling = search.count > 1 && Set(search.lowercased()).count == 1
            let prefix = cycling ? chars : search
            let start = max(0, prefix.count == 1 ? (active ?? -1) + 1 : active ?? 0)
            for offset in options.indices {
                let index = (start + offset) % options.count
                if !options[index].disabled, options[index].label.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                    highlight(index); focusSelection(); break
                }
            }
        }
    }
    func cancelSettingsPresentation() -> Bool {
        guard isActive(), let dismiss else { return false }
        dismiss()
        return true
    }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func accessibilityPerformCancel() -> Bool { dismiss?(); return true }
}

@MainActor private final class ModelSelectorList: NSView { override var isFlipped: Bool { true } }

@MainActor private final class ModelSelectorRow: NSButton {
    var rowHighlighted = false
    var hover: (() -> Void)?
    var keyPressed: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; focusRingType = .none; setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func keyDown(with event: NSEvent) { keyPressed?(event) }
    override func mouseEntered(with event: NSEvent) { if isEnabled { hover?() } }
    override func draw(_ dirtyRect: NSRect) {
        if rowHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 12, yRadius: 12).fill()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph]).draw(in: NSRect(x: 11, y: 9, width: bounds.width - 44, height: 20))
        if state == .on {
            NSAttributedString(string: "✓", attributes: [.font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.secondaryLabelColor]).draw(at: NSPoint(x: bounds.width - 26, y: 8))
        }
    }
}

@MainActor private final class ModelReasoningSlider: NSSlider {
    var leave: (() -> Void)?
    var cancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 && !event.modifierFlags.contains(.shift) { leave?() }
        else if event.keyCode == 53 { cancel?() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

@MainActor private final class ModelReasoningSliderCell: NSSliderCell {
    var hasSelection = true
    override var knobThickness: CGFloat { 30 }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 12, width: rect.width, height: 24)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 12, yRadius: 12).fill()
        if hasSelection {
            let progress = CGFloat((doubleValue - minValue) / max(1, maxValue - minValue))
            let fill = NSRect(x: track.minX, y: track.minY, width: 15 + progress * (track.width - 30), height: 24)
            ModelSelectorStyle.accent.setFill(); NSBezierPath(roundedRect: fill, xRadius: 12, yRadius: 12).fill()
        }
        for index in 0..<numberOfTickMarks {
            let x = track.minX + 15 + CGFloat(index) / CGFloat(max(1, numberOfTickMarks - 1)) * (track.width - 30)
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 2, y: track.midY - 2, width: 4, height: 4)).fill()
        }
    }
    override func drawKnob(_ knobRect: NSRect) {
        guard hasSelection else { return }
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 15, y: knobRect.midY - 15, width: 30, height: 30)).fill()
    }
    override func drawTickMarks() {}
}

private func modelSelectorSearchText(_ event: NSEvent) -> String? {
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
          let text = event.characters, !text.isEmpty,
          text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xf700...0xf8ff).contains($0.value) }) else { return nil }
    return text
}

@MainActor private enum ModelSelectorStyle {
    static let accent = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            NSColor(srgbRed: 166 / 255.0, green: 122 / 255.0, blue: 242 / 255.0, alpha: 1)
        } else {
            NSColor(srgbRed: 121 / 255.0, green: 73 / 255.0, blue: 184 / 255.0, alpha: 1)
        }
    }
}
