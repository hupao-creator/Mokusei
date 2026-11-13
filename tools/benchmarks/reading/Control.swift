import AppKit
import Foundation

private final class Document: NSView {
    let anchors: [String]
    override var isFlipped: Bool { true }

    init(anchors: [String]) {
        self.anchors = anchors
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: CGFloat(anchors.count) * 145 + 300))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for (index, anchor) in anchors.enumerated() {
            let y = CGFloat(index) * 145 + 60
            guard dirtyRect.intersects(NSRect(x: 0, y: y, width: bounds.width, height: 120)) else { continue }
            (anchor as NSString).draw(at: NSPoint(x: 65, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: 23, weight: .medium), .foregroundColor: NSColor.black])
            ("A completed observation remains readable as this document scrolls." as NSString)
                .draw(at: NSPoint(x: 65, y: y + 40), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.darkGray])
        }
    }
}

private final class ScrollControl: NSScrollView {
    var mode = "normal"
    var eventCount = 0
    var evidence: URL?
    private var receivedPixels: CGFloat = 0
    private var receivedEvents = 0
    private var gestureStart: CGFloat = 0

    private func record(_ kind: String) {
        guard let evidence,
              let data = try? JSONSerialization.data(withJSONObject: ["kind": kind,
                  "atNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW)]) else { return }
        if !FileManager.default.fileExists(atPath: evidence.path) {
            _ = FileManager.default.createFile(atPath: evidence.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: evidence) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }

    override func scrollWheel(with event: NSEvent) {
        eventCount += 1
        if event.phase.contains(.began) {
            receivedPixels = 0; receivedEvents = 0; gestureStart = contentView.bounds.minY
        }
        receivedPixels += event.scrollingDeltaY
        receivedEvents += 1
        if event.phase.contains(.ended), let evidence {
            let pixels = receivedPixels, count = receivedEvents, start = gestureStart
            let ending = event.scrollingDeltaY
            // The independent control exposes its own receiver/geometry truth
            // after the quiet settling interval; product measurements stay optical.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                let value: [String: Any] = ["receivedPixels": pixels, "receivedEvents": count,
                    "endingPixels": ending, "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
                    "startTop": start, "settledTop": self.contentView.bounds.minY,
                    "atNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW)]
                let path = evidence.deletingLastPathComponent().appendingPathComponent("received-scroll.jsonl")
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
                if !FileManager.default.fileExists(atPath: path.path) { _ = FileManager.default.createFile(atPath: path.path, contents: nil) }
                guard let handle = try? FileHandle(forWritingTo: path) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data([10]))
            }
        }
        if mode == "frozen" { return }
        if mode == "stall", eventCount == 15 {
            record("stall-start")
            Thread.sleep(forTimeInterval: 1.2)
            record("stall-end")
        }
        if mode == "wrong" {
            // Make the control's actual document travel backwards. Rewriting
            // legacy CGEvent fields can leave NSEvent's precise delta intact.
            let maximum = max(0, (documentView?.bounds.height ?? 0) - contentView.bounds.height)
            let top = min(maximum, max(0, contentView.bounds.minY + event.scrollingDeltaY))
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: top))
            reflectScrolledClipView(contentView)
            return
        }
        if mode == "delay" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.apply(event) }
            return
        }
        super.scrollWheel(with: event)
    }

    private func apply(_ event: NSEvent) { super.scrollWheel(with: event) }
}

private final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3, ["normal", "frozen", "wrong", "delay", "stall"].contains(args[0]) else {
                throw NSError(domain: "ReadingControl", code: 1)
            }
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as? [String: Any]
            guard let anchors = value?["anchors"] as? [String], !anchors.isEmpty else {
                throw NSError(domain: "ReadingControl", code: 2)
            }
            let window = NSWindow(contentRect: NSRect(x: 50, y: 60, width: 1200, height: 800),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Independent reading scroll control"
            let scroll = ScrollControl(frame: window.contentView?.bounds ?? .zero)
            scroll.autoresizingMask = [.width, .height]
            scroll.mode = args[0]
            scroll.evidence = URL(fileURLWithPath: args[2])
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = true
            scroll.backgroundColor = .white
            scroll.documentView = Document(anchors: anchors)
            window.contentView = scroll
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } catch {
            fputs("reading control preparation failed: \(error)\n", stderr)
            exit(1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private struct Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
