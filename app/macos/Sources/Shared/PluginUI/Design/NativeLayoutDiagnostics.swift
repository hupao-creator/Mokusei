import AppKit
import SwiftUI

/// Dev-only, process-local geometry diagnostics. Never inspect text, accessibility
/// labels/identifiers, window titles, URLs, model IDs or represented objects here.
@MainActor
public enum NativeLayoutDiagnostics {
    private static var observer: LayoutWindowObserver?
    private static var writer: NativeLayoutLogWriter?
    public static var isEnabled: Bool { writer != nil }

    /// A Release build of the dev channel is still a dev application. Conversely,
    /// DEBUG alone must never enable recording in a production bundle/profile.
    public static func start(directory: URL, explicitDataDirectory: Bool = false) {
        guard writer == nil, ProcessInfo.processInfo.environment["MOKUSEI_LAYOUT_LOG"] != "0" else { return }
        var development = Bundle.main.bundleIdentifier == "com.mokusei.native.dev"
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app", explicitDataDirectory,
           ProcessInfo.processInfo.environment["MOKUSEI_LAYOUT_LOG"] == "1" { development = true }
        #endif
        guard development else { return }
        let writer = NativeLayoutLogWriter(directory: directory)
        self.writer = writer
        FileHandle.standardError.write(Data("[layout-log] \(writer.directory.path)/events-*.jsonl\n".utf8))
        observer = LayoutWindowObserver()
        observer?.start()
    }

    public static func finish() {
        observer?.stop(); observer = nil
        writer?.finish(); writer = nil
    }

    fileprivate static func record(kind: String, source: String, component: String, role: String,
                                   window: String? = nil, parent: String? = nil, sibling: Int? = nil,
                                   flipped: Bool? = nil, before: NativeLayoutGeometry?, after: NativeLayoutGeometry?) {
        writer?.append(NativeLayoutRecord(time: Date(), uptimeNs: DispatchTime.now().uptimeNanoseconds,
            kind: kind, source: source, component: component, role: role,
            window: window, parent: parent, sibling: sibling, flipped: flipped, before: before, after: after))
    }
}

@MainActor
private final class LayoutWindowObserver {
    @MainActor private final class WindowEntry {
        weak var window: NSWindow?
        let id: String
        var geometry: NativeLayoutGeometry?
        init(_ window: NSWindow, id: String) { self.window = window; self.id = id }
    }
    @MainActor private final class ViewEntry {
        weak var view: NSView?
        let id: String
        let role: String
        let postedFrame: Bool
        let postedBounds: Bool
        var geometry: NativeLayoutGeometry?
        var window: String = ""
        var parent: String = ""
        var sibling = 0
        init(_ view: NSView, id: String) {
            self.view = view; self.id = id
            // Class names describe implementation, never user-controlled values.
            role = String(NSStringFromClass(type(of: view)).prefix(160))
            postedFrame = view.postsFrameChangedNotifications
            postedBounds = view.postsBoundsChangedNotifications
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
        }
        func restore() {
            view?.postsFrameChangedNotifications = postedFrame
            view?.postsBoundsChangedNotifications = postedBounds
        }
    }
    private var windows: [ObjectIdentifier: WindowEntry] = [:]
    private var views: [ObjectIdentifier: ViewEntry] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var sequence = 0
    private var scanning = false
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()

