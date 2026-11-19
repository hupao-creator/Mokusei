import AppKit
import Foundation
import SwiftUI

struct PropertyFailure: Error { let message: String; init(_ message: String) { self.message = message } }

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func integer(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }
}

struct PropertyBudget {
    let seed: UInt64
    let cases: Int
    let shrinkSeconds: Int
    init(defaultCases: Int) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let seed = UInt64(environment["MOKUSEI_PBT_SEED"] ?? "1"),
              let cases = Int(environment["MOKUSEI_PBT_CASES"] ?? String(defaultCases)),
              let shrinkSeconds = Int(environment["MOKUSEI_PBT_SHRINK_SECONDS"] ?? "30"),
              shrinkSeconds > 0, (1...10000).contains(cases) else { throw PropertyFailure("invalid PBT seed/cases/shrink budget") }
        self.seed = seed
        self.cases = cases
        self.shrinkSeconds = shrinkSeconds
    }
}

func propertyReplay<T: Decodable>(_ type: T.Type) throws -> T? {
    guard let path = ProcessInfo.processInfo.environment["MOKUSEI_PBT_REPLAY"] else { return nil }
    return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func propertyEvidence<T: Encodable>(_ value: T, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["MOKUSEI_PBT_EVIDENCE"] else { return }
    try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: path).appendingPathComponent(name), options: .atomic)
}

// Minimal window/wait support extracted from historical SwiftUIReplaySupport.
// No AX/input fixtures or non-property test methods are restored.
@MainActor enum SwiftUIReplay {
    static func window<Content: View>(_ content: Content, width: CGFloat, height: CGFloat) -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: width, height: height))
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }
    static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            for window in NSApp?.windows ?? [] {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PropertyFailure("presentation did not settle in 3s")
    }
}
