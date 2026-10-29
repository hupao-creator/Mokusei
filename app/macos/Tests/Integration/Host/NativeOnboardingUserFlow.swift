import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiApplications
@testable import MokuseiUI

/// Mounted production onboarding, real native resources and Runtime settings.
/// Invoked by the existing Go-backed settings flow, with its isolated CLI peer.
@MainActor enum NativeOnboardingUserFlow {
    static func verify(profile: RuntimeProfile, port: Int, directory: URL) async throws {
        let client = RuntimeClient(storageDirectory: directory, connectionSource: SettingsPrefetchConnectionSource(profile: profile, port: port))
        let preferences = DesktopPreferences(directory: directory)
        try preferences.setOnboardingCompleted(false)
        let workspace = NativeWorkspaceModel(client: client, preferences: preferences,
            plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: NativeApplicationModules.make()))
        let presentation = NativeWorkspacePresentation(workspace: workspace)
        let window = NSWindow(contentRect: .init(x: 80, y: 100, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NativeWorkspaceView(model: workspace, presentation: presentation)
            .modifier(NativeWorkspaceWindowSurface()))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspace.start()
        presentation.start()
        presentation.setScenePhase(.active)
        do {
            let setup = presentation.onboarding
            try await wait("Real Agent discovery did not make onboarding ready") { setup.admitted && setup.mounted && setup.canAdvance }
            #expect(setup.installed.map(\.descriptor.id) == ["codex"])
            #expect(SwiftUIReplay.editor(in: try #require(window.contentView)) == nil)
            #expect(presentation.interactionPage == "onboarding")
            #expect(!presentation.canOpenSettings)
            try await activate("next", in: presentation)
            try await wait("Moku native execution profile did not become ready") { setup.step == .moku && setup.canAdvance }
            #expect(setup.selectedHost?.descriptor.id == "codex")
            #expect(setup.targets == ["codex"])
            let savedBeforeIncompleteEdit = setup.settings.draft.saved
            try await control("moku.codex.model", operation: "select", value: .text("settings-explicit"), in: presentation)
            try await wait("Incomplete native model choices did not block Continue") { !setup.editorReady && !setup.canAdvance }
            try await setup.advance()
            #expect(setup.step == .moku && setup.settings.draft.saved == savedBeforeIncompleteEdit)
            try await control("moku.codex.effort", operation: "select", value: .text("high"), in: presentation)
            try await wait("Completed Moku profile did not become ready") { setup.canAdvance }
            try await activate("next", in: presentation)
            try await wait("Tag did not inherit the saved Moku profile") { setup.step == .tag && setup.canAdvance }
            #expect(setup.settings.savedSettings["moku"]?["executionHarnesses"]?["codex"]?["threadSettings"]?["effort"] == .text("high"))
            try await activate("independent", in: presentation)
            try await wait("Tag independent profile did not become ready") {
                setup.settings.draft.value["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .text("tag.settings") })?["value"]?["mode"] == .text("override") && setup.canAdvance
            }
            try await activate("inherit", in: presentation)
            try await wait("Tag inheritance did not settle") { setup.canAdvance }
            try await activate("next", in: presentation)
            try await wait("Report did not become ready") { setup.step == .report && setup.canAdvance }
            try await activate("back", in: presentation)
            try await wait("Back did not preserve Tag configuration") { setup.step == .tag && setup.canAdvance }
            let tag = setup.settings.draft.value["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .text("tag.settings") })?["value"]
            #expect(tag?["mode"] == .text("inherit") && tag?["independent"] != nil)
            try await activate("next", in: presentation)
            try await wait("Report did not reopen") { setup.step == .report && setup.canAdvance }

            // A failed completion marker cannot retire the panel after Runtime
            // settings have saved. Repair the owned test path and retry in place.
            let marker = directory.appendingPathComponent("desktop-preferences.json")
            try FileManager.default.removeItem(at: marker)
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
            try await activate("next", in: presentation)
            try await wait("Completion marker failure was not surfaced") { setup.error != nil && !setup.busy }
            #expect(setup.step == .report && setup.blocksWorkspace && !preferences.onboardingCompleted)
            #expect(SwiftUIReplay.editor(in: try #require(window.contentView)) == nil)
            try FileManager.default.removeItem(at: marker)
            try await activate("next", in: presentation)
            try await wait("Onboarding did not hand off to the real Dock") { !setup.blocksWorkspace && presentation.scene.inputOpen }
            try await wait("The real Moku editor did not mount") { SwiftUIReplay.editor(in: window.contentView!) != nil }
            #expect(preferences.onboardingCompleted)
            #expect(DesktopPreferences(directory: directory).onboardingCompleted)
            #expect(setup.settings.draft.value == setup.settings.draft.saved)
            #expect(presentation.interactionPage == "overview")
        } catch {
            try? presentation.interactionSnapshot().encodedData().write(to: directory.appendingPathComponent("onboarding-failure.json"))
            if let target = try? await SCShareableContent.currentProcess.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(target.frame.width * window.backingScaleFactor)
                configuration.height = Int(target.frame.height * window.backingScaleFactor)
                configuration.ignoreShadowsSingleWindow = true
                configuration.showsCursor = false
                configuration.colorSpaceName = CGColorSpace.sRGB
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration),
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appendingPathComponent("onboarding-failure.png"))
                }
            }
            window.close(); await presentation.release(); try? await workspace.stop()
            throw error
        }
        window.close(); await presentation.release(); try await workspace.stop()
    }

    private static func activate(_ suffix: String, in presentation: NativeWorkspacePresentation) async throws {
        try await control(suffix, operation: "activate", value: .null, in: presentation)
    }

    private static func control(_ suffix: String, operation: String, value: JSONValue, in presentation: NativeWorkspacePresentation) async throws {
        func matches() -> [JSONValue] {
            let controls = presentation.interactionSnapshot()["settings"]?["controls"]?.arrayValue ?? []
            return controls.filter {
                let id = $0["id"]?.stringValue ?? ""
                return id == suffix || id.hasSuffix("." + suffix)
            }
        }
        try await wait("Onboarding control did not refresh: \(suffix)") {
            let controls = matches()
            return controls.count == 1 && controls[0]["pending"] == .bool(false)
        }
        let control = try #require(matches().first, "Missing mounted onboarding control: \(suffix)")
        try #require(control["enabled"] == .bool(true), "Onboarding control is disabled: \(suffix)")
        try presentation.performInteraction(.settingsControl(id: try #require(control["id"]?.stringValue),
            handle: try #require(control["handle"]?.stringValue), operation: operation, value: value))
    }

    private static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate(), Date() < deadline {
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(predicate(), Comment(rawValue: message))
    }
}
