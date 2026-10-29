import AppKit
import SwiftUI
import MokuseiCore

/// Lets a custom native editor participate in its row label's activation.
/// Registrations are scoped by owner so dismantling an old control cannot
/// remove the replacement control's handler.
@MainActor public final class NativeSettingsFieldActivation {
    private var owner: UUID?
    private var action: (@MainActor () -> Void)?
    public func install(owner: UUID, action: @escaping @MainActor () -> Void) { self.owner = owner; self.action = action }
    public func remove(owner: UUID) { if self.owner == owner { self.owner = nil; action = nil } }
    func perform() { action?() }
}

struct NativeSettingsField: Sendable {
    var label = ""
    var description: String?
    var invalid = false
    var activation: NativeSettingsFieldActivation?
}
private struct NativeSettingsFieldKey: EnvironmentKey { static let defaultValue = NativeSettingsField() }
private struct NativeSettingsPageKey: EnvironmentKey { static let defaultValue = false }
private struct NativeSettingsViewportWidthKey: EnvironmentKey { static let defaultValue = CGFloat.infinity }
private struct NativeSettingsLocalAgentDetailKey: EnvironmentKey { static let defaultValue = false }
private struct NativeSettingsCLIKey: EnvironmentKey { static let defaultValue = false }
private struct NativeSettingsGroupBottomSpacingKey: EnvironmentKey { static let defaultValue = CGFloat(22) }
public extension EnvironmentValues {
    var nativeSettingsFieldActivation: NativeSettingsFieldActivation? { nativeSettingsField.activation }
    var nativeSettingsFormPage: Bool {
        get { self[NativeSettingsPageKey.self] }
        set { self[NativeSettingsPageKey.self] = newValue }
    }
    /// The complete settings viewport, including its sidebar, not a field's
    /// proposed width. The source uses a 620px media query for shared rows.
    var nativeSettingsViewportWidth: CGFloat {
        get { self[NativeSettingsViewportWidthKey.self] }
        set { self[NativeSettingsViewportWidthKey.self] = newValue }
    }
    var nativeSettingsLocalAgentDetail: Bool {
        get { self[NativeSettingsLocalAgentDetailKey.self] }
        set { self[NativeSettingsLocalAgentDetailKey.self] = newValue }
    }
    var nativeSettingsGroupBottomSpacing: CGFloat {
        get { self[NativeSettingsGroupBottomSpacingKey.self] }
        set { self[NativeSettingsGroupBottomSpacingKey.self] = newValue }
    }
}
extension EnvironmentValues {
    var nativeSettingsField: NativeSettingsField {
        get { self[NativeSettingsFieldKey.self] }
        set { self[NativeSettingsFieldKey.self] = newValue }
    }
    var nativeSettingsCLI: Bool {
        get { self[NativeSettingsCLIKey.self] }
        set { self[NativeSettingsCLIKey.self] = newValue }
    }
}

public struct NativeSettingsFormScope<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content.environment(\.nativeSettingsFormPage, true).font(NativeTypography.settings(size: 13)) }
}

public struct NativeSettingsGroup<Content: View>: View {
    public let title: String?
    public let description: String?
    private let action: AnyView?
    private let content: Content
    @Environment(\.nativeSettingsGroupBottomSpacing) private var bottomSpacing
    @Environment(\.nativeSettingsFormPage) private var settingsFormPage
    @Environment(\.nativeSettingsCompactPresentation) private var onboarding
    public init(title: String? = nil, description: String? = nil, action: AnyView? = nil,
                @ViewBuilder content: () -> Content) {
        self.title = title; self.description = description; self.action = action; self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if (!onboarding && (title?.isEmpty == false || description?.isEmpty == false)) || action != nil {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let title, !title.isEmpty, !onboarding {
                            Text(title).font(NativeTypography.settings(size: settingsFormPage ? 14 : 13, weight: 600))
                                .foregroundStyle(NativePlatformPalette.settings.text.swiftUI).fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let description, !description.isEmpty, !onboarding {
                            Text(description).modifier(NativeSettingsTextMetrics(size: 12, lineHeight: 18.6))
                                .foregroundStyle(NativePlatformPalette.settings.muted.swiftUI).padding(.top, title?.isEmpty == false ? 0 : 5)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    action
                }.padding(.bottom, 10)
            }
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, bottomSpacing)
    }
}

