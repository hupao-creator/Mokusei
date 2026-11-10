import AppKit
import Darwin
import MarkdownUI
import MokuseiPluginUI
import SwiftUI
import Textual

private struct Failure: Error { let message: String }

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func footprintMiB() throws -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw Failure(message: "Cannot read physical footprint") }
    return Double(info.phys_footprint) / 1_048_576
}

@MainActor private final class State: ObservableObject {
    @Published var source: String
    var height: CGFloat = 0
    var lastGeometryChange = CACurrentMediaTime()
    init(_ source: String) { self.source = source }
}

@MainActor private struct Reader: View {
    @ObservedObject var state: State
    let renderer: String

    @ViewBuilder private var document: some View {
        switch renderer {
        case "production":
            NativeMarkdownView(text: state.source, fontSize: 16, openExternal: { _ in })
        case "textual":
            StructuredText(markdown: state.source)
                .textual.structuredTextStyle(.gitHub)
                .textual.textSelection(.enabled)
                .font(NativeTypography.inter(size: 16))
        default:
            Markdown(state.source)
                .markdownTheme(.gitHub)
                .markdownTextStyle {
                    FontFamily(.custom("Inter"))
                    FontSize(16)
                }
                .textSelection(.enabled)
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            document
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(height - state.height) > 0.1 {
                        state.height = height
                        state.lastGeometryChange = CACurrentMediaTime()
                    }
                }
                .padding(20)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .light)
        .environment(\.openURL, OpenURLAction { _ in .handled })
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var captureDirectory: URL?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); exit(0) }
            catch { print("BENCHMARK_ERROR \(error)"); exit(1) }
        }
    }

    private func foreground() throws {
        guard NSApp.isActive, window.isKeyWindow, window.occlusionState.contains(.visible) else {
            throw Failure(message: "Foreground or visible window lost")
        }
        guard ProcessInfo.processInfo.thermalState.rawValue < 2 else {
            throw Failure(message: "Serious/critical thermal state")
        }
    }

    private func settle(_ state: State) async throws {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 20 {
            // Every renderer receives the same native layout/display flush. This
            // measures component layout convergence, not final WindowServer pixels.
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if state.height > 0, CACurrentMediaTime() - start >= 0.2,
               CACurrentMediaTime() - state.lastGeometryChange >= 0.15 {
                try foreground()
                return
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        throw Failure(message: "Document geometry did not converge")
    }

    private func scrollView() throws -> NSScrollView {
        var candidates: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 1 {
                candidates.append(scroll)
            }
            view.subviews.forEach(visit)
        }
        if let root = window.contentView { visit(root) }
        guard let scroll = candidates.max(by: { $0.contentView.bounds.height < $1.contentView.bounds.height }) else {
            throw Failure(message: "No scrollable document found")
        }
        return scroll
    }

    private func capture(_ name: String) throws {
        guard let captureDirectory, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(message: "Cannot capture native view")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "Cannot encode capture")
        }
        try png.write(to: captureDirectory.appendingPathComponent(name + ".png"))
    }

    private func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, ["production", "textual", "markdownui"].contains(arguments[1]) else {
            throw Failure(message: "Expected renderer, fixture path and result path")
        }
        let renderer = arguments[1]
        let source = try String(contentsOfFile: arguments[2], encoding: .utf8)
        let output = URL(fileURLWithPath: arguments[3])
        try String(ProcessInfo.processInfo.processIdentifier).write(
            to: output.deletingPathExtension().appendingPathExtension("pid"), atomically: true, encoding: .utf8)
        if arguments.count > 4 { captureDirectory = URL(fileURLWithPath: arguments[4]) }
        NativeTypography.registerFonts()
        NSApp.appearance = NSAppearance(named: .aqua)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Markdown baseline — " + renderer
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(250))
        try foreground()
        var result: [String: Any] = ["renderer": renderer, "sourceBytes": source.utf8.count,
            "baselineFootprintMiB": try footprintMiB(), "backingScale": window.backingScaleFactor,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "captured": captureDirectory != nil]
        var state = State(source)
        for phase in ["cold", "warm"] {
            window.contentView = NSView()
            try await Task.sleep(for: .milliseconds(200))
            state = State(source)
            let start = CACurrentMediaTime(), cpu = cpuSeconds()
            let host = NSHostingView(rootView: Reader(state: state, renderer: renderer))
            host.sizingOptions = []
            window.contentView = host
            try await settle(state)
            result[phase + "MountWallMs"] = (CACurrentMediaTime() - start) * 1000
            result[phase + "MountCPUMs"] = (cpuSeconds() - cpu) * 1000
            result[phase + "Height"] = state.height
        }
        result["mountedFootprintMiB"] = try footprintMiB()
        var views = 0, texts = 0
        func count(_ view: NSView) {
            views += 1
            if view is NSTextView { texts += 1 }
            view.subviews.forEach(count)
        }
        if let root = window.contentView { count(root) }
        result["nativeViews"] = views; result["nativeTextViews"] = texts
        try capture("top")
        let scroll = try scrollView()
        let scrollStart = CACurrentMediaTime(), scrollCPU = cpuSeconds()
        var lateness: [Double] = [], offsets: [Double] = []
        // Fixed cadence and normalized distance make differently styled document
        // heights comparable. Timer lateness is responsiveness, never display FPS.
        for index in 0..<120 {
            let deadline = scrollStart + Double(index) / 60
            let remaining = deadline - CACurrentMediaTime()
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            lateness.append(max(0, CACurrentMediaTime() - deadline) * 1000)
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            let fraction = Double(index % 60) / 59
            let y = maximum * (index < 60 ? fraction : 1 - fraction)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            offsets.append(scroll.contentView.bounds.minY)
        }
        result["scrollWallMs"] = (CACurrentMediaTime() - scrollStart) * 1000
        result["scrollCPUMs"] = (cpuSeconds() - scrollCPU) * 1000
        result["scrollLatenessMs"] = lateness
        result["observedScrollRange"] = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        try foreground()
        if captureDirectory != nil {
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            for (name, fraction) in [("middle", 0.5), ("bottom", 1.0)] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(200))
                try capture(name)
            }
        }
        let resizeCPU = cpuSeconds(), resizeStart = CACurrentMediaTime()
        window.setContentSize(NSSize(width: 500, height: 700))
        try await settle(state)
        result["narrowHeight"] = state.height
        window.setContentSize(NSSize(width: 900, height: 700))
        try await settle(state)
        result["resizeWallMs"] = (CACurrentMediaTime() - resizeStart) * 1000
        result["resizeCPUMs"] = (cpuSeconds() - resizeCPU) * 1000
        result["restoredHeight"] = state.height
        result["finalFootprintMiB"] = try footprintMiB()
        guard abs(state.height - (result["warmHeight"] as! CGFloat)) < 1 else {
            throw Failure(message: "Document height did not recover after resize")
        }
        try foreground()
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
        print("BENCHMARK_COMPLETE " + renderer)
        if ProcessInfo.processInfo.environment["BENCHMARK_HOLD"] == "1" {
            try await Task.sleep(for: .seconds(300))
        }
        window.close()
    }
}

@main private struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
