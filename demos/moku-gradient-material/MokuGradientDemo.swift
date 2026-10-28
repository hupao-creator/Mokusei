import SwiftUI

/// A material proposal around production eyes and geometry, not a second Dock.
struct MokuGradientDemo: View {
    @State private var strength = 0.85
    @State private var backdrop = DemoBackdrop.sand
    @State private var display = DemoDisplay.pair
    @State private var expanded = true
    @State private var reduceTransparency = false
    @State private var draft = "帮我整理今天的灵感，\n把值得继续的想法留在这里。"
    @State private var backgroundOffset = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque

    private var opaque: Bool { reduceTransparency || systemOpaque }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                MaterialBackdrop(style: backdrop, offset: backgroundOffset)
                HStack(spacing: 36) {
                    ForEach(display.materials) { material in
                        specimen(material: material)
                    }
                }
                .padding(.horizontal, 44)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 24)
            controls
        }
        .frame(minWidth: 1080, minHeight: 740)
        .background(Color(red: 0.075, green: 0.078, blue: 0.075))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Moku / 渐变玻璃").font(.system(size: 25, weight: .medium))
                Text("深色与浅色，同样让光从底部浮出来。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("背景", selection: $backdrop) {
                ForEach(DemoBackdrop.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented).frame(width: 240)
            .accessibilityIdentifier("background-picker")
        }
        .padding(.horizontal, 32).padding(.vertical, 25)
    }

    private func specimen(material: DemoMaterial) -> some View {
        // At low density the backdrop, rather than the tint, determines contrast.
        let ink: Color = material != .original && strength < 0.5 && !opaque
            ? (backdrop == .night ? .white : .black) : (material == .light ? .black : .white)
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(material == .dark ? Color(red: 0.93, green: 0.76, blue: 0.53) : .white.opacity(0.8))
                    .frame(width: 5, height: 5)
                Text(material.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(material.caption)
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2)
            }
            .foregroundStyle(backdrop == .paper ? Color.black.opacity(0.7) : Color.white.opacity(0.8))
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    NativeMokuCapsuleEyes(expression: .idle, focus: expanded ? 1 : 0)
                        .fill(ink.opacity(0.94)).frame(width: 34, height: 24)
                    if expanded {
                        Text("Moku").font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.7))
                        Spacer()
                        Button { toggleExpansion() } label: {
                            Image(systemName: "minus").frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain).foregroundStyle(ink.opacity(0.55))
                        .accessibilityLabel("收起面板")
                    }
                }
                if expanded {
                    TextField("向 Moku 询问…", text: $draft, axis: .vertical)
                        .font(.system(size: 25, weight: .regular))
                        .lineSpacing(9).lineLimit(3, reservesSpace: true)
                        .textFieldStyle(.plain).foregroundStyle(ink)
                        .accessibilityLabel("\(material.rawValue)面板输入")
                    HStack {
                        Image(systemName: "plus").font(.system(size: 17, weight: .light))
                        Text("留一点空间，给下一个想法。")
                            .font(.system(size: 11)).padding(.leading, 3)
                        Spacer()
                        Image(systemName: "waveform").font(.system(size: 17, weight: .light))
                    }
                    .foregroundStyle(ink.opacity(0.7))
                    .accessibilityHidden(true)
                }
            }
            .padding(expanded ? 27 : 10)
            .frame(width: expanded ? nil : NativeMokuCapsuleLayout.idleSize.width,
                   height: expanded ? 270 : NativeMokuCapsuleLayout.idleSize.height)
            .frame(maxWidth: expanded ? 560 : nil, alignment: .leading)
            .background { surface(material: material) }
            .environment(\.colorScheme, material == .light ? .light : .dark)
            .shadow(color: .black.opacity(material == .dark ? 0.18 : 0.12), radius: 22, y: 12)
            .frame(height: 294, alignment: .bottom)
            .accessibilityIdentifier("\(material.id)-panel")
            Spacer(minLength: 28)
            NativeMokuCapsuleEyes(expression: .idle, focus: 0)
                .fill(ink.opacity(0.94))
                .frame(width: NativeMokuCapsuleLayout.idleSize.width, height: NativeMokuCapsuleLayout.idleSize.height)
                .background { surface(material: material) }
                .environment(\.colorScheme, material == .light ? .light : .dark)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
            Text("168 × 44 · 悬浮胶囊")
                .font(.system(size: 10)).foregroundStyle(backdrop == .paper ? .black.opacity(0.55) : .white.opacity(0.65))
                .padding(.top, 15)
            Spacer(minLength: 28)
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func surface(material: DemoMaterial) -> some View {
        if material != .original {
            NativeMokuCapsuleGlass(interactive: false, strength: strength, forceOpaque: opaque)
        } else if opaque {
            RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)
                .fill(Color(nsColor: MokuGeometry.bodyColor))
        } else {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
        }
    }

    private var controls: some View {
        VStack(spacing: 17) {
            HStack(spacing: 20) {
                Text("渐变强度").font(.system(size: 12))
                Slider(value: $strength, in: 0...1)
                    .frame(width: 220).accessibilityLabel("渐变强度")
                Text(strength, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 12, design: .monospaced)).frame(width: 38, alignment: .trailing)
                Divider().frame(height: 18)
                Picker("展示", selection: $display) {
                    ForEach(DemoDisplay.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                .accessibilityIdentifier("display-picker")
                Spacer()
                Button(expanded ? "收起面板" : "展开面板", action: toggleExpansion)
                    .accessibilityIdentifier("expand-toggle")
                Button("恢复推荐") {
                    strength = 0.85; backdrop = .sand; display = .pair
                    expanded = true; backgroundOffset = 0; reduceTransparency = false
                }
            }
            HStack(spacing: 14) {
                Text("移动背景").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $backgroundOffset, in: -1...1)
                    .frame(width: 150).accessibilityLabel("移动背景")
                Toggle("降低透明度预览", isOn: $reduceTransparency)
                Spacer()
                Text(opaque ? "降低透明度已启用 · 实色回退" : "生产材质预览 · 输入文字可编辑 · 参数仅作用于 demo")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12)).toggleStyle(.checkbox)
        .padding(.horizontal, 32).padding(.vertical, 24)
    }

    private func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) { expanded.toggle() }
    }
}