public struct NativeSettingsRow<Content: View>: View {
    public enum Layout: Sendable { case inline, stacked }
    public let label: String
    public let description: String?
    public let error: String?
    public let layout: Layout
    public let inlineControl: Bool
    private let content: Content
    @Environment(\.nativeSettingsViewportWidth) private var viewportWidth
    @Environment(\.nativeSettingsLocalAgentDetail) private var localAgentDetail
    @Environment(\.nativeSettingsFormPage) private var settingsFormPage
    @State private var hintVisible = false
    @State private var activation = NativeSettingsFieldActivation()
    public init(label: String, description: String? = nil, error: String? = nil,
                layout: Layout = .inline, inlineControl: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label; self.description = description; self.error = error; self.layout = layout
        self.inlineControl = inlineControl; self.content = content()
    }
    private var compact: Bool { viewportWidth <= 620 }
    private var stacked: Bool { compact ? !inlineControl : layout == .stacked }
    public var body: some View {
        NativeSettingsColumns(stacked: stacked, compact: compact, inlineControl: inlineControl, localAgentDetail: localAgentDetail) {
            VStack(alignment: .leading, spacing: 5) {
                if !compact, layout == .inline, let description, !description.isEmpty {
                    NativeSettingsDescriptionHint(label: label, description: description,
                                                  onVisibilityChange: { hintVisible = $0 },
                                                  onActivateLabel: { activation.perform() })
                } else {
                    Text(label).modifier(NativeSettingsTextMetrics(size: localAgentDetail ? 11 : settingsFormPage ? 14 : 13,
                                                                  weight: localAgentDetail ? 400 : 500,
                                                                  lineHeight: localAgentDetail ? 16.5 : settingsFormPage ? 21 : 19.5))
                        .foregroundStyle(localAgentDetail ? NativePlatformPalette.settings.muted.swiftUI : NativePlatformPalette.settings.text.swiftUI)
                        .contentShape(Rectangle()).onTapGesture { activation.perform() }
                }
                if compact || layout == .stacked, let description, !description.isEmpty {
                    Text(description).modifier(NativeSettingsTextMetrics(size: 12, lineHeight: 18.6))
                        .foregroundStyle(NativePlatformPalette.settings.muted.swiftUI)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                content
                    .environment(\.nativeSettingsField, NativeSettingsField(label: label, description: description,
                                                                            invalid: error?.isEmpty == false, activation: activation))
                if let error, !error.isEmpty {
                    Text(error).modifier(NativeSettingsTextMetrics(size: 12, lineHeight: 18))
                        .foregroundStyle(NativePlatformPalette.pair(0xad413c, 0xf0988d).swiftUI)
                        .padding(.top, localAgentDetail ? 10 : 12).padding(.bottom, localAgentDetail ? 0 : 12)
                }
            }
        }.padding(.top, localAgentDetail ? 14 : 15).padding(.bottom, localAgentDetail ? 0 : 15)
            .zIndex(hintVisible ? 6 : 0)
            .accessibilityElement(children: .contain)
            .onChange(of: error) { _, error in
                if let error { NativeSettingsAccessibility.announce(error, urgent: true) }
            }
    }
}

/// Original two-column sizing; fields use 44% with a 150-point minimum.
private struct NativeSettingsColumns: SwiftUI.Layout {
    let stacked: Bool
    let compact: Bool
    let inlineControl: Bool
    let localAgentDetail: Bool
    private var gap: CGFloat { localAgentDetail ? 6 : compact ? 9 : stacked ? 10 : 28 }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let sizes = measured(width: width, subviews: subviews)
        return CGSize(width: width, height: max(localAgentDetail ? 0 : 32, stacked ? sizes[0].height + sizes[1].height + gap : max(sizes[0].height, sizes[1].height)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let sizes = measured(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: stacked ? bounds.minY : bounds.midY - sizes[0].height / 2), proposal: ProposedViewSize(sizes[0]))
        subviews[1].place(at: CGPoint(x: stacked ? bounds.minX : bounds.maxX - sizes[1].width,
                                     y: stacked ? bounds.minY + sizes[0].height + gap : bounds.midY - sizes[1].height / 2), proposal: ProposedViewSize(sizes[1]))
    }
    private func measured(width: CGFloat, subviews: Subviews) -> [CGSize] {
        guard subviews.count == 2 else { return [.zero, .zero] }
        if stacked { return subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) } }
        let control = compact && inlineControl ? min(width, subviews[1].sizeThatFits(.unspecified).width) : max(150, width * 0.44)
        return [subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - control - gap), height: nil)),
                subviews[1].sizeThatFits(ProposedViewSize(width: control, height: nil))]
    }
}

