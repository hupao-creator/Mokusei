import AppKit
import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiHarnessOpenCode

/// Mounted production OpenCode settings surface. An unsettled Console account
/// check is internal bookkeeping: it must not render a notice, a retry action or
/// reserved height, while a settled failure keeps both.
@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOpenCodeSettingsStatusTests {
    @Test func pendingAccountCheckStaysSilent() async throws {
        let pending = try presentation(pending: true)
        let controls = NativeSettingsInteractions(), context = NativeSettingsInteractionContext(visit: UUID(), section: "opencode")
        let window = try mount(state: .ready(pending), reloadValue: pending, controls: controls, context: context)
        let root = try #require(window.contentView)
        try await settle(window, root)
        let pendingHeight = root.fittingSize.height

        #expect(notices(controls, context).isEmpty)
        #expect(button("Retry", root) == nil)
        #expect(!texts(root).contains { $0.contains("account availability") || $0.contains("账户可用性") })
        window.close()

        let settledControls = NativeSettingsInteractions()
        let settledWindow = try mount(state: .ready(try presentation(pending: false)), reloadValue: nil,
            controls: settledControls, context: context)
        defer { settledWindow.close() }
        let settledRoot = try #require(settledWindow.contentView)
        try await settle(settledWindow, settledRoot)
        // The silent pending state must not reserve the notice's height.
        #expect(pendingHeight == settledRoot.fittingSize.height)
        #expect(notices(settledControls, context).isEmpty)
    }

    @Test func settledAccountFailureKeepsNoticeAndRetry() async throws {
        let controls = NativeSettingsInteractions(), context = NativeSettingsInteractionContext(visit: UUID(), section: "opencode")
        let failure = "Console account check failed"
        let window = try mount(state: .error(failure), reloadValue: nil, controls: controls, context: context)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await settle(window, root)

        let notice = try #require(notices(controls, context).first)
        #expect(notice["severity"] == .text("error"))
        #expect(notice["value"] == .text(failure))
        #expect(isEnabled(try #require(button("Retry", root))))
        #expect(root.fittingSize.height > (try await measuredHeight(state: .ready(try presentation(pending: false)))))
    }

    private func measuredHeight(state: PluginResourceState<OpenCodeSettingsPresentationData>) async throws -> CGFloat {
        let window = try mount(state: state, reloadValue: nil, controls: NativeSettingsInteractions(),
            context: NativeSettingsInteractionContext(visit: UUID(), section: "opencode"))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await settle(window, root)
        return root.fittingSize.height
    }
    private func presentation(pending: Bool) throws -> OpenCodeSettingsPresentationData {
        var raw: [JSONText: JSONValue] = [
            "cli": .object(["status": .text("ready"), "version": .text("2.0.25")]),
            "models": .array([.object([
                "provider": .text("opencode-go"), "id": .text("iceman"), "name": .text("Iceman Contributor Free"),
                "variants": .array([]), "input": .array([]), "output": .array([])
            ])]),
            "agents": .array([])
        ]
        if pending { raw["accountCheckPending"] = .bool(true) }
        return try OpenCodeSettingsPresentationData(raw: .object(raw))
    }
    private struct SettingsSurface: View {
        let resource: HarnessSettingsResource<OpenCodeSettingsPresentationData>
        let value: OpenCodeHarnessSettings
        let controls: NativeSettingsInteractions
        let context: NativeSettingsInteractionContext
        var body: some View {
            OpenCodeHarnessSettingsView(props: .init(section: .thread, settingsFormPage: true, value: value,
                resource: resource, host: nil, change: { _ in }))
                .environment(\.locale, Locale(identifier: "en-US"))
                .environment(\.nativeSettingsInteractions, controls)
                .environment(\.nativeSettingsInteractionContext, context)
                .environment(\.nativeSettingsInteractionRefresh, controls.refresh)
                .padding(24)
                .frame(width: 560)
        }
    }
    private func mount(state: PluginResourceState<OpenCodeSettingsPresentationData>,
                       reloadValue: OpenCodeSettingsPresentationData?, controls: NativeSettingsInteractions,
                       context: NativeSettingsInteractionContext) throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
        let enable = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enable) { _ = app.perform(enable, with: true, with: "AXEnhancedUserInterface") }
        let resource = HarnessSettingsResource<OpenCodeSettingsPresentationData>(state: state) { _ in
            guard let reloadValue else { throw CancellationError() }
            return reloadValue
        }
        // The reported configuration: a settled draft that only lacks account evidence.
        let value = try OpenCodeHarnessSettings(raw: .object(["threadSettings": .object([
            "provider": .text("opencode-go"), "model": .text("iceman")
        ])]))
        let host = NSHostingView(rootView: SettingsSurface(resource: resource, value: value,
            controls: controls, context: context))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func settle(_ window: NSWindow, _ root: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if root.fittingSize.height > 0 {
                try await Task.sleep(for: .milliseconds(80))
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(root.fittingSize.height > 0, "Mounted OpenCode settings never settled")
    }
    private func notices(_ controls: NativeSettingsInteractions, _ context: NativeSettingsInteractionContext) -> [JSONValue] {
        controls.snapshot(context: context).filter { $0["kind"] == .text("notice") }
    }
    private func nodes(_ root: NSView) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = [], result: [NSObject] = []
        func visit(_ object: AnyObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000,
                  let node = object as? NSObject else { return }
            result.append(node)
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [AnyObject] { values.forEach(visit) }
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if node.responds(to: legacy), let values = node.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] { values.forEach(visit) }
            if let view = node as? NSView { view.subviews.forEach(visit) }
        }
        _ = root.window?.accessibilityChildren()
        visit(root.window ?? root)
        return result
    }
    private func texts(_ root: NSView) -> [String] {
        nodes(root).flatMap { node in ["accessibilityLabel", "accessibilityValue"].compactMap { name in
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue() as? String
        } }
    }
    private func label(_ node: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityLabel")
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue() as? String
    }
    private func button(_ title: String, _ root: NSView) -> NSObject? {
        nodes(root).first { node in
            let selector = NSSelectorFromString("accessibilityRole")
            let role = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
            return role == "AXButton" && label(node) == title && node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }
    }
    private func isEnabled(_ node: NSObject) -> Bool {
        if let accessible = node as? any NSAccessibilityProtocol { return accessible.isAccessibilityEnabled() }
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        if node.responds(to: selector), let enabled = node.perform(selector, with: "AXEnabled")?.takeUnretainedValue() as? Bool { return enabled }
        // SwiftUI's AX nodes expose the modern getter through KVC without
        // declaring NSAccessibilityProtocol or the legacy attribute interface.
        guard node.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return false }
        return node.value(forKey: "accessibilityEnabled") as? Bool ?? false
    }
}
