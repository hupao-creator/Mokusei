import SwiftUI
@testable import MokuseiUI
import MokuseiPluginUI

struct SetupSurface: View {
    @Bindable var fixture: SetupFixture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var mokuMotion = NativeMokuSettingsAnimationState()
    @State private var panelStep = SetupStep.discovery
    @State private var contentVisible = true
    @State private var collapsed = false
    @State private var dockRevealed = false
    @State private var panelRetired = false
    @Namespace private var selection
    private var ink: Color { colorScheme == .dark ? Color(white: 0.94) : Color(white: 0.14) }
    private var secondaryInk: Color { colorScheme == .dark ? Color(white: 0.73) : Color(white: 0.38) }
    private var surface: Color { colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.975) }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.32) }

    var body: some View {
        GeometryReader { geometry in
            let size = panelSize(in: geometry.size)
            let fallback = NativeMokuCapsuleLayout.surface(
                in: NativeMokuCapsuleLayout.frame(in: CGRect(origin: .zero, size: geometry.size), landing: true),
                expanded: true, height: 76, centered: true)
            let measured = fixture.landing.scene.capsuleFrame
            let destination = measured.width > 0 ? measured : fallback
            ZStack {
                if fixture.contrastBackdrop {
                    LinearGradient(colors: [.black, .blue, .red, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                // Keep the real landing scene mounted throughout setup. Only the Dock
                // waits until completion, so no hidden editor can steal setup focus.
                LandingSurface(fixture: fixture.landing, showsDock: fixture.step == .landing,
                    dockOpacity: dockRevealed ? 1 : 0)
                    .allowsHitTesting(fixture.handoffComplete)
                    .accessibilityHidden(!fixture.handoffComplete)
                if !panelRetired {
                    setup
                        .frame(width: size.width, height: size.height)
                        .opacity(contentVisible ? 1 : 0)
                        .frame(width: collapsed ? destination.width : size.width,
                               height: collapsed ? destination.height : size.height)
                        .background {
                            ZStack {
                                NativeMokuCapsuleGlass(interactive: false).opacity(collapsed ? 1 : 0)
                                surface.opacity(reduceTransparency || contrast == .increased ? 1 : 0.96)
                                    .opacity(collapsed ? 0 : 1)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)
                                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.65), lineWidth: 0.8)
                                .opacity(collapsed ? 0 : 1)
                        }
                        .shadow(color: .black.opacity(0.13), radius: collapsed ? 13 : 30, y: collapsed ? 6 : 16)
                        .opacity(dockRevealed ? 0 : 1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { frame in
                            fixture.panelFrame = frame
                            if fixture.step == .landing && fixture.panelSamples.count < 180 { fixture.panelSamples.append(frame) }
                        }
                        .position(x: collapsed ? destination.midX : geometry.size.width / 2,
                                  y: collapsed ? destination.midY : geometry.size.height / 2)
                        .allowsHitTesting(fixture.step != .landing)
                        .accessibilityHidden(fixture.step == .landing)
                        .animation(motion, value: size)
                }
            }
        }
        .coordinateSpace(name: "setup")
        .ignoresSafeArea()
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(fixture.landing.dark ? .dark : .light)
        .task(id: fixture.scanRevision) { await fixture.scan() }
        .task(id: fixture.step) { await transitionToLanding() }
    }

    private func panelSize(in viewport: CGSize) -> CGSize {
        let height: CGFloat
        switch panelStep {
        case .discovery: height = 430
        case .moku: height = 540
        case .tag: height = fixture.tag.followsHost ? 610 : 700
        case .report: height = fixture.report.followsHost ? 610 : 700
        case .landing: height = 610
        }
        return .init(width: min(680, viewport.width - 64), height: min(height, viewport.height - 136))
    }

    @MainActor private func transitionToLanding() async {
        guard fixture.step == .landing else {
            if !collapsed && !panelRetired && contentVisible {
                withAnimation(motion) { panelStep = fixture.step }
                return
            }
            var reset = Transaction(); reset.disablesAnimations = true
            withTransaction(reset) {
                panelStep = fixture.step
                contentVisible = true; collapsed = false; dockRevealed = false; panelRetired = false
                fixture.handoffComplete = false
            }
            return
        }
        do {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { contentVisible = false }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 160))
            // The mounted production Dock owns the destination geometry. Retain the
            // panel until its surface has arrived, then reveal that same native editor.
            withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.78)) { collapsed = true }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 800))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { dockRevealed = true }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 200))
            panelRetired = true; fixture.handoffComplete = true
        } catch { return } // Reset/navigation cancels the old handoff before it can retire a new panel.
    }

    private var setup: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                progress.padding(.top, 16).padding(.bottom, 10)
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            if panelStep == .discovery {
                                discovery.frame(minHeight: max(220, geometry.size.height - 148))
                            } else {
                                Text(panelStep == .moku ? "Moku" : panelStep == .tag ? "找到想找的会话" : "从文字到图示")
                                    .font(.system(size: 25, weight: .medium)).tracking(-0.5)
                                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("setup-title")
                                    .padding(.top, 0).padding(.bottom, 8)
                                Text(panelStep == .moku ? "One mind to orchestrate them all."
                                     : panelStep == .tag ? "A few tags to find them all."
                                     : "Less to read. More to understand.")
                                    .font(.system(size: 13)).foregroundStyle(secondaryInk)
                                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("setup-subtitle")
                                    .padding(.bottom, 16)
                                if panelStep == .tag || panelStep == .report {
                                    SetupCapabilityAnimation(kind: panelStep == .tag ? .tag : .report)
                                        .id(panelStep).padding(.bottom, 16)
                                }
                                stepContent
                            }
                        }
                        .id(panelStep)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                        .frame(maxWidth: panelStep == .discovery ? 680 : 560)
                        .padding(.horizontal, 30).padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                    }
                }
                // macOS can override .hidden when a mouse is attached. The panel
                // keeps wheel/trackpad scrolling but never exposes native scrollers.
                .scrollIndicators(.never)
                footer.frame(maxWidth: 560).padding(.horizontal, 30).padding(.bottom, 22).padding(.top, 8)
            }
        }
        .foregroundStyle(ink)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Capsule().fill(step.rawValue <= panelStep.rawValue ? ink : secondaryInk.opacity(0.2))
                    .frame(width: step == panelStep ? 32 : 20, height: 3)
            }
        }
        .frame(height: 28)
        .animation(motion, value: panelStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(panelStep.rawValue + 1) 步，共 5 步，\(panelStep.label)")
    }

    @ViewBuilder private var stepContent: some View {
        switch panelStep {
        case .discovery: discovery
        case .moku: moku
        case .tag: role($fixture.tag, id: "tag")
        case .report: role($fixture.report, id: "report")
        case .landing: EmptyView()
        }
    }

    private var discovery: some View {
        VStack(spacing: 44) {
            HStack(spacing: 10) {
                if fixture.scanning { ProgressView().controlSize(.small) }
                Text(fixture.scanning ? "正在发现 Agent" : fixture.discovered.isEmpty ? "安装一个 Agent" : "发现 \(fixture.discovered.count) 个 Agent")
                    .font(.system(size: 16, weight: .medium))
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("setup-title")
            }
            if !fixture.scanning && fixture.discovered.isEmpty {
                HStack(spacing: 30) {
                    ForEach(SetupAgent.allCases) { agent in
                        Link(destination: agent.guide) {
                            VStack(spacing: 18) {
                                agent.logo(50).frame(height: 64)
                                Label(agent.name, systemImage: "arrow.up.right").font(.system(size: 12))
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.plain)
                    }
                }
                Text("安装并登录后，重新检测。")
                    .font(.system(size: 12)).foregroundStyle(secondaryInk)
            } else {
                HStack(spacing: 32) {
                    ForEach(fixture.discovered) { agent in
                        VStack(spacing: 26) {
                            agent.logo(78).frame(width: 96, height: 96)
                            Text(agent.name).font(.system(size: 16, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 168)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.9)))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("已发现 \(agent.name)")
                    }
                }.frame(height: 190)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(motion, value: fixture.discovered)
        .animation(motion, value: fixture.scanning)
    }

    private var moku: some View {
        NativeMokuSettings(model: fixture.coordination, harnesses: SetupAgent.allCases.map(\.plugin),
            locale: .chinese, focusRequest: 0, motion: mokuMotion,
            harnessSettings: { _ in AnyView(
                profileFields(Binding(get: { fixture.hostProfiles[fixture.host]! }, set: {
                    fixture.hostProfiles[fixture.host] = $0
                }), agent: fixture.host).padding(.top, 12)
            ) }, onCoordinatorFrame: { _, _ in }, onCloseRequest: {}, presentation: .setup)
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
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型").font(.system(size: 11)).foregroundStyle(secondaryInk)
                    Menu {
                        ForEach(agent.models, id: \.self) { model in
                            Button { binding.wrappedValue.model = model } label: {
                                if binding.wrappedValue.model == model { Label(model, systemImage: "checkmark") }
                                else { Text(model) }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(binding.wrappedValue.model).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }.frame(maxWidth: .infinity, minHeight: 20)
                    }
                    .accessibilityLabel("模型").accessibilityValue(binding.wrappedValue.model)
                    .accessibilityIdentifier("profile-model")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("推理强度").font(.system(size: 11)).foregroundStyle(secondaryInk)
                    Menu {
                        ForEach(["低", "适中", "高"], id: \.self) { effort in
                            Button { binding.wrappedValue.effort = effort } label: {
                                if binding.wrappedValue.effort == effort { Label(effort, systemImage: "checkmark") }
                                else { Text(effort) }
                            }
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Text(binding.wrappedValue.effort)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }.frame(minWidth: 82, minHeight: 20)
                    }
                    .accessibilityLabel("推理强度").accessibilityValue(binding.wrappedValue.effort)
                    .accessibilityIdentifier("profile-effort")
                }
            }
            .font(.system(size: 12)).controlSize(.large)
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(.glass).buttonBorderShape(.capsule)
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

    private var footer: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                if panelStep != .discovery {
                    Button { withAnimation(motion) { fixture.back() } } label: {
                        Label("返回", systemImage: "chevron.left").font(.system(size: 12))
                    }.buttonStyle(.glass).controlSize(.large).buttonBorderShape(.capsule)
                        .foregroundStyle(ink).setupControl("setup-back", fixture: fixture)
                }
                Spacer()
                if panelStep == .discovery && !fixture.scanning && fixture.discovered.isEmpty {
                    Button(action: fixture.rescan) { Label("重新检测", systemImage: "arrow.clockwise").frame(width: 134, height: 24) }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).setupControl("rescan", fixture: fixture)
                } else {
                    Button { withAnimation(motion) { fixture.advance() } } label: {
                        HStack(spacing: 15) {
                            Text(panelStep == .report ? "开始使用 Moku" : "继续")
                            Image(systemName: "arrow.right")
                        }.font(.system(size: 12, weight: .medium)).frame(minWidth: 116, minHeight: 24)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
                    .disabled(!fixture.canContinue).keyboardShortcut(.defaultAction)
                    .opacity(panelStep == .discovery && fixture.scanning ? 0 : 1)
                    .accessibilityHidden(panelStep == .discovery && fixture.scanning)
                    .setupControl("setup-next", fixture: fixture)
                }
            }.frame(height: 44)
        }
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

private extension View {
    @MainActor func setupControl(_ id: String, fixture: SetupFixture) -> some View {
        accessibilityIdentifier(id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { fixture.controlFrames[id] = $0 }
            .onDisappear { fixture.controlFrames.removeValue(forKey: id) }
    }
}
