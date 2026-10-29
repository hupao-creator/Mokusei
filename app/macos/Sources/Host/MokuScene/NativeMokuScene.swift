import MokuseiPluginUI
import SwiftUI

public struct NativeMokuScene<Outside: View, Thread: View, Dock: View, Settings: View>: View {
    public let state: NativeMokuSceneState
    private let outside: Outside
    private let thread: Thread
    private let dock: Dock
    private let settings: Settings
    private let closeSettings: () -> Void
    public init(state: NativeMokuSceneState, @ViewBuilder outside: () -> Outside,
                @ViewBuilder thread: () -> Thread, @ViewBuilder dock: () -> Dock,
                onCloseSettings: (() -> Void)? = nil,
                @ViewBuilder settings: () -> Settings) {
        self.state = state; self.outside = outside(); self.thread = thread(); self.dock = dock(); self.settings = settings()
        self.closeSettings = onCloseSettings ?? { state.closeSettings() }
    }
    public var body: some View {
        ZStack {
            outside.opacity(state.mokuOpen ? 0 : 1)
                .blur(radius: state.settingsExpanded ? 12 : 0)
                .disabled(state.mokuOpen || state.settingsOpen)
                .allowsHitTesting(!state.mokuOpen && !state.settingsOpen)
                .accessibilityHidden(state.mokuOpen || state.settingsOpen)
            if state.mokuOpen { thread.transition(.opacity.combined(with: .scale(scale: 0.97))).disabled(state.settingsOpen) }
            if state.settingsOpen {
                Color.black.opacity(state.settingsExpanded ? 0.08 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if !state.settingsClosing { closeSettings() } }
                    .accessibilityHidden(true)
            }
            // Shared shell slot. Covered routes already omit the dock; a selected
            // thread or application is not Overview, so the capsule must not stay mounted.
            if !state.dockCovered || state.settingsOpen {
                Group {
                    if state.overviewVisible {
                        dock.environment(\.nativeMokuSettingsContent, AnyView(settings)).transition(.opacity)
                    }
                }
                .allowsHitTesting(state.overviewVisible)
                .accessibilityHidden(!state.overviewVisible)
                .disabled(!state.overviewVisible)
                .animation(.smooth(duration: 0.42, extraBounce: 0), value: state.overviewVisible)
            }
        }
        .modifier(NativeSettingsTransition(state: state))
        .environment(\.nativeCanvasInputRegions, state.canvasInputRegions)
        .animation(.smooth(duration: 0.3), value: state.mokuOpen)
        .onAppear { state.setWindowVisible(true) }
        .onDisappear { state.setWindowVisible(false) }
    }
}
