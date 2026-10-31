import AppKit
import CoreMedia
import CoreVideo
import Observation
import ScreenCaptureKit
import SwiftUI
import Testing
import MokuseiCore
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class SearchInputFixture {
    var text = ""
    var request = 1
    var exits = 0
}
private struct SearchInputReplay: View {
    let fixture: SearchInputFixture
    var body: some View {
        OverviewThreadSearchField(text: fixture.text, placeholder: "搜索会话", focusRequest: fixture.request,
            onChange: { fixture.text = $0 }, onExit: { fixture.exits += 1 })
            .padding(20)
    }
}

@MainActor @Suite(.serializedNative, .serialized)
struct SwiftUIOverviewInteractionTests {
    private func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    @Test(.requiresDisplay) func searchEditsChineseAndRepeatedFocusSelectsCurrentText() async throws {
        let fixture = SearchInputFixture()
        let window = SwiftUIReplay.window(SearchInputReplay(fixture: fixture), width: 500, height: 100)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        // AppKit can retain a negative clip origin after the document grows
        // from its initial, shorter height during the search morph.
        let scroll = try #require(editor.enclosingScrollView)
        editor.setFrameSize(NSSize(width: editor.frame.width, height: 25))
        let constrained = scroll.contentView.constrainBoundsRect(scroll.contentView.bounds)
        #expect(constrained.origin.y == 0)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: -15))
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.y == 0)
        editor.setMarkedText("ni", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -15))
        #expect(scroll.contentView.bounds.origin.y == 0 && editor.hasMarkedText())
        editor.insertText("你好世界", replacementRange: .init(location: NSNotFound, length: 0))
        try await SwiftUIReplay.wait { fixture.text == "你好世界" }
        #expect(!editor.hasMarkedText())
        fixture.request += 1
        try await SwiftUIReplay.wait { editor.selectedRange() == NSRange(location: 0, length: 4) }
        editor.insertText("SwiftUI", replacementRange: .init(location: NSNotFound, length: 0))
        try await SwiftUIReplay.wait { fixture.text == "SwiftUI" }
        #expect(fixture.exits == 0)
        let longQuery = String(repeating: "long query ", count: 30)
        editor.insertText(longQuery, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await SwiftUIReplay.wait { fixture.text == longQuery }
        editor.scrollRangeToVisible(NSRange(location: longQuery.utf16.count, length: 0))
        let horizontalOrigin = scroll.contentView.bounds.origin.x
        #expect(horizontalOrigin > 0)
        scroll.contentView.scroll(to: NSPoint(x: horizontalOrigin, y: -15))
        #expect(scroll.contentView.bounds.origin.y == 0)
        #expect(scroll.contentView.bounds.origin.x == horizontalOrigin)
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.x == horizontalOrigin)
        #expect(scroll.contentView.bounds.origin.y == 0)
    }

    @Test(.requiresDisplay) func focusedCardPausesCameraUntilFocusLeaves() async throws {
        let state = NativeOverviewCanvasState()
        let input = SearchInputFixture()
        let items = (0..<20).map { NativeOverviewItem(id: "focus-\($0)", carouselEligible: $0 == 0) }
        let window = SwiftUIReplay.window(NativeOverviewCanvas(items: items, sceneKey: "focus", state: state) { item in
            if item.id == "focus-0" {
                TextField("Card input", text: Binding(get: { input.text }, set: { input.text = $0 }))
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text(item.id).frame(maxWidth: .infinity, maxHeight: .infinity) }
        })
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { !state.isLayingOut && state.camera.carouselTargetID != nil && field(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        #expect(window.firstResponder === editor)
        try await SwiftUIReplay.wait { state.camera.carouselPaused }
        state.beginInteraction(cardID: "focus-0"); state.endInteraction(cardID: "focus-0")
        #expect(state.camera.carouselPaused && !state.camera.manual)
        window.makeFirstResponder(nil)
        try await SwiftUIReplay.wait { !state.camera.carouselPaused }
    }

    @Test func adaptivePaletteRendersBothAppearancesWithoutNativeColors() throws {
        for (scheme, expected) in [(ColorScheme.light, 0xf8f7f4), (.dark, 0x20211f)] {
            let renderer = ImageRenderer(content: Rectangle().fill(NativePalette.overview.canvas.swiftUI)
                .frame(width: 8, height: 8).environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            let offset = (4 * 8 + 4) * 4
            #expect(abs(Int(bytes[offset]) - ((expected >> 16) & 255)) < 2)
            #expect(abs(Int(bytes[offset + 1]) - ((expected >> 8) & 255)) < 2)
            #expect(abs(Int(bytes[offset + 2]) - (expected & 255)) < 2)
        }
    }
}

@MainActor @Observable private final class OverviewTextFixture {
    let visibility = ThreadCardAnimationVisibility()
    let presentation = try! composeThreadCard(.standard(extensions: []), layoutContext: .init(availableCols: 1))
    var title = "Title A"
    var content = "Initial excerpt"
    var message = "Initial excerpt"
    var messageID: JSONText = "message"
    var scenePhase = ScenePhase.active
    var reduceMotion = false
    var suppliesVisibility = true
    @ObservationIgnored var appearances = 0
    @ObservationIgnored var disappearances = 0
    @ObservationIgnored var identities: [UUID] = []

    func setMessage(_ text: String, id: JSONText = "message", excerpt: String? = nil) {
        message = text; messageID = id; content = excerpt ?? String(text.suffix(600))
    }
}

private struct OverviewTextReplay: View {
    let fixture: OverviewTextFixture
    var titleOnly = false
    @State private var identity = UUID()
    var body: some View {
        Group {
            if titleOnly {
                HarnessThreadCard(identity: .init(title: fixture.title, excerpt: ""), presentation: fixture.presentation)
            } else {
                ThreadCardExcerpt(content: fixture.content, messageId: fixture.messageID, messageText: fixture.message)
                    .padding(18)
            }
        }
        .frame(width: 360, height: 200)
        .background(Color.white)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.colorScheme, .light)
        .environment(\.scenePhase, fixture.scenePhase)
        .environment(\.threadCardTextReduceMotionOverride, Optional(fixture.reduceMotion))
        .environment(\.threadCardAnimationVisibility, fixture.suppliesVisibility ? fixture.visibility : nil)
        .environment(\.threadCardCloudAnimationsEnabled, false)
        .onAppear { fixture.appearances += 1; fixture.identities.append(identity) }
        .onDisappear { fixture.disappearances += 1 }
    }
}

extension SwiftUIOverviewInteractionTests {
    @Test(.requiresDisplay) func streamingTitlesMakeProgressBeforeInputStops() async throws {
        let fixture = OverviewTextFixture()
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture, titleOnly: true), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Title A") }
        var displayedDuringStream = Set<String>()
        for index in 1...12 {
            fixture.title = "Streaming title \(index)"
            try await Task.sleep(for: .milliseconds(100))
            // The helper reads AX label/value, never the outer card's .help
            // text, so observing a title means its displayed Text was replaced.
            displayedDuringStream.formUnion(SwiftUIReplay.text(in: root).filter { $0.hasPrefix("Streaming title ") })
        }
        #expect(displayedDuringStream.count >= 2)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Streaming title 12") }
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func titleReversalAndVisibilityCancellationSettlePixels() async throws {
        let fixture = OverviewTextFixture()
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture, titleOnly: true), width: 360, height: 200)
        defer { window.close() }
        var captures: [(String, Data)] = []
        var windowCaptures: [(String, CGImage)] = []
        var measurements: [[String: String]] = []
        defer {
            do {
                // Every stream path stops before leaving the method. Encoding
                // and disk writes cannot delay the live cancellation boundary.
                for (name, image) in windowCaptures {
                    captures.append((name, try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))))
                }
                try saveTextCaptures(captures, measurements: measurements)
            }
            catch { Issue.record(Comment(rawValue: "Could not save title cancellation captures: \(error)")) }
        }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Title A") }
        try await Task.sleep(for: .milliseconds(350))
        let original = try textPixels(in: root)
        captures.append(("01-original", original))
        fixture.title = "Title B"
        try await Task.sleep(for: .milliseconds(50))
        fixture.title = "Title A"
        try await Task.sleep(for: .milliseconds(500))
        let reversed = try textPixels(in: root)
        captures.append(("02-reversed", reversed))
        #expect(reversed == original)

        fixture.title = "Cancelled title"
        try await Task.sleep(for: .milliseconds(40))
        fixture.visibility.isVisible = false
        fixture.title = "Hidden latest"
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Hidden latest") }
        let hidden = try textPixels(in: root)
        captures.append(("03-hidden-before-reversal", hidden))
        fixture.visibility.isVisible = true
        try await Task.sleep(for: .milliseconds(20))
        fixture.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(350))
        let hiddenAfter = try textPixels(in: root)
        captures.append(("04-hidden-after-reversal", hiddenAfter))
        #expect(hiddenAfter == hidden)

        fixture.visibility.isVisible = true
        fixture.scenePhase = .background
        fixture.title = "Background latest"
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Background latest") }
        let background = try textPixels(in: root)
        captures.append(("05-background", background))
        fixture.scenePhase = .inactive
        try await Task.sleep(for: .milliseconds(350))
        let foreground = try textPixels(in: root)
        captures.append(("06-foreground", foreground))
        #expect(foreground == background)
        fixture.reduceMotion = true
        fixture.title = "Reduced motion latest"
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Reduced motion latest") }
        let reduced = try textPixels(in: root)
        captures.append(("07-reduced-motion", reduced))
        try await Task.sleep(for: .milliseconds(350))
        let reducedAfter = try textPixels(in: root)
        captures.append(("08-reduced-motion-after", reducedAfter))
        #expect(reducedAfter == reduced)

        // AX can publish the title after its presentation has settled, and
        // cacheDisplay is not a WindowServer animation oracle. Arm the existing
        // continuous capture before input; all references use this same stream.
        let shareable = try await SCShareableContent.currentProcess
        let target = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        let frames = TagGlassFrames()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "overview-title-capture"))
        let titlebar = window.frame.height - root.bounds.height
        let region = CGRect(x: 8 * scale, y: (titlebar + 8) * scale,
                            width: (root.bounds.width - 16) * scale, height: 64 * scale).integral
        try await stream.startCapture()
        do {
            let reducedWindow = try await titleWindowFrame(frames, region: region, stage: "reduced-reference",
                captures: &windowCaptures, measurements: &measurements) { _ in true }
            fixture.title = "Title A"
            let titleWindow = try await titleWindowFrame(frames, region: region, stage: "title-reference",
                captures: &windowCaptures, measurements: &measurements) { $0.pixels.data != reducedWindow.pixels.data }
            // NBSP preserves the title line's layout but has no visible ink.
            // A partial nonblank frame can therefore only be incoming motion.
            fixture.title = "\u{00a0}"
            let blankWindow = try await titleWindowFrame(frames, region: region, stage: "blank-reference",
                captures: &windowCaptures, measurements: &measurements) { $0.pixels.ink() < titleWindow.pixels.ink() * 0.01 }
            let fullInk = titleWindow.pixels.ink() - blankWindow.pixels.ink()
            try #require(fullInk > 0)
            let incomingEnd = try #require(titleWindow.pixels.lastInkColumn(comparedTo: blankWindow.pixels))
            let newTitleStart = incomingEnd + Int(8 * scale)
            let changedTitleInk = reducedWindow.pixels.ink(after: newTitleStart) - blankWindow.pixels.ink(after: newTitleStart)
            try #require(changedTitleInk > 0)
            _ = frames.takeSamples()
            fixture.reduceMotion = false
            fixture.title = "Title A"
            let incoming = try await titleWindowFrame(frames, region: region, stage: "incoming",
                captures: &windowCaptures, measurements: &measurements) { frame in
                let fraction = (frame.pixels.ink() - blankWindow.pixels.ink()) / fullInk
                return fraction > 0.1 && fraction < 0.6
                    && ProcessInfo.processInfo.systemUptime - frame.sample.receivedAt < 0.05
            }
            try #require(incoming.pixels.data != blankWindow.pixels.data && incoming.pixels.data != titleWindow.pixels.data,
                         "Cancellation requires a live incoming frame, not either static endpoint")
            let cancelledAt = ProcessInfo.processInfo.systemUptime
            try #require(cancelledAt - incoming.sample.receivedAt < 0.05, "The observed incoming frame is stale")
            fixture.reduceMotion = true
            fixture.title = "Reduced motion latest"
            measurements.append(["stage": "cancel", "receivedAt": "\(incoming.sample.receivedAt)",
                "cancelledAt": "\(cancelledAt)", "inkFraction": "\((incoming.pixels.ink() - blankWindow.pixels.ink()) / fullInk)"])
            // The long replacement has ink beyond Title A's bounds, even after
            // allowing for its blur. Inspect its first real frame, without an
            // AX wait that could conceal continued interpolation.
            _ = try await titleWindowFrame(frames, region: region, stage: "cancelled",
                captures: &windowCaptures, measurements: &measurements, firstMatching: true,
                check: { frame in #expect(frame.pixels.data == reducedWindow.pixels.data) }) { frame in
                // Old Title A frames may arrive after the cancellation call.
                // Require both increasing presentation time and actual ink
                // unique to the replacement, not just a callback timestamp.
                frame.sample.presentationTime > incoming.sample.presentationTime
                    && frame.pixels.ink(after: newTitleStart) - blankWindow.pixels.ink(after: newTitleStart) > changedTitleInk * 0.02
            }
            try await Task.sleep(for: .milliseconds(350))
            // Complete frames represent changed window surfaces. Every update
            // after cancellation must remain identical to the settled reference.
            for (index, sample) in frames.takeSamples().enumerated() {
                windowCaptures.append(("window-after-cancel-\(index)", sample.image))
                #expect(try titleWindowPixels(sample.image, region: region).data == reducedWindow.pixels.data)
            }
            try await stream.stopCapture()
            print("TITLE_INCOMING_MOTION_CONFIRMED received=\(incoming.sample.receivedAt) cancelled=\(cancelledAt)")
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func retainedExcerptsPauseHiddenBacklogAndResumeLatestInput() async throws {
        let fixture = OverviewTextFixture()
        fixture.visibility.isVisible = false
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        fixture.setMessage("First hidden replacement")
        fixture.setMessage("Latest before first appearance")
        try await Task.sleep(for: .milliseconds(100))
        #expect(SwiftUIReplay.text(in: root).contains("Latest before first appearance"))
        let initialHiddenPixels = try textPixels(in: root)
        fixture.visibility.isVisible = true
        try await SwiftUIReplay.wait {
            guard let pixels = try? textPixels(in: root) else { return false }
            return pixels != initialHiddenPixels && SwiftUIReplay.text(in: root).contains("Latest before first appearance")
        }

        let first = String(repeating: "A", count: 600), second = String(repeating: "B", count: 600)
        fixture.setMessage(first + second + "old tail")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(first) }
        fixture.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(100))
        let hiddenPixels = try textPixels(in: root)
        fixture.setMessage(first + second + "latest hidden tail", excerpt: "latest hidden tail")
        try await Task.sleep(for: .milliseconds(1_200))
        // Semantic content stays current while the rendered window is frozen.
        #expect(SwiftUIReplay.text(in: root).contains("latest hidden tail"))
        #expect(try textPixels(in: root) == hiddenPixels)
        fixture.visibility.isVisible = true
        var resumedPixels: Data?
        try await SwiftUIReplay.wait {
            guard let pixels = try? textPixels(in: root), pixels != hiddenPixels,
                  SwiftUIReplay.text(in: root).contains("latest hidden tail") else { return false }
            resumedPixels = pixels
            return true
        }
        let resumed = try #require(resumedPixels)
        try await Task.sleep(for: .milliseconds(350))
        #expect(try textPixels(in: root) == resumed)

        fixture.scenePhase = .background
        try await Task.sleep(for: .milliseconds(50))
        let backgroundPixels = try textPixels(in: root)
        fixture.setMessage("new background message", id: "replacement")
        try await Task.sleep(for: .milliseconds(100))
        #expect(SwiftUIReplay.text(in: root).contains("new background message"))
        #expect(try textPixels(in: root) == backgroundPixels)
        fixture.scenePhase = .inactive
        try await SwiftUIReplay.wait {
            guard let pixels = try? textPixels(in: root) else { return false }
            return pixels != backgroundPixels && SwiftUIReplay.text(in: root).contains("new background message")
        }
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func excerptWindowsAdvanceDuringAppendsAndRespectCurrentMotionPolicy() async throws {
        let fixture = OverviewTextFixture()
        fixture.suppliesVisibility = false
        fixture.visibility.isVisible = false
        fixture.setMessage("A")
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("A") }
        fixture.setMessage("AB")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("AB") }
        let first = "AB" + String(repeating: "A", count: 598), second = String(repeating: "B", count: 600)
        fixture.setMessage(first)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(first) }
        try await Task.sleep(for: .milliseconds(180))
        // Crossing 600 characters changes `more`, but later appends must not
        // reset the hold while the current window and its Markdown context match.
        fixture.setMessage(first + second)
        var advancedDuringInput = false
        for index in 1...9 {
            if index == 2 { fixture.reduceMotion = true }
            fixture.setMessage(first + second + String(repeating: "c", count: index))
            try await Task.sleep(for: .milliseconds(100))
            if SwiftUIReplay.text(in: root).contains(second) {
                advancedDuringInput = true
                let settled = try textPixels(in: root)
                try await Task.sleep(for: .milliseconds(60))
                #expect(try textPixels(in: root) == settled)
                break
            }
        }
        #expect(advancedDuringInput)
        // A rewrite must invalidate the reused full-window preview, even at the
        // same offset; changing message identity must do so as well.
        fixture.setMessage("**rewritten** text")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("rewritten text") }
        fixture.setMessage("**replacement** text", id: "new-message")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("replacement text") }

        // Keep a full displayed window while the transport drops its consumed
        // prefix. Its absolute hold boundary must still advance to the next one.
        fixture.scenePhase = .background
        try await Task.sleep(for: .milliseconds(50))
        fixture.setMessage(first + second, id: "shifted-message", excerpt: second)
        fixture.scenePhase = .active
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(second) }
        let third = String(repeating: "C", count: 600)
        fixture.setMessage(first + second + third, id: "shifted-message")
        try await Task.sleep(for: .milliseconds(100))
        fixture.setMessage(second + third, id: "shifted-message")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(third) }
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func retainedExcerptRestartsAfterHostingViewReattachmentWithoutInputChange() async throws {
        let fixture = OverviewTextFixture()
        fixture.reduceMotion = true
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Initial excerpt") }
        let first = String(repeating: "A", count: 600), second = String(repeating: "B", count: 600)
        fixture.setMessage(first + second + "retained latest tail", excerpt: "retained latest tail")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(first) }

        // Retain this exact NSHostingView and its SwiftUI state. No source,
        // visibility or motion-policy property changes across the lifecycle edge.
        window.contentView = nil
        try await SwiftUIReplay.wait { fixture.disappearances == 1 }
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        try await SwiftUIReplay.wait {
            fixture.appearances == 2 && SwiftUIReplay.text(in: root).contains("retained latest tail")
        }
        #expect(window.contentView === root)
        #expect(Set(fixture.identities).count == 1)
        fixture.setMessage("content after reattachment")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("content after reattachment") }
        #expect(fixture.appearances == 2)
    }

    /// Observe the production mask in WindowServer frames. Static production
    /// excerpts supply glyph references; no test changes the animation policy.
    @Test(.requiresDisplay) func excerptRevealKeepsMovingThroughRewriteAndWidthChanges() async throws {
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                     "Excerpt motion observation requires the native runner's ordinary motion-enabled environment")
        for scenario in ExcerptInkScenario.allCases {
            try await captureExcerptInk(scenario)
        }
        print("EXCERPT_INK_MOTION_CONFIRMED fixed=true rewrite=true localResize=true WindowServer=true")
    }

    private func captureExcerptInk(_ scenario: ExcerptInkScenario) async throws {
        let fixture = ExcerptInkFixture()
        let window = SwiftUIReplay.window(ExcerptInkReplay(fixture: fixture), width: 420, height: 580)
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let root = try #require(window.contentView)
        var captures: [TagGlassFrames.Sample] = []
        var report = ExcerptInkReport(scenario: scenario.rawValue, backingScale: Double(window.backingScaleFactor))
        defer {
            report.widths = fixture.widths
            report.appearances = fixture.appearances
            do { try saveExcerptInk(captures, report: report) }
            catch { Issue.record(Comment(rawValue: "Could not retain excerpt WindowServer evidence: \(error)")) }
        }
        try await SwiftUIReplay.wait {
            fixture.widths.contains { abs($0.width - 360) < 0.01 }
                && SwiftUIReplay.text(in: root).contains(ExcerptInkFixture.first)
                && SwiftUIReplay.text(in: root).contains(ExcerptInkFixture.second)
        }
        // Initial mounting installs the production preview without a reveal.
        // References settle before capture; timed actions never wait on AX.
        try await Task.sleep(for: .milliseconds(350))
        let shareable = try await SCShareableContent.currentProcess
        let target = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let scale = window.backingScaleFactor
        let titlebar = window.frame.height - root.bounds.height
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        let frames = TagGlassFrames()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "overview-excerpt-capture"))
        try await stream.startCapture()
        do {
            try await SwiftUIReplay.wait { frames.ready }
            captures.append(contentsOf: frames.takeSamples())
            report.baselineIndex = captures.count - 1
            let began = ProcessInfo.processInfo.systemUptime
            report.events.append(.init(name: "rewrite-from-blank", uptime: began, width: 360))
            fixture.message = ExcerptInkFixture.first
            fixture.phase = 1
            if let delay = scenario.interruptionDelay {
                try await collectExcerptFrames(frames, until: began + delay, into: &captures)
                let changed = ProcessInfo.processInfo.systemUptime
                report.actualInterruptionMilliseconds = (changed - began) * 1000
                report.events.append(.init(name: scenario == .rewrite ? "rewrite-again" : "change-local-width",
                                           uptime: changed, width: scenario == .resize ? 280 : 360))
                if scenario == .rewrite { fixture.message = ExcerptInkFixture.second }
                else { fixture.width = 280 }
                fixture.phase = 2
                try await collectExcerptFrames(frames, until: changed + 0.45, into: &captures)
            } else {
                try await collectExcerptFrames(frames, until: began + 0.45, into: &captures)
            }
            try await stream.stopCapture()
            captures.append(contentsOf: frames.takeSamples())
        } catch {
            try? await stream.stopCapture()
            captures.append(contentsOf: frames.takeSamples())
            throw error
        }

        // All pixel work and encoding occur after stop. During motion, draining
        // every 5 ms keeps TagGlassFrames' 60-frame bound from discarding evidence.
        func region(_ top: CGFloat) -> CGRect {
            CGRect(x: 16 * scale, y: (titlebar + top) * scale,
                   width: 360 * scale, height: 96 * scale).integral
        }
        let baseline = try #require(captures.indices.contains(report.baselineIndex) ? captures[report.baselineIndex] : nil,
                                    "Observation incomplete: no full WindowServer baseline")
        report.capturedPixels = [baseline.image.width, baseline.image.height]
        try #require(baseline.image.width == configuration.width && baseline.image.height == configuration.height,
                     "Observation incomplete: capture dimensions do not match the full window at its actual backing scale")
        let blank = try titleWindowPixels(baseline.image, region: region(48))
        let wide = try titleWindowPixels(baseline.image, region: region(174))
        let replacement = try titleWindowPixels(baseline.image, region: region(300))
        let narrow = try titleWindowPixels(baseline.image, region: region(426))
        let wideMask = ExcerptInkReference(blank: blank, full: wide)
        let replacementMask = ExcerptInkReference(blank: blank, full: replacement, excluding: wide)
        let previousMask = ExcerptInkReference(blank: blank, full: wide, excluding: replacement)
        let narrowMask = ExcerptInkReference(blank: blank, full: narrow)
        try #require([wideMask, replacementMask, previousMask, narrowMask].allSatisfy { $0.pointCount > 30 },
                     "Observation incomplete: settled production references have insufficient independent glyph pixels")
        var crops: [TitleWindowPixels] = []
        for (index, sample) in captures.enumerated() {
            let pixels = try titleWindowPixels(sample.image, region: region(48))
            crops.append(pixels)
            let phase = try excerptPhase(sample.image,
                                         at: CGPoint(x: 22 * scale, y: (titlebar + 22) * scale))
            let widthPixels = try excerptComposedWidth(sample.image,
                at: CGPoint(x: 16 * scale, y: (titlebar + 148) * scale), maximum: Int(362 * scale))
            report.frames.append(.init(index: index, phase: phase,
                composedWidth: Double(widthPixels) / Double(scale), composedWidthPixels: widthPixels,
                receivedAt: sample.receivedAt, presentationTime: sample.presentationTime,
                wide: wideMask.exposure(pixels), replacement: replacementMask.exposure(pixels),
                previous: previousMask.exposure(pixels), narrow: narrowMask.exposure(pixels)))
        }
        try #require(report.frames.allSatisfy { $0.phase >= 0 },
                     "Observation incomplete: a WindowServer frame does not contain the fixture's phase marker")
        if let delay = scenario.interruptionDelay {
            let actual = report.events[1].uptime - report.events[0].uptime
            try #require(actual >= delay - 0.005 && actual < delay + 0.06,
                         "Observation incomplete: the requested interruption was delivered too late to characterize this short reveal")
        }
        func hasWidth(_ frame: ExcerptInkFrameRecord, _ points: CGFloat) -> Bool {
            abs(frame.composedWidthPixels - Int(points * scale)) <= 1
        }
        let phaseOne = report.frames.filter { $0.phase == 1 && hasWidth($0, 360) }
        try #require(!phaseOne.isEmpty, "Observation incomplete: no composed frame acknowledged the first input")
        try requireExcerptMotion(phaseOne, key: \.wide, stage: scenario.rawValue + "-before-interruption",
                                 minimumFrames: scenario == .fixed ? 3 : 2,
                                 minimumGain: scenario == .fixed ? 0.18 : 0.06, scale: scale)
        let finalFrames: [ExcerptInkFrameRecord]
        let expected: TitleWindowPixels
        switch scenario {
        case .fixed:
            finalFrames = phaseOne
            expected = wide
        case .rewrite:
            let after = report.frames.filter { $0.phase == 2 && hasWidth($0, 360) }
            try #require(!after.isEmpty, "Observation incomplete: no composed frame acknowledged the second rewrite")
            let firstTime = try #require(after.first).presentationTime
            // The old display is the complete logical text by contract. A
            // rewrite may restore that ink; its NEW incoming row must restart
            // near zero, then reveal. Independent glyph supports prevent the
            // incoming/outgoing colors from cancelling this measurement.
            let reset = after.first {
                $0.presentationTime - firstTime <= 0.065
                    && $0.replacement.fraction <= 0.15 && $0.previous.fraction >= 0.80
            }
            let observedReset = try #require(reset,
                "Observation incomplete or changed reset behavior: no early frame shows complete previous ink and a reset incoming mask")
            report.resetFrameIndex = observedReset.index
            try #require(after.prefix { $0.index <= observedReset.index }.allSatisfy { $0.replacement.fraction <= 0.20 },
                         "The incoming replacement was already advanced before its observed reset")
            try requireExcerptMotion(after, key: \.replacement, stage: "rewrite-new-incoming",
                                     minimumFrames: 3, minimumGain: 0.18, scale: scale)
            finalFrames = after
            expected = replacement
        case .resize:
            try #require(fixture.widths.contains { abs($0.width - 360) < 0.01 }
                         && fixture.widths.contains { abs($0.width - 280) < 0.01 },
                         "Observation incomplete: the production excerpt's local width did not change from 360 to 280 points")
            try #require(abs(root.bounds.width - 420) < 0.01,
                         "Resize fixture must change local excerpt width while the window stays fixed")
            let after = report.frames.filter { $0.phase == 2 && hasWidth($0, 280) }
            try #require(!after.isEmpty, "Observation incomplete: no composed frame acknowledged local resize")
            try requireExcerptMotion(after, key: \.narrow, stage: "after-local-resize",
                                     minimumFrames: 2, minimumGain: 0.06, scale: scale)
            finalFrames = after
            expected = narrow
        }
        let final = try #require(finalFrames.last)
        let error = ExcerptInkReference.relativeError(crops[final.index], expected: expected, blank: blank)
        report.finalRelativeError = error
        try #require(error < 0.02, "The settled WindowServer excerpt differs from its production reference")
        try #require(fixture.appearances == 1, "The moving production excerpt remounted during the observed reveal")
        report.assertionsPassed = true
    }

    private func collectExcerptFrames(_ frames: TagGlassFrames, until deadline: TimeInterval,
                                      into captures: inout [TagGlassFrames.Sample]) async throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            captures.append(contentsOf: frames.takeSamples())
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(for: .seconds(min(0.005, remaining))) }
        }
        captures.append(contentsOf: frames.takeSamples())
    }

    private func requireExcerptMotion(_ frames: [ExcerptInkFrameRecord],
                                      key: KeyPath<ExcerptInkFrameRecord, ExcerptInkExposure>,
                                      stage: String, minimumFrames: Int,
                                      minimumGain: Double, scale: CGFloat) throws {
        // Inspect every frame of this phase and composed geometry before
        // selecting motion samples. A full->partial jump or an earlier peak
        // cannot disappear merely because a later pair moves correctly.
        var peak = 0.0
        var reachedFull = false
        for frame in frames {
            let fraction = frame[keyPath: key].fraction
            try #require(fraction + 0.025 >= peak,
                Comment(rawValue: "Incoming ink visibly regressed in " + stage + " at frame \(frame.index)"))
            try #require(!reachedFull || fraction >= 0.965,
                Comment(rawValue: "A fully exposed frame was followed by partial ink in " + stage + " at frame \(frame.index)"))
            peak = max(peak, fraction)
            reachedFull = reachedFull || fraction >= 0.98
        }
        let partial = frames.filter {
            let exposure = $0[keyPath: key]
            return exposure.fraction > 0.02 && exposure.fraction < 0.98 && exposure.front != nil
        }
        try #require(partial.count >= minimumFrames,
                     Comment(rawValue: "Observation incomplete: too few intermediate WindowServer ink frames for " + stage))
        let movesLeft = partial.enumerated().contains { index, first in
            partial.dropFirst(index + 1).contains { last in
                guard let start = first[keyPath: key].front, let end = last[keyPath: key].front else { return false }
                return last.presentationTime > first.presentationTime + 0.012
                    && first[keyPath: key].fraction + minimumGain <= last[keyPath: key].fraction
                    && start - end >= Int(4 * scale)
            }
        }
        try #require(movesLeft,
                     Comment(rawValue: "No observed right-to-left mask boundary motion between intermediate frames for " + stage))
    }

    private func excerptPhase(_ image: CGImage, at point: CGPoint) throws -> Int {
        let pixel = try titleWindowPixels(image, region: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        let bytes = [UInt8](pixel.data)
        let blue = Int(bytes[0]), green = Int(bytes[1]), red = Int(bytes[2])
        if max(red, max(green, blue)) < 48 { return 0 }
        if red > 200 && blue > 200 && green < 64 { return 1 }
        if green > 200 && blue > 200 && red < 64 { return 2 }
        return -1
    }

    private func excerptComposedWidth(_ image: CGImage, at point: CGPoint, maximum: Int) throws -> Int {
        let pixels = try titleWindowPixels(image,
            region: CGRect(origin: point, size: CGSize(width: CGFloat(maximum), height: 1)))
        let bytes = [UInt8](pixels.data)
        func blue(_ column: Int) -> Bool {
            let offset = column * 4
            return bytes[offset] > 200 && bytes[offset + 1] < 64 && bytes[offset + 2] < 64
        }
        let width = (0..<maximum).prefix(while: blue).count
        // A contiguous bar must end in this crop; disconnected pixels are not
        // accepted as the local layout width.
        guard width < maximum, !(width..<maximum).contains(where: blue) else { return -1 }
        return width
    }

    private func saveExcerptInk(_ captures: [TagGlassFrames.Sample], report: ExcerptInkReport) throws {
        let directory: URL
        if let root = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"] {
            directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("excerpt", isDirectory: true)
        } else {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<6 { repository.deleteLastPathComponent() }
            directory = repository.appendingPathComponent(".scratch/reading-presentation/excerpt", isDirectory: true)
        }
        let output = directory.appendingPathComponent(report.scenario, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (index, sample) in captures.enumerated() {
            let image = NSBitmapImageRep(cgImage: sample.image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(String(format: "%03d.png", index)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("measurements.json"))
    }

    private func textPixels(in root: NSView) throws -> Data {
        root.layoutSubtreeIfNeeded(); root.window?.displayIfNeeded()
        let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: image)
        return try #require(image.representation(using: .png, properties: [:]))
    }

    private func titleWindowFrame(_ frames: TagGlassFrames, region: CGRect, stage: String,
                                  captures: inout [(String, CGImage)], measurements: inout [[String: String]],
                                  firstMatching: Bool = false, check: ((TitleWindowFrame) -> Void)? = nil,
                                  accepts: (TitleWindowFrame) -> Bool) async throws -> TitleWindowFrame {
        let deadline = ContinuousClock.now + .seconds(3)
        var selected: TitleWindowFrame?
        while ContinuousClock.now < deadline {
            let samples = frames.takeSamples()
            for sample in samples {
                captures.append(("window-\(stage)-\(captures.count)", sample.image))
            }
            // Incoming motion requires the newest complete frame. Cancellation
            // inspects the first replacement frame and every later frame in its
            // batch, so a settled last frame cannot conceal an earlier fade.
            for sample in firstMatching ? samples : Array(samples.suffix(1)) {
                let frame = TitleWindowFrame(sample: sample, pixels: try titleWindowPixels(sample.image, region: region))
                measurements.append(["stage": stage, "receivedAt": "\(sample.receivedAt)",
                    "presentationTime": "\(sample.presentationTime)", "ink": "\(frame.pixels.ink())"])
                if selected != nil || accepts(frame) {
                    if selected == nil { selected = frame }
                    check?(frame)
                }
            }
            if selected != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(selected, Comment(rawValue: "No qualifying current WindowServer frame during " + stage))
    }

    private func titleWindowPixels(_ image: CGImage, region: CGRect) throws -> TitleWindowPixels {
        try #require(image.bitsPerPixel == 32 && image.bitsPerComponent == 8)
        try #require(region.minX >= 0 && region.minY >= 0 && region.maxX <= CGFloat(image.width) && region.maxY <= CGFloat(image.height))
        let provider = try #require(image.dataProvider?.data)
        let source = try #require(CFDataGetBytePtr(provider))
        let width = Int(region.width), height = Int(region.height)
        var pixels = Data(capacity: width * height * 4)
        for y in Int(region.minY)..<Int(region.maxY) {
            // Compare only valid BGRA pixels, never bytesPerRow padding.
            pixels.append(source.advanced(by: y * image.bytesPerRow + Int(region.minX) * 4), count: width * 4)
        }
        return TitleWindowPixels(data: pixels, width: width)
    }

    private func saveTextCaptures(_ captures: [(String, Data)], measurements: [[String: String]]) throws {
        let directory: URL
        if let artifacts = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"] {
            // NativeReplay stages these sources outside the checkout and
            // exports this writable artifact root after the app exits.
            directory = URL(fileURLWithPath: artifacts, isDirectory: true)
                .appendingPathComponent("overview-text-motion", isDirectory: true)
        } else {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<6 { repository.deleteLastPathComponent() }
            directory = repository.appendingPathComponent(".scratch/reading-presentation/overview-text-motion", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, pixels) in captures {
            try pixels.write(to: directory.appendingPathComponent(name + ".png"))
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("window-frames.json"))
    }
}

private enum ExcerptInkScenario: String, CaseIterable {
    case fixed, rewrite, resize
    var interruptionDelay: TimeInterval? {
        switch self {
        case .fixed: nil
        case .rewrite: 0.100
        case .resize: 0.140
        }
    }
}

@MainActor @Observable private final class ExcerptInkFixture {
    // The replacement occupies another line. Its independent glyph pixels
    // distinguish new incoming ink from the complete logical previous text.
    static let first = String(repeating: "M", count: 36)
    static let second = "\n" + first
    var message = "\u{00a0}"
    var width: CGFloat = 360
    var phase = 0
    @ObservationIgnored var widths: [ExcerptInkWidth] = []
    @ObservationIgnored var appearances = 0
}

private struct ExcerptInkReplay: View {
    let fixture: ExcerptInkFixture

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Rectangle()
                .fill(Color(.sRGB, red: fixture.phase == 1 ? 1 : 0,
                            green: fixture.phase == 2 ? 1 : 0,
                            blue: fixture.phase == 0 ? 0 : 1, opacity: 1))
                .frame(width: 12, height: 12)
                .offset(x: 16, y: 16)
            ThreadCardExcerpt(content: fixture.message, messageId: "excerpt-ink-motion", messageText: fixture.message)
                .lineLimit(5)
                .onAppear { fixture.appearances += 1 }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    fixture.widths.append(.init(uptime: ProcessInfo.processInfo.systemUptime, width: Double(width)))
                }
                .frame(width: fixture.width, height: 96, alignment: .topLeading)
                .overlay {
                    // Use the actual frame's geometry. A bottom alignment can
                    // inherit the excerpt's text guide, which moves as lines
                    // change and can put the marker inside the ink crop.
                    GeometryReader { geometry in
                        Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)
                            .frame(width: geometry.size.width, height: 3)
                            .offset(y: geometry.size.height + 3)
                    }
                }
                .offset(x: 16, y: 48)
            reference(ExcerptInkFixture.first, width: 360).offset(x: 16, y: 174)
            reference(ExcerptInkFixture.second, width: 360).offset(x: 16, y: 300)
            reference(ExcerptInkFixture.first, width: 280).offset(x: 16, y: 426)
        }
        .preferredColorScheme(.light)
        .environment(\.scenePhase, .active)
    }

    private func reference(_ value: String, width: CGFloat) -> some View {
        ThreadCardExcerpt(content: value, messageId: "excerpt-ink-reference", messageText: value)
            .lineLimit(5)
            .frame(width: width, height: 96, alignment: .topLeading)
    }
}

