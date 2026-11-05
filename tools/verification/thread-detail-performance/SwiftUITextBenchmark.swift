import AppKit
import Darwin
import SwiftUI
@testable import MokuseiPluginUI

private struct BenchmarkFailure: Error { let message: String }

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func footprintMiB() throws -> Double {
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw BenchmarkFailure(message: "TASK_VM_INFO failed") }
    return Double(vm.phys_footprint) / 1_048_576
}

@MainActor private final class Geometry {
    var height: CGFloat = 0
}

@MainActor private struct Reader: View {
    let blocks: [MarkdownBlock]
    let swiftUI: Bool
    let reveal: NativeThreadContentReveal?
    let geometry: Geometry
    let actions: MarkdownViewActions
    let anchorPrefix = UUID().uuidString
    var body: some View {
        ScrollView {
            MarkdownContent(blocks: blocks, options: MarkdownViewOptions(fontSize: 16, muted: false,
                openLink: actions.open, resolveMedia: nil, anchorPrefix: anchorPrefix, actions: actions))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { geometry.height = $0 }
                .padding(20)
        }
        .environment(\.nativeMarkdownUsesSwiftUIText, swiftUI)
        .environment(\.nativeThreadReveal, reveal)
        .background(NativePalette.thread.canvas.swiftUI)
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); exit(0) }
            catch { print("BENCHMARK_ERROR \(error)"); exit(1) }
        }
    }

    private func settle(_ window: NSWindow, geometry: Geometry) async throws {
        var stable = 0
        var previous: CGFloat = -1
        let deadline = CACurrentMediaTime() + 15
        while CACurrentMediaTime() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if geometry.height > 0 && abs(geometry.height - previous) < 0.1 { stable += 1 } else { stable = 0 }
            previous = geometry.height
            if stable == 4 { return }
            try await Task.sleep(for: .milliseconds(16))
        }
        throw BenchmarkFailure(message: "layout did not settle")
    }

    private func run() async throws {
        let swiftUI = CommandLine.arguments.contains("--swiftui")
        let scoped = CommandLine.arguments.contains("--thread-scope")
        let mixed = CommandLine.arguments.contains("--mixed")
        let prose = "A paragraph with **strong text**, `inline code`, a [link](https://example.com), and 中文阅读。 "
        let source: String
        if mixed {
            source = (0..<40).map { index in
                "## Section \(index)\n\n" + String(repeating: prose, count: 3)
                + "\n\n- First list item\n- Second list item with a longer sentence that can wrap\n\n"
                + "| Name | Status | Notes |\n|---|---|---|\n| Alpha | Ready | A moderately long cell that wraps at narrow widths |\n| Beta | | 中文🙂 |\n\n"
                + "```swift\nlet value = \(index)\nprint(value)\n```"
            }.joined(separator: "\n\n")
        } else {
            source = (0..<160).map { "Paragraph \($0). " + String(repeating: prose, count: 4) }.joined(separator: "\n\n")
        }
        // Compare the actual renderers with identical parsed blocks. Transport,
        // parsing, page admission and entrance animation are outside this probe.
        let document = try await NativeMarkdownParser.shared.parse(source)
        let reveal = scoped ? NativeThreadContentReveal() : nil
        reveal?.begin(bottomUp: false, reducedMotion: true)
        try await Task.sleep(for: .milliseconds(80))
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
        guard NSApp.isActive, window.isKeyWindow, window.occlusionState.contains(.visible) else {
            throw BenchmarkFailure(message: "foreground visible window required")
        }
        var result: [String: Any] = ["renderer": swiftUI ? "swiftui" : "appkit",
            "scope": scoped ? "thread" : "plain", "fixture": mixed ? "mixed" : "prose",
            "sourceBytes": source.utf8.count, "blocks": document.blocks.count,
            "baselineFootprintMiB": try footprintMiB()]
        var latestGeometry = Geometry()
        for phase in ["cold", "warm"] {
            window.contentView = NSView()
            try await Task.sleep(for: .milliseconds(100))
            latestGeometry = Geometry()
            let startCPU = cpuSeconds(), start = CACurrentMediaTime()
            let actions = MarkdownViewActions()
            actions.openLink = { _ in }
            let host = NSHostingView(rootView: Reader(blocks: document.blocks, swiftUI: swiftUI,
                                                     reveal: reveal, geometry: latestGeometry, actions: actions))
            host.sizingOptions = []
            window.contentView = host
            try await settle(window, geometry: latestGeometry)
            result[phase + "MountWallMs"] = (CACurrentMediaTime() - start) * 1000
            result[phase + "MountCPUMs"] = (cpuSeconds() - startCPU) * 1000
        }
        result["mountedFootprintMiB"] = try footprintMiB()
        result["wideHeight"] = latestGeometry.height
        let resizeCPU = cpuSeconds(), resizeStart = CACurrentMediaTime()
        window.setContentSize(NSSize(width: 500, height: 700))
        try await settle(window, geometry: latestGeometry)
        result["narrowHeight"] = latestGeometry.height
        window.setContentSize(NSSize(width: 900, height: 700))
        try await settle(window, geometry: latestGeometry)
        result["resizeWallMs"] = (CACurrentMediaTime() - resizeStart) * 1000
        result["resizeCPUMs"] = (cpuSeconds() - resizeCPU) * 1000
        var views = 0, texts = 0, rows = 0
        func count(_ view: NSView) {
            views += 1
            if view is MarkdownTextView { texts += 1 }
            if view is ThreadRevealRowView { rows += 1 }
            view.subviews.forEach(count)
        }
        if let root = window.contentView { count(root) }
        result["nativeViews"] = views
        result["markdownTextViews"] = texts
        result["revealRowHosts"] = rows
        guard NSApp.isActive, window.isKeyWindow, window.occlusionState.contains(.visible) else {
            throw BenchmarkFailure(message: "foreground lost during sample")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("BENCHMARK_JSON " + String(decoding: data, as: UTF8.self))
        window.close()
    }
}

@main private struct Main {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
