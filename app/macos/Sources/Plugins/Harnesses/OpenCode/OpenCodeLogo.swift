import SwiftUI
import MokuseiPluginUI

/// Original official OpenCode SVG paths, with its surface-dependent colors.
public struct OpenCodeLogo: View {
    /// The approved running-card palette belongs to this harness.
    public static let threadCardCloudPalette = NativeCloudPalette(channels: [
        .init(color: NativePalette.pair(0x969898, 0xe7e4df).swiftUI, seed: 136, energy: 0.42),
        .init(color: NativePalette.pair(0x62676e, 0xa6acb4).swiftUI, seed: 73, energy: 0.31),
        .init(color: NativePalette.pair(0xc3beb6, 0xcfcecd).swiftUI, seed: 211, energy: 0.34)
    ], phase: 6.4)

    public let size: CGFloat
    public init(size: CGFloat = 24) { self.size = size }
    public var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 240, geometry.size.height / 300)
            ZStack {
                Path { p in p.addRect(CGRect(x: 60 * scale, y: 120 * scale, width: 120 * scale, height: 120 * scale)) }
                    .fill(NativePalette.pair(0xcfcecd, 0x4b4646).swiftUI)
                Path { p in
                    p.move(to: CGPoint(x: 180 * scale, y: 60 * scale)); p.addLine(to: CGPoint(x: 60 * scale, y: 60 * scale))
                    p.addLine(to: CGPoint(x: 60 * scale, y: 240 * scale)); p.addLine(to: CGPoint(x: 180 * scale, y: 240 * scale)); p.closeSubpath()
                    p.addRect(CGRect(x: 0, y: 0, width: 240 * scale, height: 300 * scale))
                }.fill(NativePalette.pair(0x211e1e, 0xf1ecec).swiftUI, style: FillStyle(eoFill: true))
            }.frame(width: 240 * scale, height: 300 * scale).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.frame(width: size, height: size).accessibilityLabel("OpenCode")
    }
    public static let source = "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQwIiBoZWlnaHQ9IjMwMCIgdmlld0JveD0iMCAwIDI0MCAzMDAiIGZpbGw9Im5vbmUiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjwhLS0gT2ZmaWNpYWwgT3BlbkNvZGUgYnJhbmQgYXNzZXQ6IGh0dHBzOi8vb3BlbmNvZGUuYWkvYnJhbmQgKDIwMjYtMTAtMDgpLgogICAgIE9yaWdpbmFsIHBhdGhzIHJldGFpbmVkOyB0aGVtZSBjb2xvcnMgZm9sbG93IHRoZSBlbWJlZGRpbmcgc3VyZmFjZS4gLS0+CjxzdHlsZT4ub3BlbmNvZGUtc2hlbGx7ZmlsbDojMjExRTFFfS5vcGVuY29kZS1zY3JlZW57ZmlsbDojQ0ZDRUNEfUBtZWRpYShwcmVmZXJzLWNvbG9yLXNjaGVtZTpkYXJrKXsub3BlbmNvZGUtc2hlbGx7ZmlsbDojRjFFQ0VDfS5vcGVuY29kZS1zY3JlZW57ZmlsbDojNEI0NjQ2fX08L3N0eWxlPgo8ZyBjbGlwLXBhdGg9InVybCgjY2xpcDBfMTQwMV84NjI3NCkiPgo8bWFzayBpZD0ibWFzazBfMTQwMV84NjI3NCIgc3R5bGU9Im1hc2stdHlwZTpsdW1pbmFuY2UiIG1hc2tVbml0cz0idXNlclNwYWNlT25Vc2UiIHg9IjAiIHk9IjAiIHdpZHRoPSIyNDAiIGhlaWdodD0iMzAwIj4KPHBhdGggZD0iTTI0MCAwSDBWMzAwSDI0MFYwWiIgZmlsbD0id2hpdGUiLz4KPC9tYXNrPgo8ZyBtYXNrPSJ1cmwoI21hc2swXzE0MDFfODYyNzQpIj4KPHBhdGggY2xhc3M9Im9wZW5jb2RlLXNjcmVlbiIgZD0iTTE4MCAyNDBINjBWMTIwSDE4MFYyNDBaIiBmaWxsPSIjQ0ZDRUNEIi8+CjxwYXRoIGNsYXNzPSJvcGVuY29kZS1zaGVsbCIgZD0iTTE4MCA2MEg2MFYyNDBIMTgwVjYwWk0yNDAgMzAwSDBWMEgyNDBWMzAwWiIgZmlsbD0iIzIxMUUxRSIvPgo8L2c+CjwvZz4KPGRlZnM+CjxjbGlwUGF0aCBpZD0iY2xpcDBfMTQwMV84NjI3NCI+CjxyZWN0IHdpZHRoPSIyNDAiIGhlaWdodD0iMzAwIiBmaWxsPSJ3aGl0ZSIvPgo8L2NsaXBQYXRoPgo8L2RlZnM+Cjwvc3ZnPgo="
}