private struct ExcerptInkWidth: Encodable { let uptime: TimeInterval; let width: Double }
private struct ExcerptInkEvent: Encodable { let name: String; let uptime: TimeInterval; let width: Double }
private struct ExcerptInkReport: Encodable {
    let scenario: String
    let backingScale: Double
    let captureKind = "WindowServer/ScreenCaptureKit complete BGRA frames"
    let initialLocalFramePoints = [360, 96]
    let windowContentPoints = [420, 580]
    let camera = "none"
    var capturedPixels: [Int]?
    var assertionsPassed = false
    var appearances = 0
    var baselineIndex = -1
    var events: [ExcerptInkEvent] = []
    var widths: [ExcerptInkWidth] = []
    var frames: [ExcerptInkFrameRecord] = []
    var actualInterruptionMilliseconds: Double?
    var resetFrameIndex: Int?
    var finalRelativeError: Double?
}

private struct ExcerptInkFrameRecord: Encodable {
    let index: Int
    let phase: Int
    let composedWidth: Double
    let composedWidthPixels: Int
    let receivedAt: TimeInterval
    let presentationTime: Double
    let wide: ExcerptInkExposure
    let replacement: ExcerptInkExposure
    let previous: ExcerptInkExposure
    let narrow: ExcerptInkExposure
}

