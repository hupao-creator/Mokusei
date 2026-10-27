import SwiftUI
import AppKit

/// Supplies native tab semantics while the visible SwiftUI button owns input and focus.
/// Keep the original button's accessibility label and selected trait after
/// `accessibilityRepresentation` so SwiftUI's keyboard-focus proxy retains them.
@MainActor struct SettingsTabAccessibilityRepresentation: NSViewRepresentable {
    let title: String
    let selected: Bool
    let focused: Bool
    let activate: () -> Void

    func makeNSView(context: Context) -> SettingsTabAccessibilityView {
        SettingsTabAccessibilityView(frame: .zero)
    }

    func updateNSView(_ view: SettingsTabAccessibilityView, context: Context) {
        let selectionChanged = view.selected != selected
        view.title = title
        view.selected = selected
        view.focused = focused
        view.enabled = context.environment.isEnabled
        view.activate = activate
        if selectionChanged {
            NSAccessibility.post(element: view, notification: .valueChanged)
        }
    }

    static func dismantleNSView(_ view: SettingsTabAccessibilityView, coordinator: ()) {
        view.activate = nil
    }
}

@MainActor final class SettingsTabAccessibilityView: NSView {
    var title = ""
    var selected = false
    var focused = false
    var enabled = true
    var activate: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tabButtonSubrole }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { NSNumber(value: selected) }
    override func isAccessibilitySelected() -> Bool { selected }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override func isAccessibilityFocused() -> Bool { focused }

    override func setAccessibilityFocused(_ value: Bool) {
        // Inactive tabs are outside the key-view loop. Activation must select the
        // tab before its original SwiftUI button can receive keyboard focus.
        if value, enabled { activate?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled, let activate else { return false }
        activate()
        return true
    }
}



/// A tab's semantic state. Its visible button retains all pointer and keyboard input.
@MainActor struct SettingsAccessibilityTab: Identifiable {
    let id: String
    let title: String
    let selected: Bool
    let focused: Bool
    let activate: () -> Void
}

@MainActor extension View {
    /// Measure the visible button without recreating its SwiftUI layout.
    func settingsTabAccessibilityAnchor(id: String) -> some View {
        anchorPreference(key: SettingsTabBoundsPreference.self, value: .bounds) { [id: $0] }
    }

    /// Apply to the tab stack, excluding its heading and Back button.
    func settingsTabListAccessibility(title: String, horizontal: Bool, tabs: [SettingsAccessibilityTab]) -> some View {
        modifier(SettingsTabListAccessibilityModifier(title: title, horizontal: horizontal, tabs: tabs))
    }
}

private struct SettingsTabBoundsPreference: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SettingsTabFramesPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor private struct SettingsTabListAccessibilityModifier: ViewModifier {
    let title: String
    let horizontal: Bool
    let tabs: [SettingsAccessibilityTab]
    @State private var frames: [String: CGRect] = [:]

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(SettingsTabBoundsPreference.self) { anchors in
            GeometryReader { geometry in
                Color.clear.preference(key: SettingsTabFramesPreference.self, value: anchors.mapValues { geometry[$0] })
            }
        }.onPreferenceChange(SettingsTabFramesPreference.self) { frames = $0 }
            .accessibilityRepresentation {
                SettingsTabGroupAccessibilityRepresentation(title: title, horizontal: horizontal, tabs: tabs, frames: frames)
            }
    }
}

@MainActor private struct SettingsTabGroupAccessibilityRepresentation: NSViewRepresentable {
    let title: String
    let horizontal: Bool
    let tabs: [SettingsAccessibilityTab]
    let frames: [String: CGRect]

    func makeNSView(context: Context) -> SettingsTabGroupAccessibilityView { SettingsTabGroupAccessibilityView(frame: .zero) }
    func updateNSView(_ view: SettingsTabGroupAccessibilityView, context: Context) {
        view.update(title: title, horizontal: horizontal, tabs: tabs, frames: frames, enabled: context.environment.isEnabled)
    }
    static func dismantleNSView(_ view: SettingsTabGroupAccessibilityView, coordinator: ()) {
        for tab in view.tabs { tab.activate = nil }
        view.tabs = []
    }
}

@MainActor private final class SettingsTabGroupAccessibilityView: NSView {
    var title = ""
    var horizontal = false
    var tabs: [SettingsTabGroupAccessibilityLeaf] = []
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { horizontal ? .horizontal : .vertical }
    override func accessibilityChildren() -> [Any]? { tabs }
    override func accessibilityTabs() -> [Any]? { tabs }
    override func accessibilitySelectedChildren() -> [Any]? { tabs.filter(\.selected) }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let result: NSView = MainActor.assumeIsolated { tabs.first { $0.accessibilityFrame().contains(point) } ?? self }
        return result
    }

    func update(title: String, horizontal: Bool, tabs descriptions: [SettingsAccessibilityTab], frames: [String: CGRect], enabled: Bool) {
        let oldSelection = tabs.filter(\.selected).map(\.id)
        let structureChanged = tabs.map(\.id) != descriptions.map(\.id) || self.horizontal != horizontal
        let old = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        self.title = title; self.horizontal = horizontal
        tabs = descriptions.compactMap { description in
            guard let frame = frames[description.id], frame.width > 0, frame.height > 0 else { return nil }
            let tab = old[description.id] ?? SettingsTabGroupAccessibilityLeaf()
            let selectionChanged = tab.selected != description.selected
            tab.id = description.id; tab.title = description.title; tab.selected = description.selected
            tab.focused = description.focused; tab.enabled = enabled; tab.activate = description.activate
            tab.parent = self; tab.localFrame = frame
            if selectionChanged { NSAccessibility.post(element: tab, notification: .valueChanged) }
            return tab
        }
        for tab in old.values where !tabs.contains(where: { $0 === tab }) { tab.activate = nil; tab.parent = nil }
        if structureChanged { NSAccessibility.post(element: self, notification: .layoutChanged) }
        if oldSelection != tabs.filter(\.selected).map(\.id) {
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }
}

@MainActor private final class SettingsTabGroupAccessibilityLeaf: NSView {
    var id = ""
    var title = ""
    var selected = false
    var focused = false
    var enabled = true
    var activate: (() -> Void)?
    weak var parent: SettingsTabGroupAccessibilityView?
    var localFrame = CGRect.zero
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityParent() -> Any? { parent }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tabButtonSubrole }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { NSNumber(value: selected) }
    override func isAccessibilitySelected() -> Bool { selected }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override func isAccessibilityFocused() -> Bool { focused }
    override func accessibilityFrame() -> NSRect {
        guard let parent else { return .zero }
        // A representation has no real window. Translate the measured SwiftUI
        // rectangle from its top-left origin into the group's screen-space frame.
        let frame = parent.accessibilityFrame()
        return CGRect(x: frame.minX + localFrame.minX, y: frame.maxY - localFrame.maxY, width: localFrame.width, height: localFrame.height)
    }
    override func setAccessibilityFocused(_ value: Bool) { if value, enabled { activate?() } }
    override func accessibilityPerformPress() -> Bool { guard enabled, let activate else { return false }; activate(); return true }
}