private struct NativeSettingsTextMetrics: ViewModifier {
    let size: CGFloat
    var weight: CGFloat = 400
    let lineHeight: CGFloat
    func body(content: Content) -> some View {
        let nativeHeight = nativeSettingsLineHeight(size: size, weight: weight)
        let extra = max(0, lineHeight - nativeHeight)
        content.font(NativeTypography.settings(size: size, weight: weight)).lineSpacing(extra)
            .padding(.vertical, extra / 2).fixedSize(horizontal: false, vertical: true)
    }
}

private struct NativeSettingsInputDecoration: ViewModifier {
    let focused: Bool
    @Environment(\.nativeSettingsField) private var field
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeSettingsLocalAgentDetail) private var localAgentDetail
    func body(content: Content) -> some View {
        let small = localAgentDetail
        content.font(NativeTypography.settings(size: small ? 11 : 13)).foregroundStyle(NativePlatformPalette.settings.text.swiftUI)
            .padding(.horizontal, small ? 9 : 10).padding(.vertical, small ? 0 : 7)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(NativePlatformPalette.settings.input.swiftUI, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(field.invalid ? NativePlatformPalette.settings.danger.swiftUI : focused && enabled ? NativePlatformPalette.settings.accent.swiftUI : NativePlatformPalette.settings.inputBorder.swiftUI))
            .overlay {
                if focused && enabled {
                    RoundedRectangle(cornerRadius: 10.5).stroke(NativePlatformPalette.color(0x426b9a, alpha: 0.22).swiftUI, lineWidth: 3)
                        .padding(-3.5).allowsHitTesting(false).transition(.identity)
                }
            }
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12), value: focused)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12), value: field.invalid)
            .opacity(enabled ? 1 : 0.5).accessibilityLabel(field.label).accessibilityHint(field.description ?? "")
    }
}

public struct NativeSettingsInput: View {
    @Binding private var value: String
    public let placeholder: String
    public let secret: Bool
    @FocusState private var focused: Bool
    @Environment(\.nativeSettingsField) private var field
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeSettingsFormPage) private var formPage
    public init(value: Binding<String>, placeholder: String = "", secret: Bool = false) {
        _value = value; self.placeholder = placeholder; self.secret = secret
    }
    public var body: some View {
        Group {
            if formPage {
                input.textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityLabel(field.label).accessibilityHint(field.description ?? "")
            } else {
                input.textFieldStyle(.plain).focusEffectDisabled().focused($focused)
                    .modifier(NativeSettingsInputDecoration(focused: focused))
            }
        }
            .background(NativeSettingsActivationRegistration(activation: field.activation) { if enabled { focused = true } })
            .background {
                if !secret {
                    NativeSettingsControlRegistration(descriptor: .object([
                        "kind": .text("input"), "label": .text(field.label), "value": .text(value),
                        "invalid": .bool(field.invalid), "operations": .array([.text("set")])
                    ])) { _, next in
                        guard case .string(let text) = next, JSONText(text.string) == text, text.codeUnits.count <= 20_000 else {
                            throw NativeSettingsControlError("invalid_request", "Text requires at most 20000 UTF-16 units")
                        }
                        value = text.string
                    }
                }
            }
    }
    @ViewBuilder private var input: some View {
        if secret { SecureField(placeholder, text: $value) }
        else { TextField(placeholder, text: $value) }
    }
}

