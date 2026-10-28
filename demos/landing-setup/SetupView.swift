import SwiftUI
@testable import MokuseiUI
import MokuseiPluginUI

struct SetupSurface: View {
    @Bindable var fixture: SetupFixture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var selection
    private let accent = Color(red: 0.32, green: 0.42, blue: 0.34)
    private var selectionInk: Color { colorScheme == .dark ? Color(red: 0.66, green: 0.79, blue: 0.67) : accent }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.32) }

    var body: some View {
        Group {
            if fixture.step == .landing {
                LandingSurface(fixture: fixture.landing)
                    .transition(.opacity)
            } else {
                setup
                    .transition(.opacity)
            }
        }
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(fixture.landing.dark ? .dark : .light)
        .task(id: fixture.scanRevision) { await fixture.scan() }
    }

    private var setup: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                progress.padding(.top, geometry.size.width < 800 ? 76 : 36).padding(.bottom, 26)
                ScrollView {
                    VStack(spacing: 0) {
                        NativeMokuBlinkingEyes(expression: .idle, focus: fixture.step == .discovery ? 0 : 1)
                            .frame(width: 168, height: 44)
                            .background { NativeMokuCapsuleGlass(interactive: false) }
                            .padding(.bottom, 26)
                        VStack(spacing: 0) {
                            heading
                            stepContent.padding(.top, 30)
                        }
                        .id(fixture.step)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 30)
                    .padding(.top, max(12, (geometry.size.height - 730) * 0.24))
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                footer.frame(maxWidth: 560).padding(.horizontal, 30).padding(.bottom, 30).padding(.top, 12)
            }
            .overlay(alignment: .topLeading) { NativeWindowNavigationView(action: nil) }
        }
        .coordinateSpace(name: "setup")
        .modifier(NativeWorkspaceWindowSurface())
        .tint(accent)
    }

    private var progress: some View {
        HStack(spacing: 0) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                if step != .discovery {
                    Rectangle().fill(.primary.opacity(0.10)).frame(width: 24, height: 1).padding(.horizontal, 8)
                }
                HStack(spacing: 6) {
                    Group {
                        if step.rawValue < fixture.step.rawValue { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
                        else { Text("\(step.rawValue + 1)").font(.system(size: 10, weight: .medium, design: .monospaced)) }
                    }
                    .frame(width: 20, height: 20)
                    .background(step == fixture.step ? accent.opacity(0.13) : .clear, in: Circle())
                    Text(step.label).font(.system(size: 11, weight: step == fixture.step ? .semibold : .regular))
                }
                .foregroundStyle(step.rawValue <= fixture.step.rawValue ? Color.primary : Color.secondary.opacity(0.6))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("第 \(step.rawValue + 1) 步，\(step.label)\(step == fixture.step ? "，当前步骤" : "")")
            }
        }
        .frame(height: 28)
    }

    private var heading: some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 28, weight: .medium)).tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("setup-title")
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var title: String {
        switch fixture.step {
        case .discovery: !fixture.scanning && fixture.installed.isEmpty ? "先安装一个 Agent" : "连接你的 Agent"
        case .moku: "让 Moku 协调你的工作"
        case .tag: "让任务井然有序"
        case .report: "让进展清晰可见"
        case .landing: ""
        }
    }
    private var subtitle: String {
        switch fixture.step {
        case .discovery: !fixture.scanning && fixture.installed.isEmpty
            ? "还没有发现本机 Agent。任选一个安装并登录，再回来继续。"
            : "发现本机已安装的 Agent，沿用它们自己的账号与模型。"
        case .moku: "选择谁来理解你的想法，以及谁可以接手执行任务。"
        case .tag: "Tag Agent 会在每个目录中整理标签，为任务自动归类。"
        case .report: "Report Agent 会整理任务证据，持续更新目录中的报告。"
        case .landing: ""
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch fixture.step {
        case .discovery: discovery
        case .moku: moku
        case .tag: role($fixture.tag, id: "tag")
        case .report: role($fixture.report, id: "report")
        case .landing: EmptyView()
        }
    }

    private var discovery: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                if fixture.scanning { ProgressView().controlSize(.mini) }
                else { Image(systemName: fixture.installed.isEmpty ? "desktopcomputer" : "checkmark.circle.fill").foregroundStyle(fixture.installed.isEmpty ? Color.secondary : selectionInk) }
                Text(fixture.scanning ? "正在检查此 Mac…" : fixture.installed.isEmpty ? "此 Mac · 尚未发现 Agent" : "此 Mac · 发现 \(fixture.installed.count) 个 Agent")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if !fixture.scanning && !fixture.installed.isEmpty {
                    Button("重新检测", action: fixture.rescan).buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(.secondary).setupControl("rescan", fixture: fixture)
                }
            }.padding(.bottom, 12)
            ForEach(SetupAgent.allCases) { agent in
                HStack(spacing: 14) {
                    agent.logo(27).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name).font(.system(size: 14, weight: .medium))
                        Text(agent.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if fixture.scanning {
                        Text("检测中").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else if fixture.installed.contains(agent) {
                        Label("已发现", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(selectionInk)
                    } else {
                        Link(destination: agent.guide) {
                            Label("安装指南", systemImage: "arrow.up.right").font(.system(size: 11))
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14).padding(.horizontal, 3)
                if agent != .pi { Divider().opacity(0.55) }
            }
            Text("已发现表示 CLI 已安装；登录和模型服务由各 Agent 管理。")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 17)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var moku: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("谁来担任 Moku", detail: "Host · 理解与协调")
                agentChoices($fixture.host, prefix: "host")
                profileFields(Binding(get: { fixture.hostProfiles[fixture.host]! }, set: { fixture.hostProfiles[fixture.host] = $0 }), agent: fixture.host)
            }
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("可以把任务交给谁", detail: "Targets · 至少选择一个")
                HStack(spacing: 10) {
                    ForEach(fixture.available) { agent in
                        let selected = fixture.targets.contains(agent)
                        Button { withAnimation(motion) { fixture.toggleTarget(agent) } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected ? selectionInk : Color.secondary.opacity(0.5))
                                agent.logo(17)
                                Text(agent.name).font(.system(size: 12))
                            }.frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(selected ? accent.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .disabled(selected && fixture.targets.count == 1)
                        .setupControl("target-\(agent.id)", fixture: fixture)
                        .accessibilityLabel("\(agent.name)，\(selected ? "已选择" : "未选择")为派发目标")
                    }
                }
                Text("Moku 根据任务选择合适的 Agent 和模型；Host 也可以执行任务。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func role(_ binding: Binding<SetupRole>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 4) {
                modeButton("跟随 Moku", selected: binding.wrappedValue.followsHost, id: "\(id)-inherit") {
                    binding.wrappedValue.followsHost = true
                }
                modeButton("单独配置", selected: !binding.wrappedValue.followsHost, id: "\(id)-custom") {
                    binding.wrappedValue.followsHost = false
                }
            }
            .padding(4).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))

            if binding.wrappedValue.followsHost {
                HStack(spacing: 14) {
                    fixture.host.logo(28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(fixture.host.name).font(.system(size: 14, weight: .medium))
                        Text("\(fixture.hostProfiles[fixture.host]!.model) · \(fixture.hostProfiles[fixture.host]!.effort)推理")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "link").foregroundStyle(.secondary)
                }.padding(.vertical, 12)
                Text("使用 Moku 的执行配置，拥有独立的工作上下文。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                agentChoices(binding.agent, prefix: id)
                profileFields(Binding(get: { binding.wrappedValue.profiles[binding.wrappedValue.agent]! }, set: {
                    binding.wrappedValue.profiles[binding.wrappedValue.agent] = $0
                }), agent: binding.wrappedValue.agent)
            }
            Divider().opacity(0.6).padding(.top, 2)
            VStack(alignment: .leading, spacing: 15) {
                sectionLabel(id == "tag" ? "任务会自动归类" : "把执行过程整理成报告", detail: "效果示例")
                if id == "tag" {
                    HStack(spacing: 8) {
                        ForEach(["设计", "开发", "调研", "文档", "维护"], id: \.self) { tag in
                            Text(tag).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.primary.opacity(0.045), in: Capsule())
                        }
                    }
                    Text("每个目录维护 5 个语义标签，随任务内容持续整理。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "doc.text").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Mokusei · 项目进展").font(.system(size: 13, weight: .medium))
                            Text("已完成的工作、关键结论与下一步，汇集在一份报告中。")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
        .animation(motion, value: binding.wrappedValue.followsHost)
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func agentChoices(_ binding: Binding<SetupAgent>, prefix: String) -> some View {
        HStack(spacing: 10) {
            ForEach(fixture.available) { agent in
                let selected = binding.wrappedValue == agent
                Button { withAnimation(motion) { binding.wrappedValue = agent } } label: {
                    HStack(spacing: 9) {
                        agent.logo(20)
                        Text(agent.name).font(.system(size: 12, weight: selected ? .medium : .regular))
                        if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(selectionInk) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 53)
                    .background {
                        RoundedRectangle(cornerRadius: 12).fill(selected ? accent.opacity(0.09) : Color.primary.opacity(0.025))
                    }
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? selectionInk.opacity(0.4) : Color.clear, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .setupControl("\(prefix)-\(agent.id)", fixture: fixture)
                .accessibilityLabel("\(agent.name)\(selected ? "，已选择" : "")")
            }
        }
    }

    private func profileFields(_ binding: Binding<SetupProfile>, agent: SetupAgent) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("模型").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("模型", selection: binding.model) {
                    ForEach(agent.models, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("profile-model")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("推理强度").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("推理强度", selection: binding.effort) {
                    ForEach(["低", "适中", "高"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 116, alignment: .leading).accessibilityIdentifier("profile-effort")
            }
        }
        .controlSize(.large)
    }

    private func modeButton(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(motion, action) } label: {
            Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
                .frame(maxWidth: .infinity).frame(height: 34)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.85))
                            .matchedGeometryEffect(id: "role-mode", in: selection)
                    }
                }
        }.buttonStyle(.plain).setupControl(id, fixture: fixture)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack {
                if fixture.step != .discovery {
                    Button { withAnimation(motion) { fixture.back() } } label: {
                        Label("返回", systemImage: "chevron.left").font(.system(size: 12))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).setupControl("setup-back", fixture: fixture)
                } else {
                    Text("Mokusei").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                if fixture.step == .discovery && !fixture.scanning && fixture.installed.isEmpty {
                    Button(action: fixture.rescan) { Label("重新检测", systemImage: "arrow.clockwise").frame(width: 134, height: 24) }
                        .buttonStyle(.borderedProminent).controlSize(.large).setupControl("rescan", fixture: fixture)
                } else {
                    Button { withAnimation(motion) { fixture.advance() } } label: {
                        HStack(spacing: 15) {
                            Text(fixture.step == .report ? "开始使用 Moku" : "继续")
                            Image(systemName: "arrow.right")
                        }.font(.system(size: 12, weight: .medium)).frame(minWidth: 116, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!fixture.canContinue).keyboardShortcut(.defaultAction)
                    .setupControl("setup-next", fixture: fixture)
                }
            }
            Text(fixture.step == .discovery ? "安装一个即可开始，也可以随时添加更多。" : "这些选择之后都可以在设置中调整。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
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
