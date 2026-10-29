import SwiftUI
import MokuseiCore
@testable import MokuseiUI
import MokuseiPluginUI

/// One configuration surface shared by the onboarding and tabbed Settings demos.
/// Only the surrounding navigation differs; selections have the same owner.
struct SetupConfigurationPanel: View {
    @Bindable var fixture: SetupFixture
    let step: SetupStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var mokuMotion = NativeMokuSettingsAnimationState()
    @Namespace private var selection
    private var ink: Color { colorScheme == .dark ? Color(white: 0.94) : Color(white: 0.14) }
    private var secondaryInk: Color { colorScheme == .dark ? Color(white: 0.73) : Color(white: 0.38) }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.32) }

    var body: some View {
        switch step {
        case .moku: moku
        case .tag: role($fixture.tag, id: "tag")
        case .report: role($fixture.report, id: "report")
        default: EmptyView()
        }
    }

    private var moku: some View {
        NativeMokuSettings(model: fixture.coordination, harnesses: SetupAgent.allCases.map(\.plugin),
            locale: .chinese, focusRequest: 0, motion: mokuMotion,
            harnessSettings: { _ in AnyView(
                profileFields(Binding(get: { fixture.hostProfiles[fixture.host]! }, set: {
                    fixture.hostProfiles[fixture.host] = $0
                }), agent: fixture.host).padding(.top, 12)
            ) }, onCoordinatorFrame: { _, _ in }, onCloseRequest: {}, presentation: .compact)
            .environment(\.nativeSettingsFormPage, true)
            .environment(\.nativeSettingsInteractions, fixture.mapInteractions)
            .environment(\.nativeSettingsInteractionContext, fixture.mapContext)
            .environment(\.nativeSettingsInteractionRefresh, fixture.mapInteractions.refresh)
            .background(NativeSettingsWindowVisibility { mokuMotion.setVisible($0) })
            .onDisappear { mokuMotion.stop() }
    }

    private func role(_ binding: Binding<SetupRole>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 12) {
                    modeButton("跟随 Moku", selected: binding.wrappedValue.followsHost, id: "\(id)-inherit") {
                        binding.wrappedValue.followsHost = true
                    }
                    modeButton("单独配置", selected: !binding.wrappedValue.followsHost, id: "\(id)-custom") {
                        binding.wrappedValue.followsHost = false
                    }
                }
            }

            if binding.wrappedValue.followsHost {
                HStack(spacing: 10) {
                    fixture.host.logo(20)
                    Text(fixture.host.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(fixture.hostProfiles[fixture.host]!.model) · \(fixture.hostProfiles[fixture.host]!.effort)")
                        .font(.system(size: 12)).foregroundStyle(secondaryInk)
                }.padding(.vertical, 8)
            } else {
                agentChoices(binding.agent, prefix: id)
                profileFields(Binding(get: { binding.wrappedValue.profiles[binding.wrappedValue.agent]! }, set: {
                    binding.wrappedValue.profiles[binding.wrappedValue.agent] = $0
                }), agent: binding.wrappedValue.agent)
            }
        }
        .animation(motion, value: binding.wrappedValue.followsHost)
    }

    private func agentChoices(_ binding: Binding<SetupAgent>, prefix: String) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(fixture.available) { agent in
                    let selected = binding.wrappedValue == agent
                    Button { withAnimation(motion) { binding.wrappedValue = agent } } label: {
                        HStack(spacing: 9) {
                            agent.logo(20)
                            Text(agent.name).font(.system(size: 12, weight: selected ? .medium : .regular))
                            if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(ink) }
                        }
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .modifier(SetupChoiceGlass(selected: selected))
                        .glassEffectID("\(prefix)-\(agent.id)", in: selection)
                    }
                    .buttonStyle(.plain)
                    .setupControl("\(prefix)-\(agent.id)", fixture: fixture)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityLabel("\(agent.name)\(selected ? "，已选择" : "")")
                }
            }
        }
    }

    private func profileFields(_ binding: Binding<SetupProfile>, agent: SetupAgent) -> some View {
        let model = Binding<JSONText>(get: { JSONText(binding.wrappedValue.model) },
                                      set: { binding.wrappedValue.model = $0.string })
        let models = agent.models.map { NativeSettingsOption(id: JSONText($0), label: $0) }
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("模型").font(.system(size: 11)).foregroundStyle(secondaryInk)
                NativeModelSelector(value: model, options: models, accessibilityLabel: "模型")
                    .setupControl("profile-model", fixture: fixture)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("推理强度").font(.system(size: 11)).foregroundStyle(secondaryInk)
                NativeModelSelector(value: Binding(get: { JSONText(binding.wrappedValue.effort) },
                    set: { binding.wrappedValue.effort = $0.string }),
                    options: ["低", "适中", "高"].map { .init(id: JSONText($0), label: $0) },
                    presentation: .reasoning, model: .init(value: model, options: models, label: "模型"),
                    accessibilityLabel: "推理强度")
                    .setupControl("profile-effort", fixture: fixture)
            }.frame(width: 150)
        }
    }

    private func modeButton(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(motion, action) } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(selected ? 1 : 0)
            }
            .frame(maxWidth: .infinity).frame(height: 42)
            .modifier(SetupChoiceGlass(selected: selected))
            .glassEffectID(id, in: selection)
        }
        .buttonStyle(.plain).setupControl(id, fixture: fixture)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}

/// Native glass for selectable controls, with a solid accessibility fallback.
private struct SetupChoiceGlass: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .contentShape(Capsule())
            .background {
                if reduceTransparency {
                    Capsule().fill(Color(white: scheme == .dark ? 0.19 : 0.96))
                }
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .overlay {
                Capsule().strokeBorder(selected ? Color.primary.opacity(contrast == .increased ? 0.9 : 0.35) : .clear, lineWidth: 1)
            }
    }
}

extension View {
    @MainActor func setupControl(_ id: String, fixture: SetupFixture) -> some View {
        accessibilityIdentifier(id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { fixture.controlFrames[id] = $0 }
            .onDisappear { fixture.controlFrames.removeValue(forKey: id) }
    }
}