public struct NativeSettingsTextarea: View {
    @Binding private var value: String
    public let minHeight: CGFloat
    @State private var height: CGFloat = 0
    @Environment(\.nativeSettingsField) private var field
    @Environment(\.nativeSettingsFormPage) private var formPage
    @Environment(\.locale) private var locale
    public init(value: Binding<String>, minHeight: CGFloat = 112, rows: Int? = nil) {
        _value = value; self.minHeight = minHeight
        _height = State(initialValue: max(minHeight, rows.map { CGFloat(max(1, $0)) * 18.2 + 16 } ?? minHeight))
    }
    public var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            NativeSettingsTextEditor(value: $value, height: $height, minimumHeight: max(34, minHeight),
                                 label: field.label, description: field.description, invalid: field.invalid,
                                 activation: field.activation)
                .frame(maxWidth: .infinity).frame(height: max(34, minHeight, height))
            if formPage {
                Stepper(locale.language.languageCode?.identifier == "zh" ? "编辑器高度" : "Editor height",
                        value: $height, in: max(34, minHeight)...CGFloat.greatestFiniteMagnitude, step: 28)
                    .controlSize(.small)
            }
        }
    }
}

public struct NativeSettingsOption: Identifiable, Hashable, Sendable {
    public let id: JSONText
    public let label: String
    public let disabled: Bool
    public init(id: JSONText, label: String, disabled: Bool = false) { self.id = id; self.label = label; self.disabled = disabled }
}
public struct NativeSettingsSelect: View {
    @Binding private var value: JSONText
    public let options: [NativeSettingsOption]
    public let accessibilityLabel: String?
    @Environment(\.nativeSettingsField) private var field
    public init(value: Binding<JSONText>, options: [NativeSettingsOption], accessibilityLabel: String? = nil) {
        _value = value; self.options = options; self.accessibilityLabel = accessibilityLabel
    }
    public var body: some View {
        NativeSettingsSelectPopover(selection: $value, options: options,
                                    accessibilityLabel: accessibilityLabel ?? field.label,
                                    accessibilityDescription: field.description, invalid: field.invalid)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
    }
}

