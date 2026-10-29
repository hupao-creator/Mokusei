import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor public struct NativeSettingsPage: View {
    public let model: NativeSettingsModel
    public let preferences: DesktopPreferences
    public let harnesses: [AnyHarnessPlugin]
    public let applicationSections: [NativeApplicationSettingsSection]
    public let harnessSettings: (NativeHarnessSettingsRequest) -> AnyView
    public let onSetAppearance: (DesktopAppearance) throws -> Void
    public let onSetLocale: (DesktopLocale) throws -> Void
    public let onClose: (CGRect) -> Void
    public var mokuController: MokuCharacterController?
    public var onCoordinatorFrame: (CGRect?, Bool) -> Void
    @State private var navigation: NativeSettingsNavigation
    @State private var preferencesErrors: [String: String] = [:]
    @State private var activeAgent: String?
    @State private var pinnedAgent = false
    @FocusState private var focusedTab: String?
    @FocusState private var focusedBack: Bool
    @FocusState private var focusedAgent: String?
    @State private var agentRegion = SettingsDetailRegion()
    @State private var agentErrorHeight: CGFloat = 130
    @State private var agentDetailHeight: CGFloat = 318
    @State private var restoringAgentFocus = false
    @State private var settingsContentHeight: CGFloat = 0
    @State private var agentRowBottom: CGFloat = 0
    @State private var hoveredTab: String?
    @State private var keyboardNavigation = false
    @State private var mokuMotion = NativeMokuSettingsAnimationState()
    @State private var animationVisits = NativeSettingsAnimationVisits()
    @Namespace private var tabSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: NativeSettingsModel, navigation: NativeSettingsNavigation? = nil, preferences: DesktopPreferences, harnesses: [AnyHarnessPlugin],
                applicationSections: [NativeApplicationSettingsSection] = [],
                harnessSettings: @escaping (NativeHarnessSettingsRequest) -> AnyView,
                onSetAppearance: @escaping (DesktopAppearance) throws -> Void,
                onSetLocale: @escaping (DesktopLocale) throws -> Void,
                onClose: @escaping (CGRect) -> Void,
                mokuController: MokuCharacterController? = nil,
                onCoordinatorFrame: @escaping (CGRect?, Bool) -> Void = { _, _ in }) {
        self.model = model
        _navigation = State(initialValue: navigation ?? NativeSettingsNavigation(section: model.runtimeAvailable ? "moku" : "general"))
        self.preferences = preferences; self.harnesses = harnesses
        self.applicationSections = applicationSections; self.harnessSettings = harnessSettings
        self.onSetAppearance = onSetAppearance; self.onSetLocale = onSetLocale; self.onClose = onClose
        self.mokuController = mokuController; self.onCoordinatorFrame = onCoordinatorFrame
    }

    private var locale: DesktopLocale { preferences.locale }
    private var activeApplications: [NativeApplicationSettingsSection] {
        applicationSections.filter { definition in model.plugins.first { $0.key == "extension:\(definition.owner)" }?.enabled != false }
    }
    private var sections: [String] { NativeSettingsNavigation.sections(model: model, applications: applicationSections) }
    private var activeSection: String { sections.contains(navigation.section) ? navigation.section : "general" }
    private var busy: Bool { model.clearing }
    private var detailOverflow: CGFloat {
        activeAgent == nil ? 0 : max(0, agentRowBottom + 10 + min(350, agentDetailHeight + 32) - settingsContentHeight)
    }

    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.height < 220 {
                // At extreme app zoom, fixed chrome can consume the viewport.
                // Scroll the whole shell as well, retaining every real control.
                NativeScrollView { panel.frame(minHeight: 360) }
                    .environment(\.nativeSettingsViewportWidth, geometry.size.width)
            } else {
                panel
                    .environment(\.nativeSettingsViewportWidth, geometry.size.width)
            }
        }.font(.system(size: 13)).foregroundStyle(NativeAppKitPalette.settings.text.swiftUI)
            .tint(NativeAppKitPalette.settings.accent.swiftUI)
            .environment(\.locale, Locale(identifier: locale.rawValue))
            .environment(\.nativeSettingsInteractions, navigation.interactions)
            .environment(\.nativeSettingsInteractionContext, navigation.interactionContext(section: activeSection))
            .environment(\.nativeSettingsInteractionRefresh, navigation.interactions.refresh)
            .nativeSettingsTextEditing(onComposition: { model.draft.composing = $0 },
                                       onBlur: { model.draft.flushText() })
            .background(NativeSettingsEscapeHandler {
                if activeAgent != nil { dismissAgent(returnFocus: true) }
                else { requestClose() }
            })
            .background(SettingsNavigationInputObserver { keyboardNavigation = $0 })
            .onAppear {
                model.draft.diagnostics.record(.page, .opened, revision: model.draft.revision)
                navigation.mounted = true
                focusedBack = true
                model.confirmClear = false; model.operationError = nil
                agentRegion.dismiss = { dismissAgent() }
            }
            .onDisappear {
                model.draft.diagnostics.record(.page, .closed, revision: model.draft.revision)
                navigation.mounted = false
                agentRegion.stop(); mokuMotion.stop(); onCoordinatorFrame(nil, true)
                animationVisits.reset()
            }
            .onChange(of: sections, initial: true) { _, _ in
                navigation.section = activeSection
            }
            .onChange(of: activeAgent) { _, active in
                agentRegion.setActive(active != nil)
                agentDetailHeight = 318
            }
            .onChange(of: pinnedAgent) { _, pinned in agentRegion.pinned = pinned }
            .onChange(of: focusedAgent) { _, id in
                agentRegion.iconFocused = id != nil
                if restoringAgentFocus { restoringAgentFocus = false }
                else if let id { activeAgent = id }
                else { agentRegion.dismissAfterFocusLeave() }
            }
            .onChange(of: model.runtimeAvailable) { _, available in
                if !available { navigation.section = "general"; dismissAgent() }
                else { Task { await model.refreshInstallations() } }
            }
            .onChange(of: navigation.section) { _, _ in
                model.confirmClear = false; activeAgent = nil; pinnedAgent = false
                if navigation.section != "moku" { onCoordinatorFrame(nil, true) }
            }
            .onExitCommand {
                if activeAgent != nil { dismissAgent(returnFocus: true) }
                else { requestClose() }
            }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { reader in
                NativeScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        if !model.runtimeAvailable {
                            SettingsNotice(locale.text("连接后台服务后可修改 Agent 配置。界面偏好仍可使用。", "Connect to the runtime service to edit Agent configuration. Interface preferences remain available."))
                        }
                        if let error = model.draft.error ?? model.operationError {
                            SettingsNotice(localizedError(error), error: true) {
                                if model.draft.error != nil {
                                    HStack(spacing: 16) {
                                        Button(locale.text(model.draft.conflicted ? "保留我的修改并重试" : "重试保存", model.draft.conflicted ? "Keep my changes and retry" : "Retry saving")) { model.draft.retry() }
                                            .nativeSettingsAction("retry", label: "Retry saving") { model.draft.retry() }
                                        if model.draft.conflicted {
                                            Button(locale.text("放弃草稿并载入最新设置", "Discard draft and load latest settings")) { model.draft.discardConflict() }
                                                .nativeSettingsAction("discard", label: "Discard draft") { model.draft.discardConflict() }
                                        }
                                    }.buttonStyle(.bordered).disabled(busy || !model.runtimeAvailable)
                                }
                            }.id("notice")
                        }
                        sectionBody.disabled(busy)
                            .environment(\.nativeSettingsFormPage, true)
                    }.background(GeometryReader { content in
                        Color.clear.onAppear { settingsContentHeight = content.size.height }
                            .onChange(of: content.size.height) { _, height in settingsContentHeight = height }
                    }).coordinateSpace(name: "settings-form")
                        .padding(.bottom, detailOverflow)
                        .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 36)
                }.onChange(of: activeSection) { _, _ in reader.scrollTo("top", anchor: .top) }
                    .onChange(of: model.draft.error) { _, error in if error != nil { reader.scrollTo("notice", anchor: .top) } }
                    .onChange(of: model.operationError) { _, error in if error != nil { reader.scrollTo("notice", anchor: .top) } }
                    .onChange(of: navigation.focusRequest) { _, _ in
                        if let field = model.draft.firstInvalidField { reader.scrollTo(field, anchor: .center) }
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 30, height: 30).accessibilityHidden(true)
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        tabs.frame(minWidth: geometry.size.width)
                    }.scrollIndicators(.never)
                        .onChange(of: activeSection) { _, id in reader.scrollTo(id, anchor: .center) }
                }
            }.frame(height: 42)
            Button(action: requestClose) {
                NativeIcon(name: "X", size: 14, strokeWidth: 2)
                    .frame(width: 30, height: 30).contentShape(Circle())
            }.buttonStyle(.plain).disabled(busy).focused($focusedBack)
                .foregroundStyle(.secondary)
                .accessibilityLabel(locale.text("关闭设置", "Close settings"))
                .accessibilityIdentifier("settings-close")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { navigation.returnRect = $0 }
        }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(sections, id: \.self) { id in
                Button { navigation.section = id; focusedTab = id } label: {
                    Text(sectionLabel(id))
                        .font(.system(size: 13, weight: activeSection == id ? .semibold : .regular))
                        .padding(.horizontal, 12).frame(height: 42)
                        .foregroundStyle(activeSection == id ? Color.primary : Color.secondary)
                        .background {
                            if hoveredTab == id { RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.045)) }
                        }
                        .overlay(alignment: .bottom) {
                            if activeSection == id {
                                Capsule().fill(.primary.opacity(0.8)).frame(width: 18, height: 2)
                                    .matchedGeometryEffect(id: "settings-tab", in: tabSelection)
                            }
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain).focusable(activeSection == id).focused($focusedTab, equals: id)
                    .modifier(SettingsNavigationFocusRing(visible: keyboardNavigation && focusedTab == id))
                    .onHover { hovering in
                        if hovering { hoveredTab = id } else if hoveredTab == id { hoveredTab = nil }
                    }
                    .accessibilityRepresentation {
                        SettingsTabAccessibilityRepresentation(title: sectionLabel(id), selected: activeSection == id, focused: focusedTab == id) {
                            navigation.section = id; focusedTab = id
                        }
                    }
                    .accessibilityLabel(sectionLabel(id))
                    .accessibilityAddTraits(activeSection == id ? .isSelected : [])
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end]) { event in
                        navigateTab(from: id, key: event.key); return .handled
                    }
                    .settingsTabAccessibilityAnchor(id: id).id(id)
            }
        }.padding(.horizontal, 4)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: activeSection)
            .settingsTabListAccessibility(title: locale.text("设置分类", "Settings sections"), horizontal: true,
                tabs: sections.map { id in
                    SettingsAccessibilityTab(id: id, title: sectionLabel(id), selected: activeSection == id, focused: focusedTab == id) {
                        navigation.section = id; focusedTab = id
                    }
                })
            .accessibilityElement(children: .contain).accessibilityLabel(locale.text("设置分类", "Settings sections"))
    }

    private var animationHarnesses: [AnyHarnessPlugin] {
        harnesses.filter { harness in
            let id = harness.descriptor.id.string
            let plugin = model.plugins.first { $0.key == "harness:" + id }
            return model.installations[id]?.status == .installed && plugin?.enabled != false && plugin?.unavailableReason == nil
        }
    }

    @ViewBuilder private var sectionBody: some View {
        if activeSection == "general" {
            VStack(spacing: 0) {
                Text(locale.text("通用", "General")).font(.system(size: 25, weight: .medium)).tracking(-0.5)
                    .accessibilityAddTraits(.isHeader).padding(.bottom, 8)
                Text(locale.text("界面偏好与本地 Agent", "Interface preferences and local Agents"))
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.bottom, 48)
                general
            }
        } else if let role = NativeSettingsRole(section: activeSection), model.runtimeAvailable {
            NativeRoleConfigurationPanel(role: role, harnesses: animationHarnesses, locale: locale,
                                         visitPlaybackStarted: role == .tag ? $animationVisits.tag : role == .report ? $animationVisits.report : nil) {
                if role == .moku {
                    NativeMokuSettings(model: model, harnesses: harnesses, locale: locale, focusRequest: navigation.focusRequest, motion: mokuMotion,
                        harnessSettings: harnessSettings, controller: mokuController, onCoordinatorFrame: onCoordinatorFrame,
                        onCloseRequest: requestClose, presentation: .compact, showsRoutingGuidance: true)
                } else if let application = activeApplications.first(where: { $0.id == activeSection }) {
                    applicationContent(application)
                }
            }.id(activeSection)
        } else if let application = activeApplications.first(where: { $0.id == activeSection }), model.runtimeAvailable {
            applicationContent(application)
        }
    }

    private func applicationContent(_ application: NativeApplicationSettingsSection) -> some View {
        let saved = model.savedSettings["pluginSettings"]?.arrayValue?.first { $0["id"]?.stringValue == application.id }?["value"] ?? .null
        return application.content(saved, model.applicationValueBinding(application.id))
            .environment(\.nativeSettingsInteractionScope, application.id)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: locale.text("界面偏好", "Interface preferences")) {
                ForEach(["appearance", "locale", "glassWorld"], id: \.self) { field in
                    if let error = preferencesErrors[field] { SettingsNotice(error, error: true) }
                }
                SettingsRow(label: locale.text("外观", "Appearance")) {
                    SettingsSelect(label: locale.text("外观", "Appearance"), selection: Binding(get: { preferences.appearance }, set: { value in
                        do { try onSetAppearance(value); preferencesErrors.removeValue(forKey: "appearance") } catch { preferencesErrors["appearance"] = error.localizedDescription }
                    }), options: [
                        .init(value: .system, title: locale.text("跟随系统", "System")),
                        .init(value: .light, title: locale.text("浅色", "Light")),
                        .init(value: .dark, title: locale.text("深色", "Dark"))
                    ]).nativeSettingsControl("appearance")
                }
                SettingsRow(label: locale.text("界面语言", "Interface language")) {
                    SettingsSelect(label: locale.text("界面语言", "Interface language"), selection: Binding(get: { preferences.locale }, set: { value in
                        do { try onSetLocale(value); preferencesErrors.removeValue(forKey: "locale") } catch { preferencesErrors["locale"] = error.localizedDescription }
                    }), options: [
                        .init(value: .chinese, title: locale.text("简体中文", "Simplified Chinese")),
                        .init(value: .english, title: locale.text("英语", "English"))
                    ]).nativeSettingsControl("locale")
                }
                SettingsRow(label: "glass world") {
                    NativeSettingsToggle(value: Binding(get: { preferences.glassWorld }, set: { value in
                        do { try preferences.setGlassWorld(value); preferencesErrors.removeValue(forKey: "glassWorld") }
                        catch { preferencesErrors["glassWorld"] = error.localizedDescription }
                    })).nativeSettingsControl("glassWorld")
                }
            }
            SettingsGroup(title: locale.text("本地 Agent", "Local Agents")) {
                if model.runtimeAvailable { localAgents }
            }.disabled(!model.runtimeAvailable).zIndex(2)
            SettingsGroup(title: locale.text("清空历史数据", "Clear history"), description: locale.text("停止正在运行的任务，并删除本机保存的 thread、报告和 Moku session。", "Stop running tasks and delete threads, reports, and Moku sessions saved on this machine.")) {
                HStack(spacing: 8) {
                    if model.confirmClear && !model.clearing {
                        Button(locale.text("取消清空", "Cancel")) { model.confirmClear = false }.buttonStyle(.bordered)
                    }
                    Button(role: .destructive) { Task { await model.requestClear() } } label: {
                        HStack(spacing: 6) {
                            if model.clearing { SettingsSpinner(size: 14) } else { NativeIcon(name: "Trash2", size: 14, strokeWidth: 2) }
                            Text(model.clearing ? locale.text("清空中…", "Clearing…") : model.confirmClear ? locale.text("确认永久删除", "Confirm permanent deletion") : locale.text("清空全部历史数据", "Clear all history"))
                        }
                    }.buttonStyle(.bordered)
                }.padding(.bottom, 12).disabled(!model.runtimeAvailable || model.clearing || model.draft.status == .saving || model.draft.status == .pending)
            }
        }
    }

    private var localAgents: some View {
        HStack(spacing: 16) {
            ForEach(harnesses, id: \.descriptor.id) { harness in
                let id = harness.descriptor.id.string
                let state = model.installationState(id)
                NativeHarnessSettingsIcon(harness: harness, state: state, showStatus: true) {
                    activateAgent(id, keyboard: false)
                }.help("\(harness.descriptor.displayName.string) · \(statusText(id))")
                    .accessibilityLabel("\(harness.descriptor.displayName.string) · \(statusText(id))")
                    .accessibilityValue(activeAgent == id ? locale.text("已展开", "Expanded") : locale.text("已折叠", "Collapsed"))
                    .focused($focusedAgent, equals: id)
                    .onHover { if $0 && !pinnedAgent { activeAgent = id } }
                    .onKeyPress(keys: [.return, .space]) { _ in activateAgent(id, keyboard: true); return .handled }
            }
            Spacer(minLength: 0)
        }.padding(.bottom, 8)
            .background(SettingsDetailBoundary(region: agentRegion))
            .background(GeometryReader { row in
                Color.clear.onAppear { agentRowBottom = row.frame(in: .named("settings-form")).maxY }
                    .onChange(of: row.frame(in: .named("settings-form")).maxY) { _, bottom in agentRowBottom = bottom }
            })
            .onHover { if !$0 { agentRegion.dismissAfterPointerLeave() } }
            .onChange(of: harnesses.map { "\($0.descriptor.displayName.string): \(statusText($0.descriptor.id.string))" }.joined(separator: "; ")) { _, status in
                NativeSettingsAccessibility.announce(status)
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    if let harness = harnesses.first(where: { $0.descriptor.id.string == activeAgent }) {
                        agentDetail(harness).frame(width: min(380, geometry.size.width))
                            .padding(.top, 10)
                            .background(SettingsDetailBoundary(region: agentRegion))
                            .onHover { if !$0 { agentRegion.dismissAfterPointerLeave() } }
                            .offset(y: geometry.size.height)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -3)), removal: .identity))
                    }
                }
            }
            .animation(.easeOut(duration: 0.14), value: activeAgent != nil)
    }

    private func activateAgent(_ id: String, keyboard: Bool) {
        let state = model.installationState(id)
        guard state != .checking && state != .installing else { return }
        if state == .missing || model.installationErrors[id] != nil {
            activeAgent = id; pinnedAgent = true
            Task { await model.install(id) }
        } else if keyboard {
            activeAgent = id; pinnedAgent = true
            agentRegion.focusFirstInput()
        } else {
            activeAgent = activeAgent == id && pinnedAgent ? nil : id
            pinnedAgent = activeAgent != nil
        }
    }

    private func dismissAgent(returnFocus: Bool = false) {
        let previous = activeAgent
        if returnFocus && focusedAgent != previous { restoringAgentFocus = true; focusedAgent = previous }
        activeAgent = nil; pinnedAgent = false
    }

    private func agentDetail(_ harness: AnyHarnessPlugin) -> some View {
        let id = harness.descriptor.id.string
        let state = model.installationState(id)
        return NativeScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Text(harness.descriptor.displayName.string).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(statusText(id)).font(.system(size: 11)).foregroundStyle(state == .installed ? NativeAppKitPalette.pair(0x458163, 0x8fc7a6).swiftUI : NativeAppKitPalette.settings.muted.swiftUI)
                }
                if state == .missing {
                    Text(locale.text("点击图标即可安装，完成后自动检测。", "Click the icon to install. Detection refreshes automatically."))
                        .modifier(SettingsAgentParagraph()).padding(.top, 10)
                }
                if state == .installing {
                    Text(locale.text("正在下载并安装，你可以继续使用其他功能。", "Downloading and installing. You can continue using other features."))
                        .modifier(SettingsAgentParagraph()).padding(.top, 10)
                }
                if let error = model.installationErrors[id] ?? (state == .error ? model.installations[id]?.message : nil) {
                    NativeScrollView {
                        Text(verbatim: error).modifier(SettingsAgentParagraph(error: true))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { message in
                                Color.clear.onAppear { agentErrorHeight = message.size.height }
                                    .onChange(of: message.size.height) { _, height in agentErrorHeight = height }
                            })
                    }.frame(height: min(130, agentErrorHeight)).padding(.top, 10)
                        .onAppear { NativeSettingsAccessibility.announce(error, urgent: true) }
                        .onChange(of: error) { _, value in NativeSettingsAccessibility.announce(value, urgent: true) }
                }
                if state == .installed || (state == .error && model.installationErrors[id] == nil) {
                    harnessSettings(NativeHarnessSettingsRequest(harnessID: harness.descriptor.id, section: .cli,
                        executionSnapshot: false, scopeID: nil, refreshSequence: model.detailRefreshSequences[id] ?? 0,
                        savedValue: model.savedSettings["harnesses"]?[id] ?? .null,
                        value: model.harnessValueBinding(id, execution: false)))
                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { content in
                    Color.clear.onAppear { agentDetailHeight = content.size.height }
                        .onChange(of: content.size.height) { _, height in agentDetailHeight = height }
                })
        }.frame(height: min(318, agentDetailHeight)).padding(16)
            .environment(\.nativeSettingsLocalAgentDetail, true)
            .background(NativeAppKitPalette.settings.hintSurface.swiftUI, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeAppKitPalette.settings.hintBorder.swiftUI))
            .shadow(color: NativeAppKitPalette.color(0x26384e, alpha: 20 / 255).swiftUI, radius: 14, y: 8)
            .shadow(color: NativeAppKitPalette.color(0x26384e, alpha: 8 / 255).swiftUI, radius: 3, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(harness.descriptor.displayName.string)
    }

    private func requestClose() {
        navigation.requestClose(model: model, onClose: onClose)
    }
    private func sectionLabel(_ id: String) -> String {
        switch id {
        case "general": locale.text("通用", "General")
        case "moku": "Moku"
        default: NativeSettingsRole(section: id)?.tabLabel ?? activeApplications.first(where: { $0.id == id }).map { locale.text($0.label, $0.englishLabel) } ?? id
        }
    }
    private func statusText(_ id: String) -> String {
        switch model.installationState(id) {
        case .checking: locale.text("正在检测…", "Checking…")
        case .installed: locale.text("已安装", "Installed")
        case .missing: locale.text("未安装 · 点击安装", "Not installed · Click to install")
        case .installing: locale.text("正在安装…", "Installing…")
        case .error: model.installationErrors[id] != nil ? locale.text("安装失败 · 点击重试", "Installation failed · Click to retry") : locale.text("检测失败 · 将自动重试", "Detection failed · Retrying automatically")
        }
    }
    private func navigateTab(from id: String, key: KeyEquivalent) {
        guard let index = sections.firstIndex(of: id), !sections.isEmpty else { return }
        let next = key == .home ? 0 : key == .end ? sections.count - 1 : (index + (key == .upArrow || key == .leftArrow ? -1 : 1) + sections.count) % sections.count
        navigation.section = sections[next]; focusedTab = navigation.section
    }
    private func localizedError(_ text: String) -> String {
        if model.draft.conflicted { return locale.text(text, "Settings changed in another client. Your draft is retained. Keep my changes and retry merges independent changes and keeps your edits for overlapping fields.") }
        return text
    }
}

