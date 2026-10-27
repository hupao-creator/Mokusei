import MokuseiCore
import MokuseiPluginUI
import SwiftUI

/// ApplicationStatus owns startup and recovery, independently of plugin content.
public struct NativeRuntimeSurface<Content: View>: View {
    @Bindable private var model: NativeWorkspaceModel
    private let showsConnectionNotice: Bool
    private let onSettingsWithOrigin: ((CGRect) -> Void)?
    private let onSettingsFrameChange: ((CGRect?) -> Void)?
    private let content: Content

    public init(model: NativeWorkspaceModel, showsConnectionNotice: Bool = true,
                onSettingsWithOrigin: ((CGRect) -> Void)? = nil,
                onSettingsFrameChange: ((CGRect?) -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.model = model; self.showsConnectionNotice = showsConnectionNotice
        self.onSettingsWithOrigin = onSettingsWithOrigin; self.onSettingsFrameChange = onSettingsFrameChange
        self.content = content()
    }

    public var body: some View {
        ZStack {
            if model.hasInitialContent {
                content.onAppear { model.startupPerformance?.contentAppeared() }
            }
            else {
                RuntimeStartupScreen(state: model.connection, error: model.connectionError ?? "",
                    reconnecting: model.reconnecting, locale: model.preferences.locale,
                    onReconnect: { Task { await model.retry() } },
                    onSettings: { rect in
                        if let onSettingsWithOrigin { onSettingsWithOrigin(rect) }
                        else { model.settingsOpen = true }
                    }, onSettingsFrameChange: onSettingsFrameChange, announcementsEnabled: !model.settingsOpen)
            }
        }
        .overlay(alignment: .top) {
            if showsConnectionNotice { NativeRuntimeConnectionNotice(model: model).padding(.top, 12) }
        }
    }
}

/// Place above the whole scene when Moku or Settings can cover the outside page.
/// Settings makes this inert and AX-hidden, while its visual status stays shown.
public struct NativeRuntimeConnectionNotice: View {
    @Bindable private var model: NativeWorkspaceModel
    public init(model: NativeWorkspaceModel) { self.model = model }
    public var body: some View {
        if model.hasInitialContent {
            RuntimeConnectionNotice(state: model.connection, synchronizing: model.synchronizing,
                error: model.connectionError ?? "", reconnecting: model.reconnecting,
                locale: model.preferences.locale, onReconnect: { Task { await model.retry() } },
                announcementsEnabled: !model.settingsOpen)
        }
    }
}

private struct RuntimeStartupScreen: View {
    let state: RuntimeConnectionStatus
    let error: String
    let reconnecting: Bool
    let locale: DesktopLocale
    let onReconnect: () -> Void
    let onSettings: (CGRect) -> Void
    let onSettingsFrameChange: ((CGRect?) -> Void)?
    var announcementsEnabled = true
    @State private var settingsAnchor = RuntimeSettingsAnchor()
    private var connecting: Bool { reconnecting || state == .connecting }
    private var loading: Bool { reconnecting || (error.isEmpty && (connecting || state == .connected)) }
    private var message: String {
        state == .stopped ? locale.text("后台服务已停止", "The background service has stopped")
            : locale.text("暂时无法连接 Agent", "Unable to connect to the agent")
    }

