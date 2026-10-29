import AppKit
import QuartzCore
import SwiftUI
import MokuseiCore
@testable import MokuseiPluginUI
@testable import MokuseiUI

// Offscreen NSHostingViews exercise the actual production trees. No app windows,
// app activation, synthetic input or system appearance/preference writes.
@MainActor private struct SchemeProbe: NSViewRepresentable {
    let name: String
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.name = name; view.scheme = scheme
    }
}
@MainActor private final class ProbeView: NSView {
    var name = ""
    var scheme = ColorScheme.light
}
@MainActor private func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, T.self) }
}
@MainActor private func settle(_ host: NSView) async throws {
    for _ in 0..<12 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    // SwiftUI allocates an invisible TUINSWindow for offscreen rendering. It
    // is not an app surface; none of our hosts may attach or become visible.
    precondition(host.window == nil && !(NSApp?.windows.contains(where: \.isVisible) ?? false),
                 "Replay attached a host or displayed a window")
}
@MainActor private func probe(_ name: String, in host: NSView) -> ColorScheme {
    guard let view = descendants(host, ProbeView.self).first(where: { $0.name == name }) else {
        preconditionFailure("Missing production subtree: \(name)")
    }
    return view.scheme
}

@main struct MokuAppearanceReplay {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["MOKUSEI_TEST_HEADLESS"] == "1")
        try caret()
        try await surfaces()
        precondition(!(NSApp?.windows.contains(where: \.isVisible) ?? false))
        print("PASS: windowless Moku Dock/history/interaction and Settings isolation; Overview search native editor, dark material and single-line input; shared gradient pixels; dark caret/glow/breathing; appearance changes and Reduce Motion")
    }

    @MainActor private static func caret() throws {
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        editor.font = .systemFont(ofSize: 14)
        let caret = NativeComposerCaret()
        let rect = CGRect(x: 20, y: 20, width: 1, height: 20)
        for appearance in [NSAppearance.Name.aqua, .darkAqua,
                           .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua] {
            editor.appearance = NSAppearance(named: appearance)
            caret.show(at: rect, in: editor)
            precondition(abs(caret.layer.bounds.width - 2.6) < 0.001)
            precondition(abs(caret.layer.bounds.height - 14 * 25 / 24) < 0.001)
            let core = caret.layer.sublayers!.first { $0.name == "composer-insertion-core" }!
            let glow = caret.layer.sublayers!.first { $0.name == "composer-insertion-glow" }!
            precondition(core.backgroundColor == NSColor.white.cgColor)
            precondition(!glow.isHidden && glow.contents != nil)
            for (part, floor) in [(core, 0.2), (glow, 0.0)] {
                let breath = part.animation(forKey: "breathing") as! CABasicAnimation
                precondition(breath.keyPath == "opacity" && breath.duration == 1.2 && breath.autoreverses)
                precondition((breath.toValue as! Double) == floor && breath.repeatCount == .infinity)
            }
            caret.show(at: rect.offsetBy(dx: 10, dy: 0), in: editor)
            precondition(caret.layer.animation(forKey: "typing")?.duration == 0.12)
            caret.reduceMotion = true
            precondition(caret.layer.animationKeys()?.isEmpty ?? true)
            precondition(core.animationKeys()?.isEmpty ?? true)
            precondition(glow.animationKeys()?.isEmpty ?? true)
            caret.remove()
            precondition(caret.layer.superlayer == nil)
            caret.reduceMotion = false
        }
        precondition(editor.window == nil)
    }

    @MainActor private static func surfaces() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        draft.text = "Preserved draft 光标"
        let state = NativeMokuSceneState()
        state.setInputOpen(true)
        func root(_ scheme: ColorScheme, interaction: Bool = false) -> some View {
            VStack {
                SchemeProbe(name: "workspace").frame(height: 1)
                NativeMokuDock(state: state, draft: draft, cwd: "", mode: .idle,
                    interaction: interaction ? AnyView(SchemeProbe(name: "interaction")) : nil,
                    voiceBackground: AnyView(SchemeProbe(name: "dock")), onSend: { _ in }, onCancel: {})
                    .environment(\.nativeMokuSettingsContent, AnyView(SchemeProbe(name: "settings")))
                NativeMokuHistoryComposer(draft: draft, cwd: "", focusEnabled: false,
                    voiceBackground: AnyView(SchemeProbe(name: "history")), onSend: { _ in }, onCancel: {})
                NativeComposerTextInput(value: .constant("Ordinary thread"), placeholder: "",
                    automaticFocus: false, onSubmit: {})
            }
            .environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true }
        }
        let host = NSHostingView(rootView: root(.light))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        var editors: [ComposerTextView] = []
        for scheme in [ColorScheme.light, .dark, .light] {
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.rootView = root(scheme)
            try await settle(host)
            precondition(probe("workspace", in: host) == scheme)
            precondition(probe("dock", in: host) == .dark && probe("history", in: host) == .dark)
            let allEditors = descendants(host, ComposerTextView.self)
            let current = allEditors.filter(\.emphasizedInsertionPoint)
            precondition(current.count == 2, "Dock and history must retain their native editors")
            let ordinary = allEditors.first { !$0.emphasizedInsertionPoint }!
            precondition(ordinary.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (scheme == .light ? .aqua : .darkAqua),
                         "Moku override leaked into an ordinary composer")
            for editor in current {
                precondition(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                             "Native editor failed to inherit Moku's dark environment")
                precondition(editor.string == draft.text && editor.emphasizedInsertionPoint)
            }
            if !editors.isEmpty { precondition(zip(editors, current).allSatisfy { $0 === $1 }) }
            editors = current
        }
        state.openSettings()
        try await settle(host)
        precondition(probe("settings", in: host) == .light)
        host.rootView = root(.dark)
        try await settle(host)
        precondition(probe("settings", in: host) == .dark)
        precondition(draft.text == "Preserved draft 光标")
        state.closeSettings()
        host.rootView = root(.light, interaction: true)
        try await settle(host)
        precondition(probe("interaction", in: host) == .dark)

        try await searchField()
        try material()
    }

    /// The expanded Overview search uses the production native editor and
    /// Moku's dark material, even when the workspace is light.
    @MainActor private static func searchField() async throws {
        struct SearchProbe: View {
            let query: String
            let focus: Int
            var body: some View {
                NativeOverviewChrome(filters: [], isSearching: true, searchQuery: query,
                    searchFocusRequest: focus, onTagChange: { _ in })
                    .environment(\.colorScheme, .light)
                    .transaction { $0.disablesAnimations = true }
            }
        }
        func editor(_ query: String, focus: Int) async throws -> ComposerTextView {
            let host = NSHostingView(rootView: SearchProbe(query: query, focus: focus))
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
            host.appearance = NSAppearance(named: .aqua)
            try await settle(host)
            let editors = descendants(host, ComposerTextView.self).filter(\.emphasizedInsertionPoint)
            precondition(editors.count == 1, "Overview search must use the emphasized native editor")
            precondition(host.window == nil && !(NSApp?.windows.contains(where: \.isVisible) ?? false))
            return editors[0]
        }

        let short = try await editor("光标", focus: 1)
        precondition(short.singleLine, "Search must not accept line breaks")
        precondition(short.string == "光标")
        precondition(short.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                     "Search contents must inherit Moku's dark material appearance")

        // A long query must stay on one line and extend the native document
        // horizontally instead of wrapping into the fixed-height carrier.
        let long = try await editor(String(repeating: "long search query ", count: 8), focus: 0)
        let scroll = long.enclosingScrollView!
        long.layoutManager?.ensureLayout(for: long.textContainer!)
        let used = long.layoutManager!.usedRect(for: long.textContainer!)
        precondition(long.frame.width > scroll.contentSize.width,
                     "Long search query must scroll horizontally, not wrap")
        precondition(long.frame.width >= used.width,
                     "Document must reach the query's last caret position")
        precondition(used.height <= 20, "Search query must remain one line high")
        precondition(!scroll.hasVerticalScroller)
    }

    /// The shared material's actual opaque output must match under both
    /// inherited appearances, including its Reduce Transparency fallback and
    /// the gradient Overview search overlays.
    @MainActor private static func material() throws {
        var reference: Data?
        for scheme in [ColorScheme.dark, .light] {
            let renderer = ImageRenderer(content: NativeMokuCapsuleGlass(forceOpaque: true)
                .frame(width: 168, height: 44).environment(\.colorScheme, scheme))
            let image = renderer.cgImage!
            let data = image.dataProvider!.data! as Data
            if let reference { precondition(data == reference) } else { reference = data }
        }
        let search = ImageRenderer(content: NativeMokuCapsuleGradient(forceOpaque: true)
            .frame(width: 168, height: 44)).cgImage!
        precondition(search.dataProvider!.data! as Data == reference!,
                     "Search must render the same opaque material as Moku")
    }
}
