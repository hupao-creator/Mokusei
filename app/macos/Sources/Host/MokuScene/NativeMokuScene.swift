import MokuseiCore
import MokuseiPluginUI
import SwiftUI

public struct NativeMokuScene<Outside: View, Thread: View, Dock: View, Settings: View>: View {
    public let state: NativeMokuSceneState
    private let outside: Outside
    private let thread: Thread
    private let dock: Dock
    private let settings: Settings
    private let closeSettings: () -> Void
    private let prepareHistoryReturn: (() async -> Void)?
    private let onHistoryParentPresentationChange: ((Bool) -> Void)?
    public init(state: NativeMokuSceneState, @ViewBuilder outside: () -> Outside,
                @ViewBuilder thread: () -> Thread, @ViewBuilder dock: () -> Dock,
                onCloseSettings: (() -> Void)? = nil,
                prepareHistoryReturn: (() async -> Void)? = nil,
                onHistoryParentPresentationChange: ((Bool) -> Void)? = nil,
                @ViewBuilder settings: () -> Settings) {
        self.state = state; self.outside = outside(); self.thread = thread(); self.dock = dock(); self.settings = settings()
        self.closeSettings = onCloseSettings ?? { state.closeSettings() }
        self.prepareHistoryReturn = prepareHistoryReturn
        self.onHistoryParentPresentationChange = onHistoryParentPresentationChange
    }
    public var body: some View {
        ZStack {
            NativeReadingPageStack(open: state.mokuOpen, identity: JSONText(state.historyVisit.uuidString),
                motion: state.historyMotion, enabled: !state.settingsOpen && !state.cameraActive,
                focusBlur: true, stationaryParent: true, emphasizedOpening: true, panel: true,
                onParentPresentationChange: onHistoryParentPresentationChange,
                prepareParent: prepareHistoryReturn,
                onPanelOutsideClick: { state.closeHistory() },
                onClose: { state.setMokuOpen(false) }) {
                outside
            } front: {
                thread
            }
                .blur(radius: state.settingsExpanded ? 12 : 0)
            if state.settingsOpen {
                Color.black.opacity(state.settingsExpanded ? 0.08 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if !state.settingsClosing { closeSettings() } }
                    .accessibilityHidden(true)
            }
            // One resident instance spans Overview and reading panels. Other
            // application pages and covering routes remain ineligible for the Dock.
            if !state.dockCovered || state.settingsOpen {
                Group {
                    if state.dockRouteVisible {
                        dock.environment(\.nativeMokuSettingsContent, AnyView(settings)).transition(.opacity)
                    }
                }
                .allowsHitTesting(state.dockRouteVisible)
                .accessibilityHidden(!state.dockRouteVisible)
                .disabled(!state.dockRouteVisible)
                .animation(.smooth(duration: 0.42, extraBounce: 0), value: state.dockRouteVisible)
            }
        }
        .modifier(NativeSettingsTransition(state: state))
        .environment(\.nativeCanvasInputRegions, state.canvasInputRegions)
        .onAppear { state.setWindowVisible(true) }
        .onDisappear { state.setWindowVisible(false) }
    }
}
