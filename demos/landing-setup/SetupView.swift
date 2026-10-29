import SwiftUI
@testable import MokuseiUI
import MokuseiPluginUI

struct SetupSurface: View {
    @Bindable var fixture: SetupFixture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var panelStep = SetupStep.discovery
    @State private var contentVisible = true
    @State private var collapsed = false
    @State private var dockRevealed = false
    @State private var panelRetired = false
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
        case .moku, .tag, .report: SetupConfigurationPanel(fixture: fixture, step: panelStep)
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