    var body: some View {
        Group {
            if loading {
                NativeLoadingMark().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RuntimeLoadingDragRegion())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(locale.text("正在加载…", "Loading…"))
            } else {
                VStack(spacing: 14) {
                    Text(message).font(NativeTypography.inter(size: 14, weight: 700))
                    Text(locale.text("你可以先调整界面偏好，连接后即可继续工作。",
                                     "You can adjust your preferences while waiting to reconnect."))
                    if !error.isEmpty {
                        // <p> retains its normal one-em block margins in the
                        // original flex column, in addition to its 14px gap.
                        Text(error).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).frame(maxWidth: 480).padding(.vertical, 14)
                    }
                    HStack(spacing: 20) {
                        Button(locale.text("重新连接", "Reconnect"), action: onReconnect).disabled(connecting)
                        Button(locale.text("设置", "Settings")) { onSettings(settingsAnchor.frame ?? .zero) }
                            .background(RuntimeSettingsFrameReader(anchor: settingsAnchor, onChange: onSettingsFrameChange))
                            .onDisappear { onSettingsFrameChange?(nil) }
                    }.buttonStyle(RuntimeTextButtonStyle())
                }
                .font(NativeTypography.inter(size: 14))
                .foregroundStyle(NativePalette.overview.muted.swiftUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            RuntimeStatusAnnouncements(status: loading ? locale.text("正在加载…", "Loading…") : message,
                error: loading ? "" : error, enabled: announcementsEnabled).frame(width: 0, height: 0)
        }
    }
}

@MainActor private final class RuntimeSettingsAnchor { var frame: CGRect? }
private struct RuntimeSettingsFrameReader: View {
    let anchor: RuntimeSettingsAnchor
    let onChange: ((CGRect?) -> Void)?
    var body: some View {
        Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { frame in
            anchor.frame = frame; onChange?(frame)
        }.onDisappear { anchor.frame = nil; onChange?(nil) }
    }
}

private struct RuntimeConnectionNotice: View {
    let state: RuntimeConnectionStatus
    let synchronizing: Bool
    let error: String
    let reconnecting: Bool
    let locale: DesktopLocale
    let onReconnect: () -> Void
    var announcementsEnabled = true
    private var visible: Bool { state != .connected || synchronizing || !error.isEmpty || reconnecting }
    private var canReconnect: Bool { state == .stopped || state == .disconnected || !error.isEmpty }
    private var message: String {
        if reconnecting { return locale.text("正在连接 Agent…", "Connecting to agent…") }
        if state == .stopped { return locale.text("后台服务已停止", "The background service has stopped") }
        // Trust/protocol failures stop automatic retry. Their reason must be
        // visible on touch devices, where a hover help tag is not reachable.
        if !error.isEmpty { return error }
        if state == .disconnected { return locale.text("与后台服务的连接已断开，正在重连…", "Disconnected from the background service. Reconnecting…") }
        return locale.text("正在同步后台服务…", "Syncing with the background service…")
    }
    var body: some View {
        if visible {
            HStack(spacing: 12) {
                Text(message).fixedSize(horizontal: false, vertical: true).allowsHitTesting(false)
                if canReconnect {
                    Button(locale.text("重新连接", "Reconnect"), action: onReconnect)
                        .buttonStyle(RuntimeTextButtonStyle()).disabled(reconnecting)
                }
            }
            .font(NativeTypography.inter(size: 12))
            .foregroundStyle(NativePalette.overview.muted.swiftUI)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: 640)
            // --surface-bg has no definition in the renderer: CSS Canvas is
            // the fallback, not the warm overview card surface.
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(NativePalette.pair(0xffffff, 0x121212).swiftUI)
                    .allowsHitTesting(false)
            }
            .help(error)
            .accessibilityElement(children: .contain)
            .background {
                RuntimeStatusAnnouncements(status: message, error: "", enabled: announcementsEnabled)
                    .frame(width: 0, height: 0)
            }
        }
    }
}

/// Native equivalent of the source's live status and alert regions. Settings
/// keeps the status visually present while suppressing background announcements.
private struct RuntimeStatusAnnouncements: View {
    let status: String
    let error: String
    let enabled: Bool
    var body: some View {
        Color.clear.onChange(of: error.isEmpty ? status : error) { _, message in
            if enabled, !message.isEmpty { AccessibilityNotification.Announcement(message).post() }
        }
    }
}

private struct RuntimeTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RuntimeTextButtonBody(label: configuration.label) }
}
private struct RuntimeTextButtonBody<Label: View>: View {
    let label: Label
    @State private var hovered = false
    var body: some View {
        label.font(NativeTypography.inter(size: 11, weight: 580))
            .padding(.horizontal, 13).frame(height: controlHeight)
            .foregroundStyle((hovered ? NativePalette.overview.ink : NativePalette.overview.muted).swiftUI)
            .background(hovered ? NativePalette.pair(0x20211e, 0xe0e5da, alpha: 0.05).swiftUI : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }

    private var controlHeight: CGFloat {
        32
    }
}

private struct RuntimeLoadingDragRegion: View {
    var body: some View {
        Color.clear.gesture(WindowDragGesture())
    }
}