public struct NativeSettingsToggle: View {
    @Binding private var value: Bool
    @Environment(\.nativeSettingsField) private var field
    @Environment(\.nativeSettingsFormPage) private var formPage
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    public init(value: Binding<Bool>) { _value = value }
    public var body: some View {
        Group {
            if formPage {
                Toggle(field.label, isOn: Binding(get: { value }, set: { next in
                    NativeSettingsChangeContext.withDiscreteChange { value = next }
                })).labelsHidden().toggleStyle(.switch).focused($focused)
                    .background(NativeSettingsActivationRegistration(activation: field.activation) {
                        guard enabled else { return }
                        focused = true
                        NativeSettingsChangeContext.withDiscreteChange { value.toggle() }
                    })
            } else {
                Toggle(field.label, isOn: $value).labelsHidden().toggleStyle(NativeSettingsSwitchStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(field.label).accessibilityHint(field.description ?? "")
            .background(NativeSettingsControlRegistration(descriptor: .object([
                "kind": .text("toggle"), "label": .text(field.label), "value": .bool(value),
                "operations": .array([.text("set")])
            ])) { _, next in
                guard case .bool(let selected) = next else { throw NativeSettingsControlError("invalid_request", "Toggle requires a Boolean") }
                NativeSettingsChangeContext.withDiscreteChange { value = selected }
            })
    }
}

/// Refresh the activation closure with each binding update; retaining an
/// onAppear closure would target a stale setting when a row is reused.
struct NativeSettingsActivationRegistration: NSViewRepresentable {
    let activation: NativeSettingsFieldActivation?
    let action: @MainActor () -> Void
    func makeNSView(context: Context) -> Registration { Registration() }
    func updateNSView(_ view: Registration, context: Context) { view.install(activation, action: action) }
    static func dismantleNSView(_ view: Registration, coordinator: ()) { view.remove() }
    @MainActor final class Registration: NSView {
        private weak var activation: NativeSettingsFieldActivation?
        private let owner = UUID()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func install(_ activation: NativeSettingsFieldActivation?, action: @escaping @MainActor () -> Void) {
            remove(); self.activation = activation; activation?.install(owner: owner, action: action)
        }
        func remove() { activation?.remove(owner: owner); activation = nil }
    }
}

func nativeSettingsLineHeight(size: CGFloat, weight: CGFloat = 400) -> CGFloat {
    let font = NativeTypography.settingsPlatformFont(size: size, weight: weight)
    return NSLayoutManager().defaultLineHeight(for: font)
}
private struct NativeSettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeSettingsField) private var field
    @FocusState private var focused: Bool
    @State private var keyboardFocused = false
    func makeBody(configuration: Configuration) -> some View {
        Button {
            keyboardFocused = !Self.pointerEvent
            NativeSettingsChangeContext.withDiscreteChange { configuration.isOn.toggle() }
        } label: {
            Capsule().fill(configuration.isOn ? NativePlatformPalette.settings.accent.swiftUI : NativePlatformPalette.pair(0xc6c8cb, 0x66707d).swiftUI)
                .overlay(alignment: .leading) {
                    Circle().fill(NativePlatformPalette.pair(0xffffff, 0x2c2d29).swiftUI)
                        .shadow(color: .black.opacity(2.0 / 15), radius: 1.5, y: 1)
                        .frame(width: 16, height: 16).offset(x: configuration.isOn ? 14 : 2)
                }.frame(width: 32, height: 20)
        }.buttonStyle(.plain).focusEffectDisabled().focused($focused).opacity(enabled ? 1 : 0.5)
            .overlay {
                if focused && keyboardFocused && enabled {
                    Capsule().stroke(NativePlatformPalette.color(0x426b9a, alpha: 0.22).swiftUI, lineWidth: 3)
                        .padding(-3.5).allowsHitTesting(false).transition(.identity)
                }
            }
            .onChange(of: focused) { _, focused in keyboardFocused = focused && !Self.pointerEvent }
            .background(NativeSettingsActivationRegistration(activation: field.activation) {
                guard enabled else { return }
                keyboardFocused = false; focused = true
                NativeSettingsChangeContext.withDiscreteChange { configuration.isOn.toggle() }
            })
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.15), value: configuration.isOn)
            .accessibilityRepresentation {
                Toggle(isOn: Binding(get: { configuration.isOn }, set: { value in
                    NativeSettingsChangeContext.withDiscreteChange { configuration.isOn = value }
                })) { configuration.label }
            }
    }
    private static var pointerEvent: Bool { NativePlatformInput.isPointerEvent }
}

public struct NativeSettingsUseDefaults<Content: View>: View {
    @Binding private var value: Bool
    public let label: String?
    private let content: Content
    @Environment(\.locale) private var locale
    public init(value: Binding<Bool>, label: String? = nil, @ViewBuilder content: () -> Content) {
        _value = value; self.label = label; self.content = content()
    }
    public var body: some View {
        NativeSettingsRow(label: label ?? NativePluginLocalization.localize("使用默认配置", locale: locale),
                          description: NativePluginLocalization.localize("关闭后可自定义新建 Thread 使用的配置。", locale: locale), inlineControl: true) {
            NativeSettingsToggle(value: $value)
        }
        if !value { content }
    }
}

