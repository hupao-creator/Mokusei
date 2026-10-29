import Observation
import SwiftUI
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiUI

enum SettingsDemoTab: String, CaseIterable {
    case general = "General", moku = "Moku", tag = "Tag", report = "Report"
    var step: SetupStep {
        switch self {
        case .general: .discovery
        case .moku: .moku
        case .tag: .tag
        case .report: .report
        }
    }
    var title: String {
        switch self {
        case .general: "通用"
        case .moku: "Moku"
        case .tag: "找到想找的会话"
        case .report: "从文字到图示"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "界面偏好与本地 Agent"
        case .moku: "One mind to orchestrate them all."
        case .tag: "A few tags to find them all."
        case .report: "Less to read. More to understand."
        }
    }
}

@MainActor @Observable final class SettingsTabsFixture {
    let setup = SetupFixture()
    let navigation = NativeSettingsNavigation()
    var tab = SettingsDemoTab.moku
    var open = true
    var opaque = false
    var reduceMotion = false
    var glassWorld = true
    var panelFrame = CGRect.zero

    func close() {
        navigation.requestClose(model: setup.coordination) { _ in open = false }
    }
}

struct SettingsTabsSurface: View {
    @Bindable var fixture: SettingsTabsFixture
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var focusedTab: SettingsDemoTab?
    @State private var hoveredTab: SettingsDemoTab?
    @State private var keyboardNavigation = false
    @Namespace private var selection
    private var motion: Animation? {
        systemReduceMotion || fixture.reduceMotion ? nil : .smooth(duration: 0.22)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LandingSurface(fixture: fixture.setup.landing, showsDock: !fixture.open, glassWorld: fixture.glassWorld)
                    .blur(radius: fixture.open ? 10 : 0)
                    .allowsHitTesting(!fixture.open).accessibilityHidden(fixture.open)
                if fixture.setup.contrastBackdrop && fixture.open {
                    HStack(spacing: 0) {
                        Color.black; Color.blue; Color.red; Color.white
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                if fixture.open {
                    Color.black.opacity(scheme == .dark ? 0.12 : 0.025)
                        .contentShape(Rectangle()).onTapGesture { fixture.close() }
                        .accessibilityHidden(true)
                    panel
                        .frame(width: min(780, geometry.size.width - 48),
                               height: min(680, geometry.size.height - 112))
                        .background {
                            if systemOpaque || fixture.opaque {
                                RoundedRectangle(cornerRadius: 32)
                                    .fill(Color(white: scheme == .dark ? 0.12 : 0.97))
                            }
                        }
                        .glassEffect(systemOpaque || fixture.opaque ? .identity : .regular, in: .rect(cornerRadius: 32))
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                        .shadow(color: .black.opacity(0.13), radius: 30, y: 16)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { fixture.panelFrame = $0 }
                        .transition(.opacity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: "setup").ignoresSafeArea()
        .preferredColorScheme(fixture.setup.landing.dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .background {
            if fixture.open { NativeSettingsEscapeHandler { fixture.close() } }
        }
        .background(SettingsNavigationInputObserver { keyboardNavigation = $0 })
        .nativeSettingsTextEditing(onComposition: { fixture.setup.coordination.draft.composing = $0 },
                                   onBlur: { fixture.setup.coordination.draft.flushText() })
        .animation(motion, value: fixture.open)
        .onAppear { fixture.setup.landing.openControls = { fixture.open = true } }
        .task { await fixture.setup.coordination.refreshInstallations() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        Text(fixture.tab.title).font(.system(size: 25, weight: .medium)).tracking(-0.5)
                            .accessibilityAddTraits(.isHeader).padding(.bottom, 8)
                        Text(fixture.tab.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.bottom, 24)
                        if fixture.tab == .general {
                            general
                        } else {
                            if fixture.tab == .tag || fixture.tab == .report {
                                SetupCapabilityAnimation(kind: fixture.tab == .tag ? .tag : .report)
                                    .padding(.bottom, 24)
                            }
                            SetupConfigurationPanel(fixture: fixture.setup, step: fixture.tab.step)
                        }
                    }
                    .frame(maxWidth: 560).padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 36)
                    .frame(maxWidth: .infinity).id(fixture.tab)
                    .transition(.opacity)
                }
                .scrollIndicators(.never)
                .onChange(of: fixture.tab) { _, _ in reader.scrollTo("top", anchor: .top) }
            }
        }
        .foregroundStyle(.primary)
        .environment(\.nativeSettingsFormPage, true)
        .animation(motion, value: fixture.tab)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 36, height: 36).accessibilityHidden(true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach(SettingsDemoTab.allCases, id: \.self) { tab in
                    Button { fixture.tab = tab; focusedTab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: fixture.tab == tab ? .semibold : .regular))
                            .foregroundStyle(fixture.tab == tab ? Color.primary : Color.secondary)
                            .padding(.horizontal, 12).frame(height: 42)
                            .background {
                                if hoveredTab == tab {
                                    RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.045))
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if fixture.tab == tab {
                                    Capsule().fill(.primary.opacity(0.8)).frame(width: 18, height: 2)
                                        .matchedGeometryEffect(id: "tab-selection", in: selection)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusable(fixture.tab == tab).focused($focusedTab, equals: tab)
                    .modifier(SettingsNavigationFocusRing(visible: keyboardNavigation && focusedTab == tab))
                    .onHover { hoveredTab = $0 ? tab : nil }
                    .accessibilityRepresentation {
                        SettingsTabAccessibilityRepresentation(title: tab.rawValue, selected: fixture.tab == tab,
                                                              focused: focusedTab == tab) {
                            fixture.tab = tab; focusedTab = tab
                        }
                    }
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityAddTraits(fixture.tab == tab ? .isSelected : [])
                    .setupControl("tab-" + tab.rawValue.lowercased(), fixture: fixture.setup)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { event in
                        let tabs = SettingsDemoTab.allCases
                        let index = tabs.firstIndex(of: tab)!
                        let next = event.key == .home ? 0 : event.key == .end ? tabs.count - 1
                            : (index + (event.key == .rightArrow ? 1 : tabs.count - 1)) % tabs.count
                        fixture.tab = tabs[next]; focusedTab = tabs[next]
                        return .handled
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: fixture.close) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    .frame(width: 32, height: 32).contentShape(Circle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭设置")
                .setupControl("settings-close", fixture: fixture.setup)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 32) {
            NativeSettingsGroup(title: "界面偏好") {
                NativeSettingsRow(label: "外观") {
                    NativeSettingsSelect(value: Binding(get: { fixture.setup.landing.dark ? "dark" : "light" },
                        set: { fixture.setup.landing.dark = $0 == "dark" }),
                        options: [.init(id: "light", label: "浅色"), .init(id: "dark", label: "深色")])
                }
                NativeSettingsRow(label: "glass world", inlineControl: true) {
                    NativeSettingsToggle(value: $fixture.glassWorld)
                }
            }
            VStack(alignment: .leading, spacing: 20) {
                Text("本地 Agent").font(.system(size: 13, weight: .medium))
                HStack(spacing: 24) {
                    ForEach(fixture.setup.available) { agent in
                        VStack(spacing: 12) {
                            agent.logo(32).frame(height: 36)
                            Text(agent.name).font(.system(size: 12))
                            Text("已安装").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }.padding(.top, 24)
        .environment(\.nativeSettingsCompactPresentation, true)
    }
}
