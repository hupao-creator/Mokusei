import Foundation
import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI
import MokuseiHarnessCodex
import MokuseiApplications

/// Real workspace/draft/bindings and Swift RuntimeClient against the production
/// daemon started by tools/verification/settings. No autosave logic is simulated.
@MainActor
@Suite(.serializedNative)
struct NativeSettingsUserFlows {
    @Test func revertedDraftAdoptsLatestStreamedSettingsWithoutSaving() {
        let initial: JSONValue = .object(["moku": .object(["routingGuidance": .text("initial")])])
        let remote = replace(initial, ["moku", "routingGuidance"], .text("remote"))
        let draft = NativeSettingsDraft(settings: initial, revision: 1) { _, _ in
            Issue.record("Reverting an unsaved edit must not write stale settings")
            return .saved(settings: initial, revision: 1)
        }
        draft.runtimeAvailable = true
        draft.composing = true
        draft.change(replace(initial, ["moku", "routingGuidance"], .text("local")), textEdit: true)
        draft.receive(settings: remote, revision: 2)
        draft.change(initial, textEdit: true)
        draft.composing = false
        draft.flushText()
        #expect(draft.value == remote && draft.saved == remote && draft.revision == 2)
        draft.discardForReload()
    }

    @Test(arguments: ["", "  still typing  "])
    func olderSavePreservesLaterRoutingEditorText(text: String) async throws {
        let initial: JSONValue = .object(["moku": .object(["routingGuidance": .null, "executionHarnesses": .object([:])]), "harnesses": .object([:]), "pluginSettings": .array([])])
        var response: CheckedContinuation<NativeSettingsSaveResult, Never>?
        var submitted: JSONValue?
        var saves = 0
        let draft = NativeSettingsDraft(settings: initial, revision: 1) { value, _ in
            saves += 1
            guard saves == 1 else {
                Issue.record("An older save must not submit later text while composition is active")
                return .saved(settings: value, revision: 3)
            }
            submitted = value
            return await withCheckedContinuation { response = $0 }
        }
        defer {
            draft.discardForReload()
            response?.resume(returning: .saved(settings: submitted ?? initial, revision: 2)); response = nil
        }
        draft.runtimeAvailable = true
        draft.change(replace(initial, ["harnesses", "fixture"], .object(["model": .text("new model")])))
        try await eventually("save is in flight") { response != nil }
        draft.composing = true
        draft.change(replace(draft.value, ["moku", "routingGuidance"], .text(text)), textEdit: true)
        response?.resume(returning: .saved(settings: try #require(submitted), revision: 2)); response = nil
        try await eventually("older save completes") { draft.revision == 2 && draft.status == .pending }
        #expect(draft.value["moku"]?["routingGuidance"] == .text(text))
        #expect(draft.saved["moku"]?["routingGuidance"] == .null)
        #expect(saves == 1)
    }

    @Test func enabledEmptyRoutingEditorSurvivesUnrelatedSaveButClearingSavedGuidanceNormalizes() async throws {
        let initial: JSONValue = .object(["moku": .object(["routingGuidance": .null, "executionHarnesses": .object([:])]), "harnesses": .object([:]), "pluginSettings": .array([])])
        var submitted: [JSONValue] = []
        let draft = NativeSettingsDraft(settings: initial, revision: 1) { value, revision in
            submitted.append(value)
            return .saved(settings: value, revision: revision + 1)
        }
        defer { draft.discardForReload() }
        draft.runtimeAvailable = true
        draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("")))
        #expect(draft.value["moku"]?["routingGuidance"] == .text(""))
        #expect(draft.saved["moku"]?["routingGuidance"] == .null && submitted.isEmpty)

        draft.change(replace(draft.value, ["harnesses", "fixture"], .object(["model": .text("new model")])))
        try await eventually("unrelated settings save completes") { draft.revision == 2 && draft.status == .saved }
        #expect(draft.value["moku"]?["routingGuidance"] == .text(""))
        #expect(draft.saved["moku"]?["routingGuidance"] == .null)
        #expect(submitted.count == 1 && submitted.first?["moku"]?["routingGuidance"] == .null)

        draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("  specific guidance  ")), textEdit: true)
        draft.flushText()
        try await eventually("routing guidance save completes") { draft.revision == 3 && draft.status == .saved }
        #expect(draft.value["moku"]?["routingGuidance"] == .text("  specific guidance  "))
        #expect(draft.saved["moku"]?["routingGuidance"] == .text("specific guidance"))

        draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("")), textEdit: true)
        draft.flushText()
        try await eventually("cleared routing guidance save completes") { draft.revision == 4 && draft.status == .saved }
        #expect(draft.value["moku"]?["routingGuidance"] == .null)
        #expect(draft.saved["moku"]?["routingGuidance"] == .null)
        #expect(submitted.count == 3 && submitted.last?["moku"]?["routingGuidance"] == .null)
    }

    @Test(.requiresDisplay, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_SETTINGS_TEST_PROFILE"] != nil, "Requires the Go settings launcher and its isolated runtime profile: ./scripts/go.sh run -race ./tools/verification/settings"))
    func dailySettingsFlow() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOKUSEI_SETTINGS_TEST_PROFILE"])
        let directory = URL(fileURLWithPath: path)
        try await NativeSettingsLoadingReplay.verify(directory: directory.appendingPathComponent("settings-loading-client"))
        try await localGlassWorldFlow(directory: directory.appendingPathComponent("glass-world-client"))
        let profile = try RuntimeProfile(dataDirectory: directory)
        let prefetchURL = try #require(ProcessInfo.processInfo.environment["MOKUSEI_SETTINGS_PREFETCH_URL"].flatMap(URL.init(string:)))
        let client = RuntimeClient(storageDirectory: directory,
            connectionSource: SettingsPrefetchConnectionSource(profile: profile, port: try #require(prefetchURL.port)))
        let other = RuntimeClient(profile: profile)
        let preferences = DesktopPreferences(directory: directory)
        // Local global settings work and survive reopening without a runtime.
        try preferences.setAppearance(.dark)
        try preferences.setLocale(.english)
        let reopened = DesktopPreferences(directory: directory)
        #expect(reopened.appearance == .dark)
        #expect(reopened.locale == .english)

        let workspace = NativeWorkspaceModel(client: client, preferences: preferences,
            plugins: try NativePluginComposition(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [],
                applications: [NativeReportApplication.make(), NativeTagApplication.make()]))
        workspace.start()
        do {
            try await eventually("workspace becomes available") { workspace.runtimeAvailable && workspace.settingsModel.runtimeAvailable }
            try await NativeSettingsPrefetchReplay.verify(workspace: workspace, endpoint: prefetchURL)
            let model = workspace.settingsModel
            let draft = model.draft
            let presentation = NativeWorkspacePresentation(workspace: workspace)
            presentation.start()
            try presentation.performInteraction(.openSettings)

            #expect(presentation.settingsNavigation.section == "moku")
            #expect(presentation.interactionSnapshot()["settingsSections"]?.arrayValue?.contains(.text("archived")) == false)
            #expect(throws: NativeInteractionError.self) {
                try presentation.performInteraction(.selectSettingsSection("archived"))
            }
            presentation.settingsNavigation.section = "archived"
            #expect(presentation.interactionSnapshot()["settingsSection"] == .text("general"))
            #expect(throws: NativeInteractionError.self) {
                try presentation.performInteraction(.selectSettingsSection("plugins"))
            }
            presentation.settingsNavigation.section = "plugins"
            #expect(presentation.interactionSnapshot()["settingsSection"] == .text("general"))
            #expect(presentation.interactionSnapshot()["settingsSections"]?.arrayValue?.contains(.text("plugins")) == false)
            try presentation.performInteraction(.selectSettingsSection("moku"))
            // The app's Overview menu calls this direct presentation path,
            // independently of the semantic interaction's close wrapper.
            presentation.showOverview(focusFilter: true)
            #expect(!presentation.scene.settingsOpen)
            #expect(presentation.interactionSnapshot()["page"] == .text("overview"))
            try presentation.performInteraction(.openSettings)

            // Select a complete model/effort group through the real public binding.
            let mokuBefore = draft.saved["moku"]
            let profileB = try JSONValue(data: Data(#"{"useDefaultThreadSettings":false,"threadSettings":{"model":"settings-b","effort":"medium","serviceTier":"priority","permissionMode":"ask-for-approval"}}"#.utf8))
            NativeSettingsChangeContext.withDiscreteChange {
                model.harnessValueBinding("codex", execution: false).wrappedValue = profileB
            }
            try await eventually("default model is saved") { draft.status == .saved && draft.saved["harnesses"]?["codex"]?["threadSettings"]?["model"] == .text("settings-b") }
            #expect(draft.saved["moku"] == mokuBefore)
            #expect(try await state(client)["settings"]?["harnesses"] == draft.saved["harnesses"])
            NativeSettingsChangeContext.withDiscreteChange {
                model.harnessValueBinding("codex", execution: false).wrappedValue = .object(["threadSettings": .object([:])])
            }
            try await eventually("restore defaults") { draft.status == .saved && draft.saved["harnesses"]?["codex"]?["threadSettings"]?["model"] == nil }

            draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("save after I stop typing")), textEdit: true)
            try await eventually("idle typing autosaves without an explicit flush") {
                draft.status == .saved && draft.saved["moku"]?["routingGuidance"] == .text("save after I stop typing")
            }

            let beforeQuitFlush = draft.revision
            draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("  immediate quit edit  ")), textEdit: true)
            #expect(draft.status == .pending && draft.revision == beforeQuitFlush)
            try await draft.flushForQuit()
            #expect(draft.status == .saved && draft.revision > beforeQuitFlush)
            #expect(draft.value["moku"]?["routingGuidance"] == .text("  immediate quit edit  "))
            #expect(try await state(client)["settings"]?["moku"]?["routingGuidance"] == .text("immediate quit edit"))
            try await routingUndoFlow(model: model, presentation: presentation, preferences: preferences)

            // IME composition blocks close/save; finishing and closing flushes
            // immediately, even before the debounce timer would fire.
            let beforeTyping = draft.revision
            draft.composing = true
            draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("  中文输入 🚀  ")), textEdit: true)
            #expect(throws: NativeInteractionError.self) { try presentation.performInteraction(.closeSettings) }
            presentation.showOverview(focusFilter: true)
            #expect(presentation.scene.settingsOpen)
            do {
                try await draft.flushForQuit()
                Issue.record("Quit must report an active text composition instead of silently discarding it")
            } catch let error as RuntimeError { #expect(error.code == "SETTINGS_UNSAVED") }
            #expect(draft.revision == beforeTyping)
            #expect(try await state(client)["settingsRevision"]?.intValue == beforeTyping)
            draft.composing = false
            try presentation.performInteraction(.closeSettings)
            #expect(!presentation.scene.settingsOpen)
            try await eventually("close flushes text") { draft.status == .saved && draft.saved["moku"]?["routingGuidance"] == .text("中文输入 🚀") }
            try presentation.performInteraction(.openSettings)
            #expect(workspace.settingsModel === model)
            #expect(draft.value["moku"]?["routingGuidance"] == .text("  中文输入 🚀  "))
            #expect(draft.saved["moku"]?["routingGuidance"] == .text("中文输入 🚀"))
            draft.change(replace(draft.value, ["moku", "routingGuidance"], .text(" \n\t ")), textEdit: true)
            draft.flushText()
            try await eventually("cleared text is persisted as null") { draft.status == .saved && draft.saved["moku"]?["routingGuidance"] == .null }

            // Invalid input remains editable; it does not block an independent
            // valid field. Then correcting it allows a normal close.
            let overlong = String(repeating: "🚀", count: 6_001)
            draft.composing = true
            var edited = replace(draft.value, ["moku", "routingGuidance"], .text(overlong))
            edited = replace(edited, ["harnesses", "codex"], profileB)
            draft.change(edited, textEdit: true)
            draft.composing = false
            draft.flushText()
            try await eventually("valid sibling is saved") { draft.saved["harnesses"]?["codex"] == profileB }
            #expect(draft.value["moku"]?["routingGuidance"] == .text(overlong))
            #expect(draft.validationError("routingGuidance", locale: .english) != nil)
            #expect(throws: NativeInteractionError.self) { try presentation.performInteraction(.closeSettings) }
            let beforeInvalidOverview = presentation.settingsNavigation.focusRequest
            presentation.showOverview(focusFilter: true)
            #expect(presentation.scene.settingsOpen && presentation.settingsNavigation.section == "moku")
            #expect(presentation.settingsNavigation.focusRequest > beforeInvalidOverview)
            do {
                try await draft.flushForQuit()
                Issue.record("Quit must explicitly reject invalid routing guidance")
            } catch let error as RuntimeError { #expect(error.code == "SETTINGS_UNSAVED") }
            #expect(try await state(client)["settings"]?["moku"]?["routingGuidance"] == .null)
            draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("corrected")), textEdit: true)
            presentation.showOverview(focusFilter: true)
            #expect(!presentation.scene.settingsOpen)
            try await eventually("corrected input saves") { draft.status == .saved && draft.saved["moku"]?["routingGuidance"] == .text("corrected") }

            // A rejected model selection preserves the draft. Correct through
            // the same production binding; a failed save must not freeze it.
            let invalid = replace(profileB, ["threadSettings", "effort"], .text("high"))
            NativeSettingsChangeContext.withDiscreteChange { model.harnessValueBinding("codex", execution: true).wrappedValue = invalid }
            do {
                try await draft.flushForQuit()
                Issue.record("Quit must report the native settings rejection and retain its draft")
            } catch let error as RuntimeError { #expect(error.code == "SETTINGS_UNSAVED") }
            #expect(draft.status == .error)
            #expect(draft.value["moku"]?["executionHarnesses"]?["codex"] == invalid)
            NativeSettingsChangeContext.withDiscreteChange { model.harnessValueBinding("codex", execution: true).wrappedValue = profileB }
            try await eventually("corrected model saves after failure") { draft.status == .saved }
            #expect(draft.error == nil)
            #expect(draft.saved["moku"]?["executionHarnesses"]?["codex"]?["threadSettings"]?["effort"] == .text("medium"))

            // Another window changes a separate field while this one is typing.
            // Real revision conflict and real NativeSettingsDraft.retry rebase.
            try await other.start()
            draft.composing = true
            draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("my local input")), textEdit: true)
            let remote = try await state(other)
            let remoteSettings = replace(try #require(remote["settings"]), ["harnesses", "codex"], .object(["threadSettings": .object([:])]))
            let remoteSave = try await other.invoke("app:update-settings", args: [.object([
                "settings": remoteSettings, "expectedSettingsRevision": try #require(remote["settingsRevision"])
            ])])
            let remoteRevision = try #require(remoteSave["settingsRevision"]?.intValue)
            try await eventually("remote update reaches workspace") { workspace.catalog.settingsRevision == remoteRevision }
            draft.composing = false
            draft.flushText()
            try await eventually("conflict preserves input") { draft.conflicted }
            #expect(draft.value["moku"]?["routingGuidance"] == .text("my local input"))
            draft.retry()
            try await eventually("retry merges both windows") { draft.status == .saved && !draft.conflicted }
            let final = try await state(client)
            #expect(final["settings"]?["moku"]?["routingGuidance"] == .text("my local input"))
            #expect(final["settings"]?["harnesses"]?["codex"]?["threadSettings"]?["model"] == nil)
            // Wait for actual native events in the shared local sink, not a mock reporter.
            try await eventually("native diagnostics reach runtime") {
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("runtime/debug-logs"), includingPropertiesForKeys: nil) else { return false }
                return files.filter { $0.pathExtension == "jsonl" }.contains { file in
                    guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return false }
                    return contents.split(separator: "\n").contains { line in
                        guard let event = try? JSONValue(data: Data(line.utf8)) else { return false }
                        return event["evt"] == .text("settings.client.conflict") && event["outcome"] == .text("keep") && event["flowId"] == .text(draft.diagnostics.flowID)
                    }
                }
            }
            await presentation.release()
            await other.close()
            try await workspace.stop()
        } catch {
            await other.close()
            try? await workspace.stop()
            throw error
        }
    }

    /// The real page binds its production NSTextView to the Runtime-backed
    /// draft. Waiting for autosave must not shift the editor's native Undo ranges.
    private func routingUndoFlow(model: NativeSettingsModel, presentation: NativeWorkspacePresentation,
                                 preferences: DesktopPreferences) async throws {
        let draft = model.draft
        draft.change(replace(draft.value, ["moku", "routingGuidance"], .text("ABC")), textEdit: true)
        try await draft.flushForQuit()
        let window = SwiftUIReplay.window(NativeSettingsPage(model: model,
            navigation: presentation.settingsNavigation, preferences: preferences,
            harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], harnessSettings: { _ in AnyView(EmptyView()) },
            onSetAppearance: { try preferences.setAppearance($0) },
            onSetLocale: { try preferences.setLocale($0) },
            onClose: { _ in presentation.scene.closeSettings() }))
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        func routingEditor(in view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView, editor.isEditable,
               editor.accessibilityLabel() == "Enter the rules Moku should follow when selecting models" { return editor }
            return view.subviews.lazy.compactMap { routingEditor(in: $0) }.first
        }
        try await SwiftUIReplay.wait { routingEditor(in: root)?.string == "ABC" }
        let editor = try #require(routingEditor(in: root))
        window.makeFirstResponder(editor)
        let undo = try #require(editor.undoManager)
        undo.removeAllActions()
        editor.breakUndoCoalescing()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText(" X ", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        #expect(editor.string == " X ABC")
        try await eventually("native routing edit autosaves") {
            draft.status == .saved && draft.saved["moku"]?["routingGuidance"] == .text("X ABC")
        }
        try await SwiftUIReplay.wait { editor.string == " X ABC" }
        #expect(draft.value["moku"]?["routingGuidance"] == .text(" X ABC"))
        try #require(undo.canUndo)
        undo.undo()
        try await SwiftUIReplay.wait { editor.string == "ABC" && draft.value["moku"]?["routingGuidance"] == .text("ABC") }
        try await draft.flushForQuit()
        #expect(draft.saved["moku"]?["routingGuidance"] == .text("ABC"))
    }

    /// Mount the production General page without starting the Runtime. The
    /// interaction registry invokes the toggle's real binding and error path.
    private func localGlassWorldFlow(directory: URL) async throws {
        let file = directory.appendingPathComponent("desktop-preferences.json")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(DesktopPreferences(directory: directory).glassWorld)
        try Data(#"{"preferences":{"locale":"en-US","appearance":"dark"}}"#.utf8).write(to: file)
        let preferences = DesktopPreferences(directory: directory)
        #expect(preferences.glassWorld)
        #expect(preferences.readError == nil)
        #expect(preferences.appearance == .dark)
        #expect(preferences.locale == .english)

        func saved() throws -> JSONValue { try JSONValue(data: Data(contentsOf: file)) }
        for value in [true, false] {
            try preferences.setGlassWorld(value)
            #expect(DesktopPreferences(directory: directory).glassWorld == value)
            #expect(try saved()["preferences"]?["glassWorld"] == .bool(value))
            try preferences.setAppearance(.light)
            #expect(DesktopPreferences(directory: directory).glassWorld == value)
            try preferences.setLocale(.chinese)
            #expect(DesktopPreferences(directory: directory).glassWorld == value)
            try preferences.selectThread("glass-world-selection")
            #expect(DesktopPreferences(directory: directory).glassWorld == value)
            #expect(try saved()["preferences"]?["glassWorld"] == .bool(value))
        }
        try preferences.selectThread(nil)
        try preferences.setGlassWorld(true)
        try preferences.setLocale(.english)
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let workspace = NativeWorkspaceModel(client: client, preferences: preferences,
            plugins: try NativePluginComposition(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
        // Local preferences remain available in a previously loaded Overview
        // after disconnect. The initial connection screen has no Settings entry.
        let moku = try HarnessThread(id: "moku", harnessID: "codex", revision: 1, sessionState: .null,
            observation: .init(), cwd: JSONText(directory.path), settings: .object([:]),
            createdAt: 0, updatedAt: 1, title: "Moku", tags: [], moku: true, transcript: .array([]))
        let snapshot: JSONValue = .object(["revision": .integer(1), "settingsRevision": .integer(0),
            "defaultCwd": .text(directory.path), "settings": .object([:]), "threads": .array([moku.json]),
            "executions": .array([]), "applicationThreads": .array([])])
        await workspace.installPrepared(snapshot, event: .snapshot(snapshot, authority: UUID()))
        let presentation = NativeWorkspacePresentation(workspace: workspace)
        presentation.start()
        try presentation.performInteraction(.openSettings)
        try presentation.performInteraction(.selectSettingsSection("general"))
        let window = SwiftUIReplay.window(NativeSettingsPage(model: workspace.settingsModel,
            navigation: presentation.settingsNavigation, preferences: preferences, harnesses: [],
            harnessSettings: { _ in AnyView(EmptyView()) },
            onSetAppearance: { try preferences.setAppearance($0) },
            onSetLocale: { try preferences.setLocale($0) }, onClose: { _ in }))
        defer { window.orderOut(nil); window.contentView = nil }
        func controls() -> [JSONValue] { presentation.interactionSnapshot()["settings"]?["controls"]?.arrayValue ?? [] }
        func toggle() -> JSONValue? { controls().first { $0["id"] == .text("general.glassWorld") } }
        func operate(_ value: Bool) async throws {
            try await SwiftUIReplay.wait { toggle()?["pending"] == .bool(false) }
            let handle = try #require(toggle()?["handle"]?.stringValue)
            try presentation.performInteraction(.settingsControl(id: "general.glassWorld", handle: handle, operation: "set", value: .bool(value)))
            try await SwiftUIReplay.wait { toggle()?["pending"] == .bool(false) }
        }
        try await SwiftUIReplay.wait { toggle()?["value"] == .bool(true) }
        #expect(presentation.interactionSnapshot()["runtimeAvailable"] == .bool(false))
        #expect(toggle()?["label"] == .text("glass world"))
        #expect(toggle()?["enabled"] == .bool(true))
        for value in [false, true, false] {
            try await operate(value)
            #expect(toggle()?["value"] == .bool(value))
            #expect(presentation.interactionSnapshot()["settings"]?["glassWorld"] == .bool(value))
            #expect(try saved()["preferences"]?["glassWorld"] == .bool(value))
            #expect(DesktopPreferences(directory: directory).glassWorld == value)
        }
        try preferences.setLocale(.chinese)
        try await SwiftUIReplay.wait { controls().first { $0["id"] == .text("general.locale") }?["label"] == .text("界面语言") }
        #expect(toggle()?["label"] == .text("glass world"))
        if let path = ProcessInfo.processInfo.environment["MOKUSEI_GLASS_WORLD_ARTIFACTS"], let view = window.contentView {
            // The binding and registry settle before the switch's visual spring.
            // Let that finish so the artifact shows the saved off state.
            try await Task.sleep(for: .milliseconds(350))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(!preferences.glassWorld)
            #expect(toggle()?["value"] == .bool(false))
            #expect(presentation.interactionSnapshot()["settings"]?["glassWorld"] == .bool(false))
            // Layer-backed SwiftUI controls can leave cacheDisplay showing an
            // earlier animation frame. Capture this process's actual window.
            let content = try await SCShareableContent.currentProcess
            let target = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(target.frame.width * window.backingScaleFactor)
            configuration.height = Int(target.frame.height * window.backingScaleFactor)
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            configuration.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let artifacts = URL(fileURLWithPath: path)
            try manager.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: artifacts.appendingPathComponent("settings-glass-world-off.png"))
        }

        // A directory at the destination forces atomic rename to fail even for
        // privileged runners; retain the original bytes for the reopen oracle.
        let retained = directory.appendingPathComponent("retained-preferences.json")
        try manager.moveItem(at: file, to: retained)
        try manager.createDirectory(at: file, withIntermediateDirectories: false)
        defer {
            if manager.fileExists(atPath: retained.path) {
                try? manager.removeItem(at: file)
                try? manager.moveItem(at: retained, to: file)
            }
        }
        #expect(throws: (any Error).self) { try preferences.setGlassWorld(true) }
        #expect(!preferences.glassWorld)
        try await operate(true)
        try await SwiftUIReplay.wait { controls().contains { $0["kind"] == .text("notice") && $0["severity"] == .text("error") } }
        #expect(toggle()?["value"] == .bool(false))
        #expect(presentation.interactionSnapshot()["settings"]?["glassWorld"] == .bool(false))
        #expect(try JSONValue(data: Data(contentsOf: retained))["preferences"]?["glassWorld"] == .bool(false))
        try manager.removeItem(at: file)
        try manager.moveItem(at: retained, to: file)
        #expect(!DesktopPreferences(directory: directory).glassWorld)
        try await operate(true)
        try await SwiftUIReplay.wait { !controls().contains { $0["severity"] == .text("error") } }
        #expect(DesktopPreferences(directory: directory).glassWorld)
        await presentation.release()
        await client.close()
    }

    private func state(_ client: RuntimeClient) async throws -> JSONValue { try await client.invoke("state:load") }

    private func eventually(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw FlowFailure(description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Construct user edits only. Persistence, normalization, merge and retry
    /// remain production behavior and are never reimplemented here.
    private func replace(_ value: JSONValue, _ path: [String], _ next: JSONValue) -> JSONValue {
        guard let key = path.first else { return next }
        var object = value.objectValue ?? [:]
        object[JSONText(key)] = replace(value[key] ?? .object([:]), Array(path.dropFirst()), next)
        return .object(object)
    }
    private struct FlowFailure: Error { let description: String; init(_ description: String) { self.description = description } }
}
