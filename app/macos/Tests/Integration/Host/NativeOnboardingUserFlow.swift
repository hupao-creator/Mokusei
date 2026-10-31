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
            try await verifyInherited("tag.settings", in: presentation, window: window)
            #expect(setup.settings.savedSettings["moku"]?["executionHarnesses"]?["codex"]?["threadSettings"]?["effort"] == .text("high"))
            try await activate("independent", in: presentation)
            try await wait("Tag independent profile did not become ready") {
                setup.settings.draft.value["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .text("tag.settings") })?["value"]?["mode"] == .text("override") && setup.canAdvance
            }
            try await activate("inherit", in: presentation)
            try await wait("Tag inheritance did not settle") { setup.canAdvance }
            try await verifyInherited("tag.settings", in: presentation, window: window)
            try await activate("next", in: presentation)
            try await wait("Report did not become ready") { setup.step == .report && setup.canAdvance }
            try await verifyInherited("report.settings", in: presentation, window: window)
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

            // Reuse this mounted workspace to certify the same role editors in
            // Settings, now without the onboarding admission/step sequence.
            try presentation.performInteraction(.openSettings)
            try await wait("Production Settings did not mount") { presentation.settingsNavigation.mounted && !presentation.scene.settingsTransitioning }
            #expect(presentation.interactionSnapshot()["settingsSections"] == .array([.text("general"), .text("moku"), .text("tag.settings"), .text("report.settings")]))
            let settings = workspace.settingsModel
            func application(_ id: String) -> JSONValue? {
                settings.savedSettings["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .text(id) })?["value"]
            }
            try presentation.performInteraction(.selectSettingsSection("report.settings"))
            try await verifyInherited("report.settings", in: presentation, window: window)
            try await activate("independent", in: presentation)
            try await control("report.settings.codex.model", operation: "select", value: .text("settings-b"), in: presentation)
            try await control("report.settings.codex.effort", operation: "select", value: .text("medium"), in: presentation)
            try await wait("Independent Report profile did not persist") {
                application("report.settings")?["mode"] == .text("override") &&
                application("report.settings")?["harnesses"]?["codex"]?["threadSettings"]?["model"] == .text("settings-b")
            }
            try presentation.performInteraction(.selectSettingsSection("tag.settings"))
            try await activate("independent", in: presentation)
            try await wait("Independent Tag profile did not persist") { application("tag.settings")?["mode"] == .text("override") }
            try await activate("inherit", in: presentation)
            try await wait("Tag inheritance did not persist") { application("tag.settings")?["mode"] == .text("inherit") }
            try await verifyInherited("tag.settings", in: presentation, window: window)
            #expect(application("tag.settings")?["independent"] != nil)
            try presentation.performInteraction(.selectSettingsSection("report.settings"))
            try await activate("inherit", in: presentation)
            try await wait("Report inheritance did not retain its profile") {
                application("report.settings")?["mode"] == .text("inherit") &&
                application("report.settings")?["independent"]?["harnesses"]?["codex"]?["threadSettings"]?["model"] == .text("settings-b")
            }
            // The retained independent profile is settings-b/medium, whereas
            // this read-only display must still be Moku's explicit/high profile.
            try await verifyInherited("report.settings", in: presentation, window: window)

            try presentation.performInteraction(.selectSettingsSection("moku"))
            try await control("moku.codex.model", operation: "select", value: .text("settings-a"), in: presentation)
            try await control("moku.codex.effort", operation: "select", value: .text("low"), in: presentation)
            try await wait("Moku effort change did not persist") {
                settings.savedSettings["moku"]?["executionHarnesses"]?["codex"]?["threadSettings"]?["effort"] == .text("low")
            }
            try presentation.performInteraction(.selectSettingsSection("tag.settings"))
            try await verifyInherited("tag.settings", in: presentation, window: window)
            try presentation.performInteraction(.selectSettingsSection("report.settings"))
            try await verifyInherited("report.settings", in: presentation, window: window)
            try await activate("independent", in: presentation)
            try await wait("Independent Report choice was not restored") {
                application("report.settings")?["mode"] == .text("override") &&
                application("report.settings")?["harnesses"]?["codex"]?["threadSettings"]?["model"] == .text("settings-b")
            }
            try presentation.performInteraction(.closeSettings)
            try await wait("Settings did not release its modal gate") { !presentation.scene.settingsOpen }
        } catch {
            try? presentation.interactionSnapshot().encodedData().write(to: directory.appendingPathComponent("onboarding-failure.json"))
            try? await capture(window, to: directory.appendingPathComponent("onboarding-failure.png"))
            window.close(); await presentation.release(); try? await workspace.stop()
            throw error
        }
        window.close(); await presentation.release(); try await workspace.stop()
    }

    private static func verifyInherited(_ settingID: String, in presentation: NativeWorkspacePresentation, window: NSWindow) async throws {
        let settings = presentation.workspace.settingsModel
        let profile = try #require(settings.savedSettings["moku"]?["executionHarnesses"]?["codex"]?["threadSettings"])
        let expected = ["model": try #require(profile["model"]), "effort": try #require(profile["effort"]),
                        "serviceTier": try #require(profile["serviceTier"])]
        func controls() -> [JSONValue] { presentation.interactionSnapshot()["settings"]?["controls"]?.arrayValue ?? [] }
        try await wait("Inherited \(settingID) fields did not show Moku's saved configuration as read-only") {
            expected.allSatisfy { field, value in
                controls().contains {
                    $0["id"] == .text(settingID + ".codex." + field) && $0["value"] == value
                        && $0["enabled"] == .bool(false) && $0["pending"] == .bool(false)
                }
            }
        }
        let before = settings.draft.value
        let model = try #require(controls().first { $0["id"] == .text(settingID + ".codex.model") })
        #expect(throws: NativeInteractionError.self) {
            try presentation.performInteraction(.settingsControl(id: settingID + ".codex.model",
                handle: try #require(model["handle"]?.stringValue), operation: "select", value: .text("settings-b")))
        }
        #expect(settings.draft.value == before)
        if let path = ProcessInfo.processInfo.environment["MOKUSEI_INHERITED_SETTINGS_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let page = presentation.onboarding.blocksWorkspace ? "onboarding" : "settings"
            // Evidence only: let mode/page transitions settle after the live
            // control assertions, then capture native glass and AppKit controls.
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(600))
            try await capture(window, to: directory.appendingPathComponent("\(page)-\(settingID).png"))
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) async throws {
        let target = try #require(try await SCShareableContent.currentProcess.windows.first {
            $0.windowID == CGWindowID(window.windowNumber)
        })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }

    private static func activate(_ suffix: String, in presentation: NativeWorkspacePresentation) async throws {
        try await control(suffix, operation: "activate", value: .null, in: presentation)
    }

    private static func control(_ suffix: String, operation: String, value: JSONValue, in presentation: NativeWorkspacePresentation) async throws {
        @MainActor func matches() -> [JSONValue] {
            let controls = presentation.interactionSnapshot()["settings"]?["controls"]?.arrayValue ?? []
            return controls.filter {
                let id = $0["id"]?.stringValue ?? ""
                return id == suffix || id.hasSuffix("." + suffix)
            }
        }
        try await wait("Onboarding control did not refresh: \(suffix)", diagnostic: {
            let setup = presentation.onboarding
            let controls = matches()
            let summary = JSONValue.array(controls.prefix(3).map { control in
                .object(["id": control["id"] ?? .null, "handle": control["handle"] ?? .null,
                         "pending": control["pending"] ?? .null, "enabled": control["enabled"] ?? .null])
            })
            let encoded = (try? summary.encodedData()) ?? Data()
            let controlDetails = String(String(decoding: encoded, as: UTF8.self).prefix(2048))
            return "page=\(presentation.interactionPage) step=\(setup.step) admitted=\(setup.admitted) mounted=\(setup.mounted) "
                + "canAdvance=\(setup.canAdvance) editorReady=\(setup.editorReady) busy=\(setup.busy) "
                + "runtimeAvailable=\(presentation.workspace.runtimeAvailable) composing=\(setup.settings.draft.composing) "
                + "invalidField=\(String((setup.settings.draft.firstInvalidField ?? "none").prefix(160))) "
                + "draftStatus=\(setup.settings.draft.status) matchCount=\(controls.count) controls=\(controlDetails)"
        }) {
            let controls = matches()
            // Model readiness can precede SwiftUI's update of the mounted control.
            return controls.count == 1 && controls[0]["pending"] == .bool(false)
                && controls[0]["enabled"] == .bool(true)
        }
        let control = try #require(matches().first, "Missing mounted onboarding control: \(suffix)")
        try #require(control["enabled"] == .bool(true), "Onboarding control is disabled: \(suffix)")
        try presentation.performInteraction(.settingsControl(id: try #require(control["id"]?.stringValue),
            handle: try #require(control["handle"]?.stringValue), operation: operation, value: value))
    }

    private static func wait(_ message: String, diagnostic: @MainActor () -> String = { "" }, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate(), Date() < deadline {
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            try await Task.sleep(for: .milliseconds(30))
        }
        let completed = predicate()
        let detail = completed ? "" : diagnostic()
        try #require(completed, Comment(rawValue: detail.isEmpty ? message : "\(message)\n\(detail)"))
    }
}