private enum DemoMaterial: String, Identifiable {
    case dark = "深色渐变", light = "浅色渐变", original = "原材质"
    var id: String { caption.lowercased() }
    var caption: String {
        switch self {
        case .dark: "DARK"
        case .light: "LIGHT"
        case .original: "ORIGINAL"
        }
    }
}

private enum DemoDisplay: String, Identifiable, CaseIterable {
    case pair = "深浅对比", dark = "深色", light = "浅色", original = "原材质"
    var id: String { rawValue }
    var materials: [DemoMaterial] {
        switch self {
        case .pair: [.dark, .light]
        case .dark: [.dark]
        case .light: [.light]
        case .original: [.original]
        }
    }
}

private enum DemoBackdrop: String, Identifiable, CaseIterable {
    case sand = "暖沙", paper = "浅色", night = "深色"
    var id: String { rawValue }
    var colors: [Color] {
        switch self {
        case .sand: [Color(red: 0.30, green: 0.24, blue: 0.19), Color(red: 0.67, green: 0.58, blue: 0.46), Color(red: 0.86, green: 0.80, blue: 0.69)]
        case .paper: [Color(red: 0.71, green: 0.74, blue: 0.72), Color(red: 0.88, green: 0.87, blue: 0.82), Color(red: 0.98, green: 0.96, blue: 0.90)]
        case .night: [Color(red: 0.08, green: 0.11, blue: 0.17), Color(red: 0.20, green: 0.24, blue: 0.32), Color(red: 0.42, green: 0.47, blue: 0.54)]
        }
    }
}

private struct MaterialBackdrop: View {
    let style: DemoBackdrop
    let offset: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<4) { index in
                    ribbon(size: size, index: index)
                        .fill(LinearGradient(colors: [style.colors[0], style.colors[1], style.colors[2], style.colors[1]],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            ribbon(size: size, index: index)
                                .stroke(.white.opacity(style == .night ? 0.13 : 0.30), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.15), radius: 22, y: 15)
                }
            }
        }
        .clipped().accessibilityHidden(true)
    }

    private func ribbon(size: CGSize, index: Int) -> Path {
        let y = CGFloat(index) * size.height * 0.37 - size.height * 0.40
        let shift = offset * size.width * 0.20
        return Path { path in
            path.move(to: CGPoint(x: -100 + shift, y: y))
            path.addCurve(to: CGPoint(x: size.width + 140 + shift, y: y + size.height * 0.65),
                          control1: CGPoint(x: size.width * 0.24 + shift, y: y + size.height * 0.95),
                          control2: CGPoint(x: size.width * 0.70 + shift, y: y - size.height * 0.25))
            path.addLine(to: CGPoint(x: size.width + 140 + shift, y: y + size.height * 1.1))
            path.addCurve(to: CGPoint(x: -100 + shift, y: y + size.height * 0.4),
                          control1: CGPoint(x: size.width * 0.66 + shift, y: y + size.height * 0.1),
                          control2: CGPoint(x: size.width * 0.24 + shift, y: y + size.height * 1.2))
            path.closeSubpath()
        }
    }
}
