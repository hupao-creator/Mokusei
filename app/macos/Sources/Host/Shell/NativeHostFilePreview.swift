import Foundation
import MokuseiCore
import MokuseiPluginAPI
import AppKit
import Quartz

/// Files enter native preview only after an authenticated download passes its
/// host checksum. Quick Look supplies Save to Files and the system share sheet.
@MainActor
enum NativeHostFilePreview {
    static func present(_ file: RuntimeDownloadedFile, lifetime: PluginLifetime? = nil) throws {
        try lifetime?.checkCancellation()
        try HostQuickLookWindow.present(file, lifetime: lifetime)
    }
}

/// Preview remains a read-only Quick Look operation on the Mac as well. In
/// particular a downloaded executable must not be opened in its default app.
@MainActor
private final class HostQuickLookWindow: NSObject, NSWindowDelegate {
    private static var open: [UUID: HostQuickLookWindow] = [:]
    private let id = UUID()
    private let file: RuntimeDownloadedFile
    private let window: NSWindow
    private let preview: QLPreviewView
    private weak var lifetime: PluginLifetime?
    private var lifetimeID: UUID?

    static func present(_ file: RuntimeDownloadedFile, lifetime: PluginLifetime?) throws {
        let owner = try HostQuickLookWindow(file: file, lifetime: lifetime)
        open[owner.id] = owner
        owner.window.center(); owner.window.makeKeyAndOrderFront(nil)
    }
    init(file: RuntimeDownloadedFile, lifetime: PluginLifetime?) throws {
        self.file = file; self.lifetime = lifetime
        let frame = CGRect(x: 0, y: 0, width: 720, height: 540)
        guard let preview = QLPreviewView(frame: frame, style: .normal) else { throw PluginContractError("无法预览文件") }
        self.preview = preview
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false; window.title = file.name
        preview.autostarts = false; preview.shouldCloseWithWindow = false
        preview.previewItem = file.url as NSURL
        window.contentView = preview; window.delegate = self
        lifetimeID = lifetime?.onCancel { [weak self] in self?.window.close() }
    }
    func windowWillClose(_ notification: Notification) {
        preview.close()
        if let lifetimeID { lifetime?.removeHandler(lifetimeID); self.lifetimeID = nil }
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        Self.open[id] = nil
    }
}
