import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Point geometry of the Settings header. The leading seat belongs to Moku's
/// face: the resident Dock draws the same eyes into it while Settings owns the
/// shell, so the page never mounts a second character and the face can travel
/// from the capsule without being replaced. Keep both call sites on these
/// constants so the eye lands in the reserved column exactly.
enum NativeSettingsHeaderLayout {
    static let horizontalInset: CGFloat = 22
    static let topInset: CGFloat = 16
    static let bottomInset: CGFloat = 12
    static let rowHeight: CGFloat = 42
    /// Placeholder the header reserves at the leading edge, left of the tabs.
    static let faceSlot = CGSize(width: 30, height: 30)
    /// Centre of that column in panel-local points.
    static var faceCenter: CGPoint {
        CGPoint(x: horizontalInset + faceSlot.width / 2, y: topInset + rowHeight / 2)
    }
}

/// The scroll document reports its natural height, independent of the clipped
/// viewport. The Dock can fit every tab without changing the form's design.
struct NativeSettingsPreferredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor public struct NativeSettingsPage: View {
    public let model: NativeSettingsModel
    public let locale: DesktopLocale
    public let harnesses: [AnyHarnessPlugin]
    public let applicationSections: [NativeApplicationSettingsSection]
    public let harnessSettings: (NativeHarnessSettingsRequest) -> AnyView
    public let onClose: (CGRect) -> Void
    public var mokuController: MokuCharacterController?
    public var onCoordinatorFrame: (CGRect?, Bool) -> Void
    @State private var navigation: NativeSettingsNavigation
    @FocusState private var focusedTab: String?
    @FocusState private var focusedBack: Bool
    @State private var settingsContentHeight: CGFloat = 0
    @State private var hoveredTab: String?
    @State private var keyboardNavigation = false
    @State private var mokuMotion = NativeMokuSettingsAnimationState()
    @State private var animationVisits = NativeSettingsAnimationVisits()
    @Namespace private var tabSelection

    public init(model: NativeSettingsModel, navigation: NativeSettingsNavigation? = nil, locale: DesktopLocale, harnesses: [AnyHarnessPlugin],
                applicationSections: [NativeApplicationSettingsSection] = [],
                harnessSettings: @escaping (NativeHarnessSettingsRequest) -> AnyView,
                onClose: @escaping (CGRect) -> Void,
                mokuController: MokuCharacterController? = nil,
                onCoordinatorFrame: @escaping (CGRect?, Bool) -> Void = { _, _ in }) {
        self.model = model
        _navigation = State(initialValue: navigation ?? NativeSettingsNavigation())
        self.locale = locale; self.harnesses = harnesses; self.onClose = onClose
        self.applicationSections = applicationSections; self.harnessSettings = harnessSettings
        self.mokuController = mokuController; self.onCoordinatorFrame = onCoordinatorFrame
    }