    func start() {
        observe(NSApplication.didUpdateNotification) { [weak self] _, _ in self?.scan() }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didUpdateNotification] {
            observe(name) { [weak self] window, _ in
                guard let self, let window else { return }
                guard !self.closedWindows.contains(window) else { return }
                self.sampleWindow(window, source: name.rawValue)
            }
        }
        observe(NSWindow.willCloseNotification) { [weak self] window, _ in
            guard let self, let window else { return }
            self.removeWindow(window)
        }
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            observe(name) { [weak self] _, view in
                guard let self, let view,
                      let entry = self.views[ObjectIdentifier(view)] else { return }
                self.sampleView(view, entry: entry, source: name.rawValue)
            }
        }
        scan()
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor @Sendable (NSWindow?, NSView?) -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            // Extract only actor-isolated AppKit objects; Notification.userInfo can
            // contain non-Sendable data and must not cross this isolation boundary.
            let window = note.object as? NSWindow
            let view = note.object as? NSView
            MainActor.assumeIsolated { action(window, view) }
        })
    }

    private func nextID(_ prefix: String) -> String { sequence += 1; return "\(prefix)\(sequence)" }

    @discardableResult
    private func sampleWindow(_ window: NSWindow, source: String) -> WindowEntry {
        let key = ObjectIdentifier(window)
        let entry: WindowEntry
        if let existing = windows[key], existing.window === window { entry = existing }
        else { entry = WindowEntry(window, id: nextID("w")); windows[key] = entry }
        let geometry = NativeLayoutGeometry(frame: window.frame, bounds: window.contentLayoutRect)
        if entry.geometry != geometry {
            NativeLayoutDiagnostics.record(kind: entry.geometry == nil ? "initial" : "change", source: source,
                component: entry.id, role: "NSWindow", window: entry.id,
                before: entry.geometry, after: geometry)
            entry.geometry = geometry
        }
        return entry
    }

    private func sampleView(_ view: NSView, entry: ViewEntry, source: String, reparented: Bool = false) {
        let geometry = NativeLayoutGeometry(frame: view.frame, bounds: view.bounds)
        guard geometry != entry.geometry || reparented else { return }
        NativeLayoutDiagnostics.record(kind: entry.geometry == nil ? "initial" : reparented ? "reparent" : "change",
            source: source, component: entry.id, role: entry.role, window: entry.window,
            parent: entry.parent, sibling: entry.sibling, flipped: view.isFlipped,
            before: entry.geometry, after: geometry)
        entry.geometry = geometry
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        var seen = Set<ObjectIdentifier>()
        // Discovery observes the existing tree after application updates. It never
        // forces layout, changes responders/hit regions, or samples presentation layers.
        for window in NSApplication.shared.windows {
            if closedWindows.contains(window) {
                guard window.isVisible else { continue }
                closedWindows.remove(window)
            }
            let owner = sampleWindow(window, source: "appkit.discovery")
            guard let content = window.contentView else { continue }
            var root = content
            while let parent = root.superview { root = parent }
            var stack: [(NSView, String, Int)] = [(root, owner.id, 0)]
            while let (view, parent, sibling) = stack.popLast() {
                let key = ObjectIdentifier(view)
                seen.insert(key)
                let entry: ViewEntry
                if let existing = views[key], existing.view === view { entry = existing }
                else { entry = ViewEntry(view, id: nextID("v")); views[key] = entry }
                let reparented = entry.window != owner.id || entry.parent != parent || entry.sibling != sibling
                entry.window = owner.id; entry.parent = parent; entry.sibling = sibling
                sampleView(view, entry: entry, source: "appkit.discovery", reparented: reparented)
                for (index, child) in view.subviews.enumerated().reversed() { stack.append((child, entry.id, index)) }
            }
        }
        for key in Array(views.keys) where !seen.contains(key) {
            if let entry = views.removeValue(forKey: key) { removeView(entry) }
        }
        for key in Array(windows.keys) where windows[key]?.window == nil { windows[key] = nil }
    }

    private func removeView(_ entry: ViewEntry) {
        entry.restore()
        NativeLayoutDiagnostics.record(kind: "removed", source: "appkit.discovery", component: entry.id,
            role: entry.role, window: entry.window, parent: entry.parent,
            before: entry.geometry, after: nil)
    }

    private func removeWindow(_ window: NSWindow) {
        closedWindows.add(window)
        guard let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        for key in Array(views.keys) where views[key]?.window == entry.id {
            if let view = views.removeValue(forKey: key) { removeView(view) }
        }
        NativeLayoutDiagnostics.record(kind: "removed", source: "NSWindowWillCloseNotification",
            component: entry.id, role: "NSWindow", window: entry.id, before: entry.geometry, after: nil)
    }

    func stop() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens.removeAll()
        views.values.forEach { $0.restore() }; views.removeAll(); windows.removeAll()
    }
}

public extension View {
    /// Use a code-owned literal role, never a title, Thread ID or other model data.
    /// Geometry callbacks describe resolved SwiftUI geometry, not all layout passes.
    @ViewBuilder
    func nativeLayoutLog(_ role: StaticString, file: StaticString = #fileID, line: UInt = #line) -> some View {
        if NativeLayoutDiagnostics.isEnabled {
            modifier(LayoutGeometryLog(role: "\(role)", location: "\(file):\(line)"))
        } else { self }
    }
}

private extension EnvironmentValues {
    @Entry var nativeLayoutLogParent: String? = nil
}

@MainActor
private final class SwiftUILayoutObservation {
    let id = "s-\(UUID().uuidString)"
    var geometry: NativeLayoutGeometry?

    func update(_ next: NativeLayoutGeometry, role: String, location: String, parent: String?) {
        guard next != geometry else { return }
        NativeLayoutDiagnostics.record(kind: geometry == nil ? "initial" : "change", source: "swiftui.geometry",
            component: id, role: "\(role)@\(location)", parent: parent, before: geometry, after: next)
        geometry = next
    }

    func visibility(_ appeared: Bool, role: String, location: String, parent: String?) {
        // SwiftUI can retain an offscreen view without another geometry callback
        // on return. Preserve its measured baseline; never relabel a cached frame
        // as a freshly measured initial layout in onAppear.
        NativeLayoutDiagnostics.record(kind: appeared ? "appeared" : "disappeared",
            source: appeared ? "swiftui.appear" : "swiftui.disappear",
            component: id, role: "\(role)@\(location)", parent: parent, before: nil, after: nil)
    }
}

private struct LayoutGeometryLog: ViewModifier {
    let role: String
    let location: String
    // Reference state is not observable: recording does not invalidate the product
    // body or introduce another geometry -> layout feedback loop.
    @State private var observation = SwiftUILayoutObservation()
    @Environment(\.nativeLayoutLogParent) private var parent

    func body(content: Content) -> some View {
        content.environment(\.nativeLayoutLogParent, observation.id)
        .onGeometryChange(for: NativeLayoutGeometry.self) { proxy in
            NativeLayoutGeometry(frame: proxy.frame(in: .global), bounds: CGRect(origin: .zero, size: proxy.size))
        } action: { geometry in
            observation.update(geometry, role: role, location: location, parent: parent)
        }
        .onAppear { observation.visibility(true, role: role, location: location, parent: parent) }
        .onDisappear { observation.visibility(false, role: role, location: location, parent: parent) }
    }
}