public struct NativeSettingsNotice: View {
    @State private var interactionID = UUID().uuidString
    public enum Kind: Sendable { case info, error, warning, success }
    public let message: String
    public let kind: Kind
    private let action: AnyView?
    private let leading: AnyView?
    @Environment(\.nativeSettingsLocalAgentDetail) private var localAgentDetail
    @Environment(\.nativeSettingsCLI) private var cli
    public init(message: String, kind: Kind = .info, action: AnyView? = nil, leading: AnyView? = nil) {
        self.message = message; self.kind = kind; self.action = action; self.leading = leading
    }
    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 7) {
                leading
                Text(message).modifier(NativeSettingsTextMetrics(size: localAgentDetail ? 11 : 12,
                                                                lineHeight: (localAgentDetail ? 11 : 12) * (kind == .error ? 1.5 : 1.55)))
                    .textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            action
        }.font(NativeTypography.settings(size: localAgentDetail ? 11 : 12)).foregroundStyle(color)
            .padding(.top, (cli ? 3 : 12) + (localAgentDetail ? 10 : 0)).padding(.bottom, cli ? 5 : 12)
            .background(NativeSettingsControlRegistration(descriptor: .object([
                "kind": .text("notice"), "severity": .text(String(describing: kind)), "value": .text(message),
                "operations": .array([])
            ])) { _, _ in }.nativeSettingsControl("notice." + interactionID))
            .onAppear { if kind == .error { NativeSettingsAccessibility.announce(message, urgent: true) } }
            .onChange(of: message) { _, message in NativeSettingsAccessibility.announce(message, urgent: kind == .error) }
    }
    private var color: Color {
        switch kind {
        case .info: NativePlatformPalette.settings.muted.swiftUI
        case .error: NativePlatformPalette.pair(0xad413c, 0xf0988d).swiftUI
        case .warning: NativePlatformPalette.pair(0x906b28, 0xe6bd78).swiftUI
        case .success: NativePlatformPalette.pair(0x3c745a, 0x8fc7a6).swiftUI
        }
    }
}

@MainActor public enum NativeSettingsAccessibility {
    /// Native equivalent of the source page's status and alert live regions.
    public static func announce(_ message: String, urgent: Bool = false) {
        guard !message.isEmpty, NSApp.isActive else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: (urgent ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
    }
}

/// CLI discovery status has its own compact source layout, rather than the
/// settings row's label/control grid. Discovery and refresh remain host-owned.
public struct NativeSettingsCliStatus: View {
    public let label: String?
    public let status: String
    public let kind: NativeSettingsNotice.Kind
    public let error: String?
    public let separated: Bool
    private let action: AnyView?
    @Environment(\.nativeSettingsLocalAgentDetail) private var localAgentDetail
    public init(label: String? = nil, status: String, kind: NativeSettingsNotice.Kind = .info,
                error: String? = nil, separated: Bool = false, action: AnyView? = nil) {
        self.label = label; self.status = status; self.kind = kind; self.error = error; self.separated = separated
        self.action = action
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label, !label.isEmpty {
                Text(label).modifier(NativeSettingsTextMetrics(size: 13, weight: 500, lineHeight: 19.5))
                    .foregroundStyle(NativePlatformPalette.settings.text.swiftUI).padding(.bottom, 4)
            }
            NativeSettingsNotice(message: status, kind: kind, action: action)
            if let error, !error.isEmpty { NativeSettingsNotice(message: error, kind: .error) }
        }.environment(\.nativeSettingsCLI, true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, localAgentDetail ? 0 : 10)
            .overlay(alignment: .top) {
                if separated { Rectangle().fill(NativePlatformPalette.settings.line.swiftUI).frame(height: 1) }
            }
    }
}
