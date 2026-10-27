import MokuseiPluginUI
import Foundation
import SwiftUI

public extension EnvironmentValues {
    @Entry var nativeWindowContentScale: CGFloat = 1
}

public extension Scene {
    @SceneBuilder
    func nativeWorkspaceWindowStyle() -> some Scene {
        windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unified(showsTitle: false))
    }
}

/// The material belongs to the window so it samples the desktop behind it.
/// A transparent toolbar gives the real system controls room without a header.
/// Keep the toolbar empty: even a clear placeholder creates a titlebar hit
/// region over the content-hosted back button.
public struct NativeWorkspaceWindowSurface: ViewModifier {
    public init() {}
    @ViewBuilder
    public func body(content: Content) -> some View {
        content
            .background(NativeWindowControlPlacement().allowsHitTesting(false).accessibilityHidden(true))
            .ignoresSafeArea()
            .containerBackground(.ultraThinMaterial, for: .window)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .windowToolbarFullScreenVisibility(.visible)
    }
}

/// Historical full-window coordinates, shared by the SwiftUI capsule and the
/// narrow AppKit bridge that positions the real system controls.
public enum NativeWindowNavigationGeometry {
    public static let left: CGFloat = 12
    public static let top: CGFloat = 16
    public static let height: CGFloat = 42
    public static let openWidth: CGFloat = 132
    public static let closedWidth: CGFloat = 88
    public static let nativeButtonLeft: CGFloat = 24
    public static let nativeButtonTop: CGFloat = 31
    public static let shadowInset: CGFloat = 8
    public static let safeAreaTop: CGFloat = 74
    public static let safeAreaLeft: CGFloat = 160
    public static let dragHeight: CGFloat = 14
    public static let hiddenOffset: CGFloat = -66
    public static let hideAfter = NativeReadingNavigationState.hideAfter
    public static let showWithin = NativeReadingNavigationState.showWithin
}

@MainActor
enum NativeWindowNavigationPresentation {
    // NavigationMotionController before the SwiftUI shell migration (310149f1d).
    static let expansionDuration: TimeInterval = 0.7
    static let expansionAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: expansionDuration)
    static let scrollDuration: CFTimeInterval = 0.22

    static func scrollOffset(from: CGFloat, to: CGFloat, elapsed: CFTimeInterval) -> CGFloat {
        let progress = min(1, max(0, elapsed / scrollDuration))
        return progress >= 1 ? to : (from + (to - from) * (1 - pow(1 - progress, 3))).rounded()
    }

}

public struct NativeWindowNavigationView: View {
    public let action: ThreadDetailBackAction?
    public let hidden: Bool
    public let suspended: Bool
    public let managesNativeButtons: Bool
    public let compact: Bool
    public let reading: NativeReadingNavigationState?
    public let onRevealChange: ((Bool) -> Void)?
    public let onBackFrameChange: ((CGRect) -> Void)?
    private let backFocus: FocusState<Bool>.Binding?
    @FocusState private var unmanagedBackFocus: Bool
    @Environment(\.locale) private var locale
    @Environment(\.nativeWindowContentScale) private var contentScale
    public init(action: ThreadDetailBackAction?, hidden: Bool = false, suspended: Bool = false,
                managesNativeButtons: Bool = true, compact: Bool = false, reading: NativeReadingNavigationState? = nil,
                onRevealChange: ((Bool) -> Void)? = nil,
                backFocus: FocusState<Bool>.Binding? = nil, onBackFrameChange: ((CGRect) -> Void)? = nil) {
        self.action = action; self.hidden = hidden; self.suspended = suspended; self.compact = compact
        self.managesNativeButtons = managesNativeButtons
        self.reading = reading; self.onRevealChange = onRevealChange
        self.backFocus = backFocus; self.onBackFrameChange = onBackFrameChange
    }
    public var body: some View {
        Group {
            if !hidden {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 81).allowsHitTesting(false)
                    Rectangle().fill(NativePalette.thread.line.swiftUI).frame(width: 1, height: 18)
                    Button { action?.onBack() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 30).contentShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).disabled(suspended || action == nil)
                    .focused(backFocus ?? $unmanagedBackFocus)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { onBackFrameChange?($0) }
                    .accessibilityLabel(action?.label ?? "").help(action?.label ?? "")
                    .accessibilityHidden(action == nil)
                    .accessibilityIdentifier("window-navigation.back")
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                    .padding(.leading, 6)
                    .offset(x: action == nil ? -7 : 0)
                    Spacer(minLength: 0)
                }
                .frame(width: action == nil ? NativeWindowNavigationGeometry.closedWidth : NativeWindowNavigationGeometry.openWidth,
                       height: NativeWindowNavigationGeometry.height, alignment: .leading)
                .glassEffect(.regular, in: .capsule)
                .opacity(action == nil ? 0 : 1)
                .animation(NativeWindowNavigationPresentation.expansionAnimation, value: action != nil)
                .allowsHitTesting(action != nil && !suspended)
                .padding(.leading, NativeWindowNavigationGeometry.left)
                .padding(.top, NativeWindowNavigationGeometry.top)
                // Window controls do not participate in application content zoom.
                .scaleEffect(1 / contentScale, anchor: .topLeading)
            }
        }
        .onChange(of: hidden, initial: true) { _, value in onRevealChange?(!value) }
    }
}