struct NativeHarnessSettingsIcon: View {
    let harness: AnyHarnessPlugin
    let state: NativeHarnessInstallation.Status
    var showStatus = false
    var transparent = false
    var hostSlot = false
    var hideLogo = false
    var preservesDisabledOpacity = false
    var logoTransform = NativeMokuSettingsMotion.Transform()
    var logoOpacity: Double = 1
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    var body: some View {
        Group {
            // The dispatch diagram uses transparent seats so button chrome
            // does not grow with Moku or shift a target away from its path.
            if transparent {
                Button(action: action) {
                    icon
                        .background(hovered ? NativeAppKitPalette.pair(0xedf0f4, 0x292e34).swiftUI : .clear,
                                    in: RoundedRectangle(cornerRadius: 13))
                        .overlay {
                            if focused {
                                RoundedRectangle(cornerRadius: 18).stroke(NativeAppKitPalette.settings.accent.swiftUI, lineWidth: 2)
                                    .padding(-5).allowsHitTesting(false)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(MokuMapButtonStyle())
                    .offset(y: hovered && !hostSlot ? -1 : 0)
                    .opacity(enabled || preservesDisabledOpacity ? 1 : 0.45)
                    .onHover { hovered = $0 }
                    .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.14), value: hovered)
                    .accessibilityRepresentation {
                        Button(harness.descriptor.displayName.string, action: action).disabled(!enabled)
                    }
            } else {
                Button(action: action) { icon }.buttonStyle(.bordered)
            }
        }
        .disabled(showStatus && (state == .checking || state == .installing))
        .accessibilityLabel(harness.descriptor.displayName.string)
    }

    private var icon: some View {
        harness.logo(size: 26)
            .modifier(NativeMokuSettingsTransform(pose: logoTransform, scale: 1, anchor: .center))
            .opacity((hideLogo ? 0 : state == .missing ? 0.48 : 1) * logoOpacity)
            .animation(hostSlot ? .timingCurve(0.25, 0.1, 0.25, 1, duration: hideLogo ? 0.14 : 0.16).delay(hideLogo ? 0.56 : 0.18) : nil, value: hideLogo)
            .frame(width: transparent ? 48 : 36, height: transparent ? 48 : 36)
            .overlay(alignment: .bottomTrailing) {
                if showStatus {
                    Group {
                        if state == .checking || state == .installing { ProgressView().controlSize(.mini) }
                        else { Image(systemName: state == .installed ? "checkmark.circle.fill" : state == .error ? "exclamationmark.circle.fill" : "arrow.down.circle") }
                    }.font(.system(size: 12)).background(.background, in: Circle()).offset(x: 5, y: 5)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct MokuMapButtonStyle: ButtonStyle {
    // PlainButtonStyle dims a disabled label itself; the map owns opacity so
    // its last selected target stays visible while removal is disabled.
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
