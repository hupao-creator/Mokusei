import AppKit
import ApplicationServices
import Foundation
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
let screens = NSScreen.screens.map { screen -> [String: Any] in
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    let mode = CGDisplayCopyDisplayMode(id)
    return ["frame": NSStringFromRect(screen.frame), "visibleFrame": NSStringFromRect(screen.visibleFrame), "scale": screen.backingScaleFactor,
            "pixelWidth": mode?.pixelWidth ?? 0, "pixelHeight": mode?.pixelHeight ?? 0, "nominalHzNotFPS": mode?.refreshRate ?? 0]
}
let evidence: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date()),
    "screens": screens, "onConsole": session["kCGSSessionOnConsoleKey"] ?? false,
    "loginDone": session["kCGSessionLoginDoneKey"] ?? false,
    "screenCaptureAlreadyAuthorized": CGPreflightScreenCaptureAccess(), "accessibilityAlreadyAuthorized": AXIsProcessTrusted(),
    "inputIdleSeconds": CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!),
    "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
    "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
    "foregroundBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
print(String(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
