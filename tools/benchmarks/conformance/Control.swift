import AppKit
import SwiftUI

// Exercise the public recognizer used by SwiftUI apps as well as AppKit's raw
// mouse callbacks. A source that only moves an NSView can hide gesture faults.
struct DragControl: View {
    let ledger: Canvas
    @State private var translation = CGSize.zero
    @GestureState private var origin: CGSize?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            ForEach(0..<4) { n in
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(format: "BENCH CARD %02d", n + 1)).font(.system(size: 18))
                    Text("Reviewing the launch settings.\nChecking the response.").font(.system(size: 14))
                }
                .padding(16).frame(width: 250, height: 150, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
                .offset(x: 160 + CGFloat(n % 2) * 290 + translation.width,
                        y: 100 + CGFloat(n / 2) * 190 + translation.height)
            }
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 4)
            .updating($origin) { _, value, _ in if value == nil { value = translation } }
            .onChanged { value in
                guard let origin else { return }
                translation = CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height)
                ledger.record(["kind": "gesture", "atNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                               "x": translation.width, "y": translation.height,
                               "startX": value.startLocation.x, "startY": value.startLocation.y,
                               "locationX": value.location.x, "locationY": value.location.y])
            })
    }
}

// A separate physical control, never linked into the product. Faults affect
// the real main thread or drawn business content, not collector observations.
final class Canvas: NSView {
    let mode: String
    let gate: String
    var dx: CGFloat = 0, dy: CGFloat = 0
    var origin = CGPoint.zero
    var starting = CGPoint.zero
    var tick = 0
    var stalled = false
    init(mode: String, gate: String) { self.mode = mode; self.gate = gate; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func record(_ event: [String: Any]) {
        guard gate != "/nonexistent-control-gate", let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        let path = gate + "-events.jsonl"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let file = FileHandle(forWritingAtPath: path) {
            file.seekToEndOfFile(); file.write(data); file.write(Data("\n".utf8)); try? file.close()
        }
    }
    func advance() {
        tick += 1
        if mode == "children", tick % 20 == 0 {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            do {
                try child.run(); let pid = child.processIdentifier; child.waitUntilExit()
                record(["kind": "childExit", "pid": pid, "atNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW), "exitStatus": child.terminationStatus])
            } catch { record(["kind": "childError", "error": String(describing: error)]) }
        }
        if mode == "stall", !stalled, FileManager.default.fileExists(atPath: gate) {
            stalled = true
            record(["kind": "stallBegin", "atNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW)])
            Thread.sleep(forTimeInterval: 1.2)
            record(["kind": "stallEnd", "atNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW)])
        }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        starting = CGPoint(x: dx, y: dy)
        if mode == "delay" { Thread.sleep(forTimeInterval: 1.1) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard mode != "frozen" else { return }
        let p = convert(event.locationInWindow, from: nil)
        let direction: CGFloat = mode == "wrong" ? -1 : 1
        dx = starting.x + direction * (p.x - origin.x)
        dy = starting.y + direction * (p.y - origin.y)
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard mode != "frozen" else { return }
        dx += event.scrollingDeltaY
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        for n in 0..<4 {
            let x = 160 + CGFloat(n % 2) * 290 + dx
            let y = 100 + CGFloat(n / 2) * 190 + dy
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 250, height: 150), xRadius: 10, yRadius: 10).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor]
            (String(format: "BENCH CARD %02d", n + 1) as NSString).draw(at: CGPoint(x: x + 16, y: y + 20), withAttributes: attributes)
            ("Reviewing the launch settings.\nChecking the response." as NSString).draw(at: CGPoint(x: x + 16, y: y + 57), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
            if mode == "normal" || mode == "stall" {
                NSColor.systemGreen.setFill()
                let progress = CGFloat(tick % 120) / 120
                NSRect(x: x + 16, y: y + 118, width: 210 * progress, height: 5).fill()
            }
        }
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let mode = args.count > 1 ? args[1] : "normal"
        let gate = args.count > 2 ? args[2] : "/nonexistent-control-gate"
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Benchmark Collector Control"
        let canvas = Canvas(mode: mode, gate: gate)
        if mode == "swiftui" {
            window.contentView = NSHostingView(rootView: DragControl(ledger: canvas))
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                canvas.record(["kind": "mouse", "type": event.type.rawValue, "atNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                               "x": event.locationInWindow.x, "y": event.locationInWindow.y,
                               "deltaX": event.deltaX, "deltaY": event.deltaY])
                return event
            }
        } else { window.contentView = canvas }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if mode != "swiftui" { timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in canvas.advance() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
