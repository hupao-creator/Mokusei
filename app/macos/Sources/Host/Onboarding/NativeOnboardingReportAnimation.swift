import SwiftUI
import MokuseiPluginAPI

struct NativeOnboardingReportAnimation: View {
    let harnesses: [AnyHarnessPlugin]
    let locale: DesktopLocale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowVisible = true
    @State private var phase = 0
    @State private var travel: CGFloat = 0
    @State private var playbackStarted = false
    private var agents: [AnyHarnessPlugin] { Array(harnesses.prefix(3)) }
    private var active: Bool { !reduceMotion && windowVisible && scenePhase == .active }
    private var paper: Color { Color(white: colorScheme == .dark ? 0.17 : 1) }

    var body: some View {
        if !agents.isEmpty { animation }
    }

    private var animation: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                documents(width: width)
                reportDocument(width: width)
                    .opacity(phase >= 2 ? 1 : 0)
                    .scaleEffect(x: phase >= 2 ? 1 : 0.28, y: phase >= 2 ? 1 : 0.6)
            }
            .frame(width: width, height: 250)
        }
        .frame(height: 250)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locale.text("多份长文档聚拢，展开为全貌、关系和要点三幅图组成的简洁报告", "Long documents gather into a concise visual report: overview, connections, and takeaways"))
        .accessibilityIdentifier("report-capability-animation")
        .background(NativeSettingsWindowVisibility { windowVisible = $0 })
        .task(id: active) {
            guard active && !playbackStarted else {
                if reduceMotion { playbackStarted = true }
                var final = Transaction(); final.disablesAnimations = true
                withTransaction(final) { phase = 3 }
                return
            }
            // Keep this visit consumed across activation changes and task cancellation.
            playbackStarted = true
            do {
                var reset = Transaction(); reset.disablesAnimations = true
                withTransaction(reset) { phase = 0; travel = 0 }
                try await Task.sleep(for: .milliseconds(300))
                withAnimation(.linear(duration: 3.4)) { travel = -300 }
                try await Task.sleep(for: .milliseconds(3450))
                withAnimation(.spring(response: 0.72, dampingFraction: 0.88)) { phase = 1 }
                try await Task.sleep(for: .milliseconds(650))
                withAnimation(.smooth(duration: 0.65)) { phase = 2 }
                try await Task.sleep(for: .milliseconds(650))
                withAnimation(.smooth(duration: 0.7)) { phase = 3 }
            } catch { return } // Leaving this step or hiding the window cancels the sequence.
        }
    }

    private func documents(width: CGFloat) -> some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                document(index)
                    .rotationEffect(.degrees(phase == 0 ? Double(index % 3 - 1) * 3 : Double(index % 3 - 1) * 7))
                    .scaleEffect(phase == 0 ? 1 : 0.32)
                    .position(x: phase == 0 ? 52 + CGFloat(index) * 176 + travel : width / 2 + CGFloat(index % 3 - 1) * 9,
                              y: phase == 0 ? 125 + CGFloat(index % 2) * 5 : 121)
                    .opacity(phase < 2 ? 1 : 0)
            }
        }
        .frame(width: width, height: 250)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.06),
                                   .init(color: .white, location: 0.94), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .clipped()
    }

    private func document(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                agents[index % agents.count].logo(size: 19).frame(width: 19, height: 19)
                RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.20)).frame(width: 48, height: 4)
                Spacer()
            }
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            // Dense, varied line lengths suggest lengthy session text without
            // asking the user to read another explanation during setup.
            Canvas { context, size in
                for line in 0..<34 {
                    let paragraph = line / 7
                    let y = CGFloat(line) * 3.7 + CGFloat(paragraph) * 3
                    let heading = line % 7 == 0
                    let fraction = CGFloat((line * 17 + index * 7) % 19) / 18
                    let length = size.width * (heading ? 0.39 : 0.56 + fraction * 0.44)
                    let rect = CGRect(x: 0, y: y, width: length, height: heading ? 2.6 : 1.6)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(.primary.opacity(heading ? 0.30 : 0.16)))
                }
            }.frame(height: 139)
        }
        .padding(14).frame(width: 154, height: 212, alignment: .topLeading)
        .background(paper, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.10), lineWidth: 1) }
        .shadow(color: .black.opacity(0.06), radius: 9, y: 5)
    }

    private func reportDocument(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 9) {
                ForEach(agents, id: \.descriptor.id) { agent in
                    agent.logo(size: 18).frame(width: 18, height: 18)
                }
                Spacer()
                Capsule().fill(.primary.opacity(0.13)).frame(width: 36, height: 3)
            }
            HStack(alignment: .top, spacing: 18) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 9) {
                        abstractFigure(index)
                            .frame(height: 102)
                        Text(locale.text(["全貌", "关系", "要点"][index], ["Overview", "Connections", "Takeaways"][index]))
                            .font(.system(size: 11, weight: .medium))
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(.primary.opacity(0.12)).frame(height: 2.5)
                            Capsule().fill(.primary.opacity(0.08)).frame(height: 2.5)
                                .padding(.trailing, CGFloat(24 + index * 7))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(phase >= 3 ? 1 : 0)
                    .offset(y: phase >= 3 ? 0 : 9)
                    .animation(active ? .smooth(duration: 0.6).delay(Double(index) * 0.16) : nil, value: phase)
                }
            }
        }
        .padding(18)
        .frame(width: width - 16, height: 214, alignment: .topLeading)
        .background(paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.10), lineWidth: 1) }
        .shadow(color: .black.opacity(0.07), radius: 13, y: 7)
    }

    /// An abstract reading sequence, not a fixed template or a claim about real report data.
    @ViewBuilder private func abstractFigure(_ index: Int) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let accent = Color.indigo.opacity(colorScheme == .dark ? 0.78 : 0.64)
            let ink = Color.primary.opacity(0.24)
            ZStack {
                if index == 0 {
                    let center = CGPoint(x: width * 0.50, y: 51)
                    let satellites = [CGPoint(x: width * 0.16, y: 24), CGPoint(x: width * 0.79, y: 18),
                                      CGPoint(x: width * 0.86, y: 67), CGPoint(x: width * 0.49, y: 89),
                                      CGPoint(x: width * 0.13, y: 75)]
                    Path { path in
                        for point in satellites { path.move(to: center); path.addLine(to: point) }
                    }
                    .trim(from: 0, to: phase >= 3 ? 1 : 0)
                    .stroke(ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    Circle().fill(accent.opacity(0.12)).frame(width: 45, height: 45).position(center)
                    Circle().fill(accent).frame(width: 19, height: 19).position(center)
                    ForEach(satellites.indices, id: \.self) { node in
                        Circle().fill(paper).frame(width: 12, height: 12)
                            .overlay { Circle().strokeBorder(ink, lineWidth: 1.4) }
                            .position(satellites[node])
                    }
                } else if index == 1 {
                    let left = CGPoint(x: width * 0.14, y: 51)
                    let middle = CGPoint(x: width * 0.48, y: 51)
                    let destinations = [CGPoint(x: width * 0.84, y: 23), CGPoint(x: width * 0.84, y: 79)]
                    Path { path in
                        path.move(to: left); path.addLine(to: middle)
                        for point in destinations {
                            path.move(to: middle)
                            path.addCurve(to: point, control1: .init(x: width * 0.68, y: 51),
                                          control2: .init(x: width * 0.64, y: point.y))
                        }
                    }
                    .trim(from: 0, to: phase >= 3 ? 1 : 0)
                    .stroke(ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    Circle().fill(paper).frame(width: 17, height: 17)
                        .overlay { Circle().strokeBorder(ink, lineWidth: 1.2) }.position(left)
                    RoundedRectangle(cornerRadius: 7).fill(accent).frame(width: 29, height: 29).position(middle)
                    ForEach(destinations.indices, id: \.self) { node in
                        RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.13)).frame(width: 23, height: 20)
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(accent.opacity(0.6), lineWidth: 1) }
                            .position(destinations[node])
                    }
                } else {
                    ForEach(0..<3, id: \.self) { row in
                        let y = CGFloat(23 + row * 28)
                        Circle().fill(row == 0 ? accent : accent.opacity(0.16))
                            .frame(width: 15, height: 15).position(x: width * 0.15, y: y)
                        if row == 0 {
                            Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white).position(x: width * 0.15, y: y)
                        }
                        Capsule().fill(row == 0 ? accent.opacity(0.5) : Color.primary.opacity(0.18))
                            .frame(width: width * [0.58, 0.43, 0.50][row], height: row == 0 ? 7 : 5)
                            .frame(width: width * 0.62, alignment: .leading).position(x: width * 0.64, y: y)
                    }
                }
            }
            .frame(width: width, height: 102)
        }
    }
}
