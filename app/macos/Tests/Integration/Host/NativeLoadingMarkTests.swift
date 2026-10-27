import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeLoadingMarkTests {
    private func pixels(at time: Double, scheme: ColorScheme) throws -> [UInt8] {
        let renderer = ImageRenderer(content: RuntimeLoadingDrawing(elapsed: time)
            .frame(width: 96, height: 96).environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        if let directory = ProcessInfo.processInfo.environment["MOKUSEI_LOADING_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try png?.write(to: url.appendingPathComponent("\(scheme)-\(time).png"))
        }
        var pixels = [UInt8](repeating: 0, count: 96 * 96 * 4)
        let context = try #require(CGContext(data: &pixels, width: 96, height: 96,
            bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        return pixels
    }

    @Test func historicalDrawingRepeatsWithOutlineFillAndFadeInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let guide = try pixels(at: 0, scheme: scheme)
            let outline = try pixels(at: 0.9, scheme: scheme)
            let filled = try pixels(at: 1.95, scheme: scheme)
            let fading = try pixels(at: 2.65, scheme: scheme)
            func alpha(_ data: [UInt8]) -> Int {
                stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + Int(data[$1]) }
            }
            #expect(alpha(guide) > 0)
            #expect(alpha(outline) > alpha(guide))
            #expect(alpha(filled) > alpha(outline) * 3)
            #expect(alpha(fading) < alpha(filled))
            #expect(try pixels(at: 3, scheme: scheme) == guide)
            // Equivalent floating-point phases can round an antialiased edge
            // by one 8-bit step. Larger visual differences remain failures.
            for time in [4.95, 7.95] {
                let repeated = try pixels(at: time, scheme: scheme)
                #expect(zip(repeated, filled).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
            }
        }
        #expect(try pixels(at: 1.95, scheme: .light) != pixels(at: 1.95, scheme: .dark))
    }

    @Test(.requiresDisplay) func liveSwiftUIClockAdvancesInAWindow() async throws {
        let window = SwiftUIReplay.window(NativeLoadingMark(), width: 96, height: 96)
        defer { window.close() }
        let host = try #require(window.contentView)
        func capture() throws -> Data {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = try capture()
        try await Task.sleep(for: .milliseconds(1700))
        #expect(try capture() != start)
    }
}
