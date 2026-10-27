import Observation
import SwiftUI

@MainActor @Observable
public final class NativeThemeTransitionController {
    public private(set) var isActive = false
    public init() {}
    public func perform(appearance: DesktopAppearance, apply: () throws -> Void) throws {
        try withAnimation(.easeInOut(duration: 0.25), apply)
    }
    public func cancel() { isActive = false }
}

public struct NativeThemeTransitionHost<Content: View>: View {
    public let controller: NativeThemeTransitionController
    public let enabled: Bool
    private let content: Content
    public init(controller: NativeThemeTransitionController, enabled: Bool = true, @ViewBuilder content: () -> Content) {
        self.controller = controller; self.enabled = enabled; self.content = content()
    }
    public var body: some View { content }
}