private struct ExcerptInkExposure: Encodable {
    let fraction: Double
    /// Leftmost reference-glyph column with at least 30% of its settled ink.
    /// Uniform opacity can change fraction without moving this boundary.
    let front: Int?
    let columns: [Double?]
}

private struct ExcerptInkReference {
    private struct Point {
        let offset: Int
        let column: Int
        let blue: Double
        let green: Double
        let red: Double
    }
    private let blank: [UInt8]
    private let points: [Point]
    private let weights: [Double]
    private let totalWeight: Double
    var pointCount: Int { points.count }

    init(blank: TitleWindowPixels, full: TitleWindowPixels, excluding: TitleWindowPixels? = nil) {
        let empty = [UInt8](blank.data), target = [UInt8](full.data)
        let excluded = excluding.map { [UInt8]($0.data) }
        var points: [Point] = []
        var weights = [Double](repeating: 0, count: full.width)
        for offset in stride(from: 0, to: target.count, by: 4) {
            let blue = Double(Int(empty[offset]) - Int(target[offset]))
            let green = Double(Int(empty[offset + 1]) - Int(target[offset + 1]))
            let red = Double(Int(empty[offset + 2]) - Int(target[offset + 2]))
            guard blue + green + red > 24 else { continue }
            if let excluded,
               (0..<3).reduce(0, { $0 + abs(Int(empty[offset + $1]) - Int(excluded[offset + $1])) }) > 12 {
                continue
            }
            let column = (offset / 4) % full.width
            points.append(.init(offset: offset, column: column, blue: blue, green: green, red: red))
            weights[column] += blue * blue + green * green + red * red
        }
        self.blank = empty; self.points = points; self.weights = weights
        totalWeight = weights.reduce(0, +)
    }

