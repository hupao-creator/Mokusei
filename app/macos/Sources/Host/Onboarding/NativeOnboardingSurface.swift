import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

struct NativeOnboardingSurface: View {
    @Bindable var state: NativeOnboardingState
    let scene: NativeMokuSceneState
    let applicationSections: [NativeApplicationSettingsSection]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var mapMotion = NativeMokuSettingsAnimationState()
    @State private var panelStep = NativeOnboardingStep.discovery
    @State private var contentVisible = true
    @State private var collapsed = false
    @State private var panelVisible = true
    // Onboarding unfolds from the always-dark Moku, so its own surface tokens
    // stay dark even when the workspace window follows a light appearance.
    private var ink: Color { Color(white: 0.94) }
    private var secondary: Color { Color(white: 0.73) }
    private var motion: Animation? { .smooth(duration: 0.32) }
    private var locale: DesktopLocale { state.locale }

    var body: some View {
        GeometryReader { geometry in
            let panelSize = size(in: geometry.size)
            let fallback = NativeMokuCapsuleLayout.surface(in: NativeMokuCapsuleLayout.frame(
                in: CGRect(origin: .zero, size: geometry.size), landing: true), expanded: true, height: 76, centered: true)
            let destination = scene.capsuleFrame.width > 0 ? scene.capsuleFrame : fallback
            panel
                .frame(width: panelSize.width, height: panelSize.height)
                .opacity(contentVisible ? 1 : 0)
                .frame(width: collapsed ? destination.width : panelSize.width,
                       height: collapsed ? destination.height : panelSize.height)
                // Stay opaque for the whole contraction. Cross-fading this fill
                // to clear glass while the Dock is still hidden samples the light
                // workspace and paints a bright pill before the composer appears.
                .background {
                    Color(white: 0.10)
                        .opacity(reduceTransparency || contrast == .increased ? 1 : 0.96)
                }
                .clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
                        .opacity(collapsed ? 0 : 1)
                }
                .shadow(color: .black.opacity(0.13), radius: collapsed ? 13 : 30, y: collapsed ? 6 : 16)
                .position(x: collapsed ? destination.midX : geometry.size.width / 2,
                          y: collapsed ? destination.midY : geometry.size.height / 2)
                .opacity(panelVisible ? 1 : 0)
                .allowsHitTesting(state.step != .landing)
                .accessibilityHidden(state.step == .landing)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("onboarding")) } action: { state.panelFrame = $0 }
                .animation(motion, value: panelSize)
        }
        .coordinateSpace(name: "onboarding")
        .ignoresSafeArea()
        // Scope the dark appearance locally: the containing window and the rest
        // of the workspace keep following the selected/system appearance.
        .environment(\.colorScheme, .dark)
        .environment(\.nativeSettingsCompactPresentation, true)
        .environment(\.nativeSettingsInteractions, state.interactions)
        .environment(\.nativeSettingsInteractionContext, state.context)
        .environment(\.nativeSettingsInteractionRefresh, state.interactions.refresh)
        .environment(\.nativeOnboardingHarnessIDs, Set(state.installed.map(\.descriptor.id)))
        .nativeSettingsTextEditing(onComposition: { state.settings.draft.composing = $0 }, onBlur: { state.settings.draft.flushText() })
        .onAppear { state.mounted = true; state.admitIfNeeded() }
        .onDisappear { state.mounted = false }
        .task(id: state.step) { await transition() }
    }

    private func size(in viewport: CGSize) -> CGSize {
        let height: CGFloat
        switch panelStep {
        case .discovery: height = 430
        case .moku: height = 650
        case .tag, .report: height = state.settings.draft.value["pluginSettings"]?.arrayValue?
            .first(where: { $0["id"] == panelStep.settingID.map(JSONValue.text) })?["value"]?["mode"] == .text("override") ? 740 : 640
        case .landing: height = 640
        }
        return .init(width: min(680, viewport.width - 64), height: min(height, viewport.height - 136))
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(NativeOnboardingStep.allCases, id: \.rawValue) { step in
                    Capsule().fill(step.rawValue <= panelStep.rawValue ? ink : secondary.opacity(0.2))
                        .frame(width: step == panelStep ? 32 : 20, height: 3)
                }
            }.frame(height: 28).padding(.top, 16).padding(.bottom, 10)
                .accessibilityLabel(locale.text("第 \(panelStep.rawValue + 1) 步，共 5 步", "Step \(panelStep.rawValue + 1) of 5"))
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        if let error = state.error ?? state.settings.draft.error ?? discoveryError {
                            NativeSettingsNotice(message: error, kind: .error, action: AnyView(
                                HStack {
                                    Button(locale.text("重试", "Retry"), action: state.retry)
                                        .nativeSettingsAction("retry", label: "Retry onboarding") { state.retry() }
                                    if state.settings.draft.conflicted {
                                        Button(locale.text("使用已保存的配置", "Use saved settings")) { state.settings.draft.discardConflict() }
                                    }
                                }.buttonStyle(.borderless))).padding(.bottom, 12)
                        }
                        if !state.admitted { ProgressView().padding(.top, 80) }
                        else if panelStep == .discovery { discovery.padding(.top, 22) }
                        else {
                            NativeRoleConfigurationPanel(role: panelStep == .moku ? .moku : panelStep == .tag ? .tag : .report,
                                harnesses: state.installed, locale: locale) {
                                configurationForStep(panelStep).disabled(state.busy)
                            }
                        }
                    }
                    .id(panelStep).transition(.opacity.combined(with: .offset(y: 10)))
                    .frame(maxWidth: 560).padding(.horizontal, 30).padding(.bottom, 20).frame(maxWidth: .infinity)
                }
            }.scrollIndicators(.never)
            HStack {
                if panelStep != .discovery {
                    Button(action: state.back) { Label(locale.text("返回", "Back"), systemImage: "chevron.left") }
                        .buttonStyle(.glass)
                        .nativeSettingsAction("back", label: "Back") { state.back() }.disabled(state.busy)
                }
                Spacer()
                if panelStep == .discovery, state.installed.isEmpty, !state.detecting, !discoveryHasFailures, discoveryError == nil {
                    Button(locale.text("重新检测", "Check again"), action: state.scan)
                        .buttonStyle(.glass)
                        .nativeSettingsAction("scan", label: "Check for Agents", action: state.scan)
                        .disabled(state.settings.probing || !state.workspace.runtimeAvailable)
                } else {
                    Button { Task { await state.advance() } } label: {
                        HStack(spacing: 15) {
                            if state.busy { ProgressView().controlSize(.small) }
                            Text(panelStep == .report ? locale.text("开始使用 Chief", "Start using Chief") : locale.text("继续", "Continue"))
                            Image(systemName: "arrow.right")
                        }.font(.system(size: 12, weight: .medium)).frame(minWidth: 116, minHeight: 24)
                    }.buttonStyle(.glass).keyboardShortcut(.defaultAction)
                        .nativeSettingsAction("next", label: "Continue") { Task { await state.advance() } }.disabled(!state.canAdvance)
                }
            }.frame(maxWidth: 560).padding(.horizontal, 30).padding(.bottom, 22).padding(.top, 8)
        }.foregroundStyle(ink)
    }

    private var discoveryError: String? {
        guard panelStep == .discovery else { return nil }
        if case .failed(let message) = state.settings.installationLoadState { return message }
        return nil
    }
    private var discoveryHasFailures: Bool {
        state.harnesses.contains { if case .failed = state.discoveryState($0) { return true }; return false }
    }
    private var discovery: some View {
        VStack(spacing: 24) {
            HStack(spacing: 10) {
                if state.detecting { ProgressView().controlSize(.small) }
                Text(state.detecting
                     ? locale.text("正在发现 Agent · \(state.installed.count) 个已就绪", "Discovering Agents · \(state.installed.count) ready")
                     : discoveryHasFailures || discoveryError != nil
                        ? locale.text("\(state.installed.count) 个 Agent 已就绪，部分读取失败", "\(state.installed.count) Agents ready; some could not be loaded")
                     : state.installed.isEmpty ? locale.text("安装一个 Agent", "Install an Agent")
                     : locale.text("发现 \(state.installed.count) 个 Agent", "Found \(state.installed.count) Agents"))
                    .font(.system(size: 16, weight: .medium)).contentTransition(.numericText())
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(state.harnesses, id: \.descriptor.id) { harness in
                    discoveryAgent(harness)
                }
            }
            ForEach(state.harnesses, id: \.descriptor.id) { harness in
                if case .failed(let message) = state.discoveryState(harness) {
                    NativeSettingsNotice(message: harness.descriptor.displayName.string + ": " + message, kind: .error,
                        action: AnyView(Button(locale.text("重试", "Retry")) { state.retryDiscovery(harness) }
                            .buttonStyle(.borderless).disabled(!state.workspace.runtimeAvailable)
                            .nativeSettingsAction("retry." + harness.descriptor.id.string, label: "Retry " + harness.descriptor.displayName.string) {
                                state.retryDiscovery(harness)
                            }))
                }
            }
            if state.installed.contains(where: { $0.descriptor.threadCapabilities.canHostMoku }), state.detecting || discoveryHasFailures {
                Text(locale.text("可以先配置已就绪的 Agent；返回此页可查看其余 Agent。", "You can configure ready Agents now. Return here to check the others."))
                    .font(.system(size: 12)).foregroundStyle(secondary)
            } else if state.installed.isEmpty && !state.detecting && !discoveryHasFailures {
                Text(locale.text("安装并登录后，重新检测。", "Install and sign in, then check again."))
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }
        }.animation(motion, value: state.installed.map(\.descriptor.id))
    }

    private func discoveryAgent(_ harness: AnyHarnessPlugin) -> some View {
        let status = state.discoveryState(harness)
        return VStack(spacing: 12) {
            harness.logo(size: status == .ready ? 72 : 32).frame(width: 86, height: 90)
                .opacity(status == .ready ? 1 : 0.5)
            Text(harness.descriptor.displayName.string).font(.system(size: status == .ready ? 16 : 12, weight: .medium))
            Group {
                switch status {
                case .checking, .loading:
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(status == .checking ? locale.text("检测中", "Checking") : locale.text("读取配置中", "Loading settings"))
                    }
                case .ready: Label(locale.text("已就绪", "Ready"), systemImage: "checkmark")
                case .failed: Text(locale.text("读取失败", "Load failed"))
                case .missing:
                    if let guide = harness.descriptor.installationGuide {
                        Button { open(guide) } label: { Label(locale.text("安装", "Install"), systemImage: "arrow.up.right") }
                            .buttonStyle(.plain)
                    } else { Text(locale.text("未安装", "Not installed")) }
                }
            }.font(.system(size: 11)).foregroundStyle(secondary)
        }.frame(maxWidth: .infinity, minHeight: 168)
    }

    private func configurationForStep(_ step: NativeOnboardingStep) -> some View {
        configuration.environment(\.nativeSettingsReadiness, state.editors[step])
    }

    @ViewBuilder private var configuration: some View {
        if panelStep == .moku {
            NativeMokuSettings(model: state.settings, harnesses: state.installed, locale: locale, focusRequest: 0, motion: mapMotion,
                harnessSettings: { request in
                    AnyView(NativeHarnessSettingsView(host: state.workspace.harnessHost,
                        configuration: .init(harnessID: request.harnessID, cwd: JSONText(state.settings.defaultCwd),
                            source: request.savedValue, scope: .global(executionOwner: .moku)),
                        section: request.section, executionSnapshot: true, settingsFormPage: true,
                        refreshSequence: request.refreshSequence, value: request.value))
                }, onCoordinatorFrame: { _, _ in }, onCloseRequest: {}, presentation: .compact)
        } else if let id = panelStep.settingID, let section = applicationSections.first(where: { $0.id == id }) {
            let saved = state.settings.savedSettings["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .text(id) })?["value"] ?? .null
            section.content(saved, state.settings.applicationValueBinding(id))
                .environment(\.nativeSettingsInteractionScope, id)
        } else {
            NativeSettingsNotice(message: locale.text("正在读取配置…", "Loading configuration…"))
                .nativeSettingsEditorReady(false)
        }
    }

    private func open(_ url: URL) {
        Task { do { try await state.workspace.services.openExternal(JSONText(url.absoluteString)) }
            catch { state.error = error.localizedDescription } }
    }

    @MainActor private func transition() async {
        guard state.step == .landing else { withAnimation(motion) { panelStep = state.step }; return }
        do {
            withAnimation(.easeOut(duration: 0.14)) { contentVisible = false }
            try await Task.sleep(for: .milliseconds(160))
            scene.disabled = !state.workspace.runtimeAvailable
            state.mountDock = true
            scene.setInputOpen(true)
            try await Task.sleep(for: .milliseconds(50))
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.78)) { collapsed = true }
            try await Task.sleep(for: .milliseconds(800))
            // Reveal the Dock behind the still-opaque panel first. Animating the
            // panel and the Dock against each other leaves both translucent over
            // the light workspace for a frame, which reads as a second flash.
            state.dockVisible = true
            try await Task.sleep(for: .milliseconds(30))
            withAnimation(.easeInOut(duration: 0.18)) { panelVisible = false }
            try await Task.sleep(for: .milliseconds(200))
            state.finishHandoff()
        } catch { return }
    }
}
