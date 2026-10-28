import AppKit
import SwiftUI
import Testing
import MokuseiCore
@testable import MokuseiPluginUI
import MokuseiTestSupport

/// Production NSViews without a window, app activation or a visible popover.
/// WindowServer lifecycle remains covered by the separate hosted native replay.
@MainActor
@Suite(.serializedNative, .serialized)
struct NativeModelSelectorHeadlessTests {
    @Test func nativeSliderAndResetKeepOpaqueValues() throws {
        let options: [NativeSettingsOption] = [
            .init(id: "", label: "Default"), .init(id: "native/low", label: "Low"),
            .init(id: "blocked", label: "Unavailable", disabled: true),
            .init(id: "native/high", label: "High"), .init(id: "opaque/max", label: "Max")
        ]
        let content = ModelSelectorContent(value: "native/high", options: options,
                                           presentation: .reasoning, model: nil, label: "Reasoning")
        try capture(content, name: "reasoning")
        var chosen: [JSONText] = []
        content.choose = { chosen.append($0) }
        let slider = try #require(content.subviews.compactMap { $0 as? NSSlider }.first)
        #expect(slider.numberOfTickMarks == 3)
        #expect(slider.doubleValue == 1)
        slider.doubleValue = 2
        slider.sendAction(slider.action, to: slider.target)
        #expect(chosen == ["opaque/max"])
        let reset = try #require(content.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Default" })
        reset.performClick(nil)
        #expect(chosen == ["opaque/max", ""])
        #expect(slider.accessibilityValue() as? String == "Default")
        try key(124, in: content)
        #expect(chosen.last == "native/low")
        #expect(!chosen.contains("blocked"))
        content.isActive = { false }
        slider.doubleValue = 2
        slider.sendAction(slider.action, to: slider.target)
        #expect(chosen.last == "native/low") // Retired popup callbacks cannot write.
        #expect(content.window == nil)
    }

    @Test func listKeyboardAndSingleChoiceUseProductionActions() throws {
        let decomposed = JSONText("cafe\u{301}")
        let content = ModelSelectorContent(value: "first", options: [
            .init(id: "first", label: "First"), .init(id: "blocked", label: "Blocked", disabled: true),
            .init(id: decomposed, label: "Decomposed")
        ], presentation: .models, model: nil, label: "Model")
        try capture(content, name: "models")
        let scroll = try #require(content.subviews.compactMap { $0 as? NativeStyledScrollView }.first)
        scroll.tile()
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.verticalScroller?.controlSize == .mini)
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
        var selected: JSONText?
        var dismissed = false
        content.choose = { selected = $0 }; content.dismiss = { dismissed = true }
        try key(125, in: content); try key(36, in: content)
        #expect(selected == decomposed)
        #expect(dismissed)
        selected = nil; dismissed = false
        try key(115, in: content); try key(53, in: content)
        #expect(selected == nil)
        #expect(dismissed)
        let single = ModelSelectorContent(value: "", options: [
            .init(id: "", label: "Choose", disabled: true), .init(id: "fixed", label: "Fixed")
        ], presentation: .reasoning, model: nil, label: "Reasoning")
        single.choose = { selected = $0 }
        let button = try #require(single.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Fixed" })
        button.performClick(nil)
        #expect(selected == "fixed")
        #expect(content.window == nil && single.window == nil)
    }

    @Test func modelNavigationUsesRefreshedProfileBinding() throws {
        var effort: JSONText = "high"
        var model: JSONText = "first"
        let options: [NativeSettingsOption] = [.init(id: "first", label: "First"), .init(id: "next", label: "Next")]
        func link(capturing snapshot: JSONText) -> NativeModelSelector.ModelLink {
            .init(value: .init(get: { model }, set: { model = $0; effort = snapshot }), options: options, label: "Model")
        }
        let content = ModelSelectorContent(value: effort, options: [
            .init(id: "low", label: "Low"), .init(id: "high", label: "High")
        ], presentation: .reasoning, model: link(capturing: effort), label: "Reasoning")
        content.choose = { effort = $0 }
        try key(123, in: content)
        #expect(effort == "low")
        content.refresh(value: effort, model: link(capturing: effort))
        let button = try #require(content.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Model" })
        button.performClick(nil)
        try key(119, in: content); try key(36, in: content)
        #expect(model == "next")
        #expect(effort == "low")
        #expect(content.window == nil)
    }

    private func capture(_ content: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_MODEL_SELECTOR_HEADLESS_ARTIFACTS"] else { return }
        #expect(content.window == nil)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { content.appearance = nil }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            content.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + "-" + suffix + ".png"))
        }
    }

    private func key(_ code: UInt16, in content: NSView) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        content.keyDown(with: event)
    }
}
