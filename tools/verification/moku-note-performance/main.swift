import AppKit
import Darwin
import Foundation
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiUI
import SwiftUI

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

@MainActor private func descendants(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants)
}

@MainActor private func pump(_ root: NSView, seconds: Double) async throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(8))
    }
}

private let executionURL = "mokusei://execution?threadId=diagnostic-thread&executionId=diagnostic-execution"
private func noteText(links: Int) -> String {
    let prose = "已合入本地 main：保留笔记、正文选择、执行链接与历史入口。正在核对打开时的布局和玻璃合成。"
    return "# Moku Note\n\n" + (0..<max(1, links)).map { index in
        "- \(prose)" + (index < links ? " [整合详情 \(index)](\(executionURL))" : "")
    }.joined(separator: "\n")
}

@main struct NotePerformanceMain {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let detail = CommandLine.arguments.contains("--detail")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if detail { NativePerformance.configure(directory: output.deletingLastPathComponent(), mode: .detailed) }
        var records: [[String: Any]] = []
        // The window is never ordered or activated. No Runtime/profile, provider,
        // pasteboard or global preferences are used by these production controls.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 780),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for count in [0, 1, 12] {
            let note = NativeMokuNote(id: "diagnostic-note", text: noteText(links: count), revision: 1, updatedAt: 1)
            let host = NSHostingView(rootView: NativeMokuNoteContent(note: note, width: 560, height: 640,
                availableHeight: 640, routeEligible: false, openExternal: { _ in },
                openExecution: { _ in }, onContentHeightChange: nil, onExposure: nil))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
            window.contentView = host
            try await pump(host, seconds: 0.4)
            let texts = descendants(host).compactMap { $0 as? MarkdownTextView }
            var elapsed: [Double] = []
            let cpu = cpuSeconds()
            for _ in 0..<30 {
                let start = DispatchTime.now().uptimeNanoseconds
                for text in texts {
                    text.updateExecutionSurfaces()
                    for surface in text.executionSurfaces.values { surface.layoutSubtreeIfNeeded() }
                }
                elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            let tree = descendants(host)
            records.append(["scenario": "unchanged-execution-layout", "links": count,
                "textViews": texts.count, "nativeViews": tree.count,
                "glassViews": tree.filter { String(describing: type(of: $0)).contains("Glass") }.count,
                "hosts": texts.reduce(0) { $0 + $1.executionSurfaces.count },
                "elapsedMs": elapsed, "cpuMs": (cpuSeconds() - cpu) * 1000])
            // Use the same mounted text and real TextKit sizing entry point.
            // SwiftUI's ideal/final proposals must not rebuild width-independent
            // attributed content or force an unchanged capsule back through glass.
            elapsed = []
            let sizingCPU = cpuSeconds()
            for _ in 0..<10 {
                let start = DispatchTime.now().uptimeNanoseconds
                for text in texts {
                    let actual = max(1, text.bounds.width)
                    for width in [actual, actual + 16, actual] { _ = text.measuredHeight(width: width) }
                    text.updateExecutionSurfaces()
                    for surface in text.executionSurfaces.values { surface.layoutSubtreeIfNeeded() }
                }
                elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            records.append(["scenario": "alternate-width-proposals", "links": count,
                "elapsedMs": elapsed, "cpuMs": (cpuSeconds() - sizingCPU) * 1000])
            if count == 1 {
                let text = texts.first { !$0.executionSurfaces.isEmpty }
                let surface = text?.executionSurfaces.values.first
                records.append(["scenario": "interaction-observations", "links": count,
                    "selectable": text?.isSelectable ?? false,
                    "pointerPassesThrough": surface?.hitTest(.zero) == nil,
                    "windowVisible": window.isVisible,
                    "applicationActive": NSApp.isActive,
                    "viewTypes": Dictionary(grouping: tree, by: { String(describing: type(of: $0)) }).mapValues(\.count)])
            }
            window.contentView = nil
        }
        // Exercise the actual shell and its opening/closing state transitions.
        let state = NativeMokuSceneState()
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        let note = NativeMokuNote(id: "diagnostic-dock", text: noteText(links: 1), revision: 1, updatedAt: 1)
        let dock = NSHostingView(rootView: NativeMokuDock(state: state, draft: draft, cwd: "/diagnostic",
            note: note, onSend: { _ in }, onCancel: {}).frame(width: 900, height: 780))
        dock.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        window.contentView = dock
        try await pump(dock, seconds: 0.2)
        for iteration in 0..<4 {
            let start = DispatchTime.now().uptimeNanoseconds
            let cpu = cpuSeconds()
            state.openNotePanelFromUser()
            try await pump(dock, seconds: 0.65)
            let texts = descendants(dock).compactMap { $0 as? MarkdownTextView }
            records.append(["scenario": "dock-open-hidden-window", "iteration": iteration,
                "wallMs": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6,
                "cpuMs": (cpuSeconds() - cpu) * 1000,
                "shellWidth": state.capsuleFrame.width, "shellHeight": state.capsuleFrame.height,
                "textViews": texts.count, "hosts": texts.reduce(0) { $0 + $1.executionSurfaces.count }])
            state.setNotePanelOpen(false)
            try await pump(dock, seconds: 0.5)
        }
        window.contentView = nil
        window.close()
        if detail { NativePerformance.finish() }
        let result: [String: Any] = ["records": records,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "scope": "Windowless production-control CPU/layout observations; excludes WindowServer/GPU/optical FPS"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
}
