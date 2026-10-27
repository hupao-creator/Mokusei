import SwiftUI
import AppKit
public typealias NativePlatformColor = NSColor
public typealias NativePlatformFont = NSFont
public typealias NativePlatformImage = NSImage
public typealias NativePlatformScreen = NSScreen
public typealias NativePlatformView = NSView
public typealias NativePlatformWindow = NSWindow
public extension NSColor { var swiftUI: Color { Color(nsColor: self) } }
public extension NSImage { var swiftUI: Image { Image(nsImage: self) } }
