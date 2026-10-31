import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

struct NativeOnboardingSurface: View {
    @Bindable var state: NativeOnboardingState
    let scene: NativeMokuSceneState
    let applicationSections: [NativeApplicationSettingsSection]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var mapMotion = NativeMokuSettingsAnimationState()
    @State private var panelStep = NativeOnboardingStep.discovery
    @State private var contentVisible = true
    @State private var collapsed = false
    // Onboarding unfolds from the always-dark Moku, so its own surface tokens
    // stay dark even when the workspace window follows a light appearance.
    private var ink: Color { Color(white: 0.94) }
    private var secondary: Color { Color(white: 0.73) }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.32) }
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
                .background {
                    ZStack {
                        NativeMokuCapsuleGlass(interactive: false).opacity(collapsed ? 1 : 0)
                        Color(white: 0.10)
                            .opacity(reduceTransparency || contrast == .increased ? 1 : 0.96)
                            .opacity(collapsed ? 0 : 1)
                    }
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
                .opacity(state.dockVisible ? 0 : 1)
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
        .nativeSettingsTextEditing(onComposition: { state.settings.draft.composing = $0 }, onBlur: { state.settings.draft.flushText() })
        .onAppear { state.mounted = true; state.admitIfNeeded() }
        .onDisappear { state.mounted = false }
        .task(id: state.step) { await transition() }
    }

    private func size(in viewport: CGSize) -> CGSize {
        let height: CGFloat
        switch panelStep {
        case .discovery: height = 430
        case .moku: height = 590
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
                    .id(panelStep).transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
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
                if panelStep == .discovery, state.installed.isEmpty, !state.detecting {
                    Button(locale.text("重新检测", "Check again")) { Task { await state.settings.refreshInstallations() } }
                        .buttonStyle(.glass)
                        .nativeSettingsAction("scan", label: "Check for Agents") { Task { await state.settings.refreshInstallations() } }
                        .disabled(state.settings.probing || !state.workspace.runtimeAvailable)
                } else {
                    Button { Task { await state.advance() } } label: {
                        HStack(spacing: 15) {
                            if state.busy { ProgressView().controlSize(.small) }
                            Text(panelStep == .report ? locale.text("开始使用 Moku", "Start using Moku") : locale.text("继续", "Continue"))
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
        return state.harnesses.compactMap { state.settings.installations[$0.descriptor.id.string] }
            .first(where: { $0.status == .error })?.message
    }
    private var discovery: some View {
        VStack(spacing: 44) {
            HStack(spacing: 10) {
                if state.detecting { ProgressView().controlSize(.small) }
                Text(state.detecting ? locale.text("正在发现 Agent", "Discovering Agents")
                     : discoveryError != nil && state.installed.isEmpty ? locale.text("暂时无法发现 Agent", "Unable to discover Agents")
                     : state.installed.isEmpty ? locale.text("安装一个 Agent", "Install an Agent")
                     : locale.text("发现 \(state.installed.count) 个 Agent", "Found \(state.installed.count) Agents"))
                    .font(.system(size: 16, weight: .medium)).contentTransition(.numericText())
            }
            if state.installed.isEmpty && !state.detecting && discoveryError == nil {
                HStack(spacing: 24) {
                    ForEach(state.harnesses, id: \.descriptor.id) { harness in
                        VStack(spacing: 16) {
                            harness.logo(size: 50).frame(height: 64)
                            if let guide = harness.descriptor.installationGuide {
                                Button { open(guide) } label: {
                                    Label(harness.descriptor.displayName.string, systemImage: "arrow.up.right").font(.system(size: 12))
                                }.buttonStyle(.plain)
                            } else { Text(harness.descriptor.displayName.string).font(.system(size: 12)) }
                        }.frame(maxWidth: .infinity)
                    }
                }
                Text(locale.text("安装并登录后，重新检测。", "Install and sign in, then check again."))
                    .font(.system(size: 12)).foregroundStyle(secondary)
            } else {
                HStack(spacing: 28) {
                    ForEach(state.installed, id: \.descriptor.id) { harness in
                        VStack(spacing: 26) {
                            harness.logo(size: 72).frame(width: 86, height: 90)
                            Text(harness.descriptor.displayName.string).font(.system(size: 16, weight: .medium))
                        }.frame(maxWidth: .infinity, minHeight: 168)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 18)))
                    }
                }.frame(height: 190)
            }
        }.animation(motion, value: state.installed.map(\.descriptor.id))
    }

    private func configurationForStep(_ step: NativeOnboardingStep) -> some View {
        configuration.environment(\.nativeSettingsReadiness, state.editors[step])
    }

    @ViewBuilder private var configuration: some View {
        if panelStep == .moku {
            NativeMokuSettings(model: state.settings, harnesses: state.harnesses, locale: locale, focusRequest: 0, motion: mapMotion,
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
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { contentVisible = false }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 160))
            scene.disabled = !state.workspace.runtimeAvailable
            state.mountDock = true
            scene.setInputOpen(true)
            try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 50))
            withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.78)) { collapsed = true }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 800))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { state.dockVisible = true }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 200))
            state.finishHandoff()
        } catch { return }
    }
}