    func exposure(_ pixels: TitleWindowPixels) -> ExcerptInkExposure {
        let bytes = [UInt8](pixels.data)
        var sums = [Double](repeating: 0, count: weights.count)
        for point in points {
            let offset = point.offset
            sums[point.column] += Double(Int(blank[offset]) - Int(bytes[offset])) * point.blue
                + Double(Int(blank[offset + 1]) - Int(bytes[offset + 1])) * point.green
                + Double(Int(blank[offset + 2]) - Int(bytes[offset + 2])) * point.red
        }
        let columns: [Double?] = sums.indices.map { weights[$0] > 400 ? sums[$0] / weights[$0] : nil }
        return .init(fraction: sums.reduce(0, +) / max(1, totalWeight),
                     front: columns.indices.first { (columns[$0] ?? 0) >= 0.30 },
                     columns: columns)
    }

    static func relativeError(_ pixels: TitleWindowPixels, expected: TitleWindowPixels,
                              blank: TitleWindowPixels) -> Double {
        let actual = [UInt8](pixels.data), wanted = [UInt8](expected.data), empty = [UInt8](blank.data)
        var error = 0, reference = 0
        for offset in stride(from: 0, to: actual.count, by: 4) {
            for channel in 0..<3 {
                error += abs(Int(actual[offset + channel]) - Int(wanted[offset + channel]))
                reference += abs(Int(empty[offset + channel]) - Int(wanted[offset + channel]))
            }
        }
        return Double(error) / Double(max(1, reference))
    }
}

private struct TitleWindowFrame { let sample: TagGlassFrames.Sample; let pixels: TitleWindowPixels }
private struct TitleWindowPixels {
    let data: Data
    let width: Int

    func ink(after column: Int = 0) -> Double {
        guard column < width else { return 0 }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var total = 0
            for row in stride(from: 0, to: bytes.count, by: width * 4) {
                for x in max(0, column)..<width {
                    let offset = row + x * 4
                    total += 765 - Int(bytes[offset]) - Int(bytes[offset + 1]) - Int(bytes[offset + 2])
                }
            }
            return Double(total)
        }
    }

    func lastInkColumn(comparedTo blank: Self) -> Int? {
        guard data.count == blank.data.count, width == blank.width else { return nil }
        for x in stride(from: width - 1, through: 0, by: -1) {
            for offset in stride(from: x * 4, to: data.count, by: width * 4) {
                if (0..<3).contains(where: { abs(Int(data[offset + $0]) - Int(blank.data[offset + $0])) > 6 }) { return x }
            }
        }
        return nil
    }
}