    private var activeApplications: [NativeApplicationSettingsSection] {
        applicationSections.filter { definition in sections.contains(definition.id) }
    }
    private var sections: [String] { NativeSettingsNavigation.sections(model: model, applications: applicationSections) }
    private var activeSection: String { navigation.activeSection(in: sections) }
    private var busy: Bool { model.clearing }

    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.height < 220 {
                // At extreme app zoom, fixed chrome can consume the viewport.
                // Scroll the whole shell as well, retaining every real control.
                ScrollViewReader { reader in
                    NativeScrollView {
                        panel(width: geometry.size.width).frame(minHeight: 360).id("settings-shell-top")
                    }.onChange(of: activeSection) { _, _ in reader.scrollTo("settings-shell-top", anchor: .top) }
                }.environment(\.nativeSettingsViewportWidth, geometry.size.width)
            } else {
                panel(width: geometry.size.width)
                    .environment(\.nativeSettingsViewportWidth, geometry.size.width)
            }
        }.preference(key: NativeSettingsPreferredHeightKey.self,
                      value: settingsContentHeight
                        + NativeSettingsHeaderLayout.topInset + NativeSettingsHeaderLayout.rowHeight
                        + NativeSettingsHeaderLayout.bottomInset + 18 + 36)
            .font(.system(size: 13)).foregroundStyle(NativeAppKitPalette.settings.text.swiftUI)
            .tint(NativeAppKitPalette.settings.accent.swiftUI)
            .environment(\.locale, Locale(identifier: locale.rawValue))
            .environment(\.nativeSettingsInteractions, navigation.interactions)
            .environment(\.nativeSettingsInteractionContext, navigation.interactionContext(section: activeSection))
            .environment(\.nativeSettingsInteractionRefresh, navigation.interactions.refresh)
            .nativeSettingsTextEditing(onComposition: { model.draft.composing = $0 },
                                       onBlur: { model.draft.flushText() })
            .background(NativeSettingsEscapeHandler { requestClose() })
            .background(SettingsNavigationInputObserver { keyboardNavigation = $0 })
            .onAppear {
                model.draft.beginPageEditing()
                navigation.mounted = true
                focusedBack = true
                model.operationError = nil
            }
            .onDisappear {
                navigation.mounted = false
                mokuMotion.stop(); onCoordinatorFrame(nil, true)
                animationVisits.reset()
            }
            .onChange(of: sections, initial: true) { _, _ in
                navigation.section = activeSection
            }
            .onChange(of: model.runtimeAvailable) { _, available in
                if available { Task { await model.refreshInstallations() } }
            }
            .onChange(of: navigation.section) { _, _ in
                if navigation.section != "moku" { onCoordinatorFrame(nil, true) }
            }
            .onExitCommand { requestClose() }
    }

    private func panel(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { reader in
                NativeScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !model.runtimeAvailable {
                            SettingsNotice(locale.text("连接后台服务后可修改 Agent 配置。", "Connect to the runtime service to edit Agent configuration."))
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
                    })
                        .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 36)
                        // Overflow must not shift the centered form. Horizontal
                        // padding keeps controls clear of the native gutter.
                        .frame(width: width)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        // Include the top inset in the scroll target. An anchor
                        // inside it discards 18pt only when the form overflows.
                        .id("top")
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
            // The Dock moves its resident eyes into this reserved header seat.
            Color.clear.frame(width: NativeSettingsHeaderLayout.faceSlot.width, height: NativeSettingsHeaderLayout.faceSlot.height)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        tabs.frame(minWidth: geometry.size.width)
                    }.scrollIndicators(.never)
                        .onChange(of: activeSection) { _, id in reader.scrollTo(id, anchor: .center) }
                }
            }.frame(height: NativeSettingsHeaderLayout.rowHeight)
            Button(action: requestClose) {
                NativeIcon(name: "X", size: 14, strokeWidth: 2)
                    .frame(width: 30, height: 30).contentShape(Circle())
            }.buttonStyle(.plain).disabled(busy).focused($focusedBack)
                .foregroundStyle(.secondary)
                .accessibilityLabel(locale.text("关闭设置", "Close settings"))
                .accessibilityIdentifier("settings-close")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { navigation.returnRect = $0 }
        }.padding(.horizontal, NativeSettingsHeaderLayout.horizontalInset)
            .padding(.top, NativeSettingsHeaderLayout.topInset)
            .padding(.bottom, NativeSettingsHeaderLayout.bottomInset)
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
            .animation(.smooth(duration: 0.22), value: activeSection)
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
        if let role = NativeSettingsRole(section: activeSection), model.runtimeAvailable {
            NativeRoleConfigurationPanel(role: role, harnesses: animationHarnesses, locale: locale, showsHeading: false,
                                         visitPlaybackStarted: role == .tag ? $animationVisits.tag : role == .report ? $animationVisits.report : nil) {
                if role == .moku {
                    NativeMokuSettings(model: model, harnesses: harnesses, locale: locale, focusRequest: navigation.focusRequest, motion: mokuMotion,
                        harnessSettings: harnessSettings, controller: mokuController, onCoordinatorFrame: onCoordinatorFrame,
                        onCloseRequest: requestClose, presentation: .compact, showsRoutingGuidance: true, showsMapGlass: true)
                } else if let application = activeApplications.first(where: { $0.id == activeSection }) {
                    applicationContent(application)
                }
            }.environment(\.nativeSettingsEditorDrafts, model.draft.editorDrafts)
                .id(activeSection + model.draft.editorDrafts.generation.uuidString)
        } else if let application = activeApplications.first(where: { $0.id == activeSection }), model.runtimeAvailable {
            applicationContent(application)
        }
    }

    private func applicationContent(_ application: NativeApplicationSettingsSection) -> some View {
        let saved = model.savedSettings["pluginSettings"]?.arrayValue?.first { $0["id"]?.stringValue == application.id }?["value"] ?? .null
        return application.content(saved, model.applicationValueBinding(application.id))
            .environment(\.nativeSettingsInteractionScope, application.id)
    }

    private func requestClose() {
        navigation.requestClose(model: model, onClose: onClose)
    }
    private func sectionLabel(_ id: String) -> String {
        NativeSettingsRole(section: id)?.tabLabel
            ?? activeApplications.first(where: { $0.id == id }).map { locale.text($0.label, $0.englishLabel) }
            ?? id
    }
    private func navigateTab(from id: String, key: KeyEquivalent) {
        guard let index = sections.firstIndex(of: id), !sections.isEmpty else { return }
        let next = key == .home ? 0 : key == .end ? sections.count - 1 : (index + (key == .upArrow || key == .leftArrow ? -1 : 1) + sections.count) % sections.count
        navigation.section = sections[next]; focusedTab = navigation.section
    }
    private func localizedError(_ text: String) -> String {
        if text == NativeSettingsNavigation.incompleteEditError {
            return locale.text(text, "Complete the model configuration before closing Settings.")
        }
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
