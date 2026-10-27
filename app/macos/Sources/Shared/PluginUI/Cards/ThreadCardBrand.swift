import ImageIO
import SwiftUI

private struct ThreadCardFollowUpKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
public extension EnvironmentValues {
    var threadCardFollowUp: (@MainActor () -> Void)? {
        get { self[ThreadCardFollowUpKey.self] }
        set { self[ThreadCardFollowUpKey.self] = newValue }
    }
}
/// The host owns follow-up eligibility and routing; the corner owns its affordance.
public struct ThreadCardFollowUpProvider<Content: View>: View {
    private let onOpen: (@MainActor () -> Void)?
    private let content: Content
    public init(onOpen: (@MainActor () -> Void)?, @ViewBuilder content: () -> Content) {
        self.onOpen = onOpen; self.content = content()
    }
    public var body: some View { content.environment(\.threadCardFollowUp, onOpen) }
}

public struct ThreadCardProviderStatus: View {
    static let diameter: CGFloat = 44
    public let label: String
    public let brandKey: String
    public let emoji: String?
    public let terminal: ThreadCardTerminalStatus?
    public let onFollowUp: (() -> Void)?
    public init(label: String, brandKey: String, emoji: String? = nil,
                terminal: ThreadCardTerminalStatus? = nil, onFollowUp: (() -> Void)? = nil) {
        self.label = label; self.brandKey = brandKey; self.emoji = emoji; self.terminal = terminal; self.onFollowUp = onFollowUp
    }
    public var body: some View {
        ThreadCardProviderStatusBody(label: label, brandKey: brandKey,
            emoji: emoji, terminal: terminal, onFollowUp: onFollowUp)
            .frame(width: Self.diameter, height: Self.diameter)
    }
}

private struct ThreadCardProviderStatusBody: View {
    private static let diameter = ThreadCardProviderStatus.diameter
    public let label: String
    public let brandKey: String
    public let emoji: String?
    public let terminal: ThreadCardTerminalStatus?
    public let onFollowUp: (() -> Void)?
    @Environment(\.threadCardFollowUp) private var inheritedFollowUp
    @Environment(\.locale) private var locale
    @Environment(\.threadCardHovered) private var cardHovered
    @Environment(\.threadCardProviderColor) private var providerColor
    @State private var hovered = false
    @FocusState private var focused: Bool
    public init(label: String, brandKey: String, emoji: String? = nil,
                terminal: ThreadCardTerminalStatus? = nil, onFollowUp: (() -> Void)? = nil) {
        self.label = label; self.brandKey = brandKey; self.emoji = emoji; self.terminal = terminal; self.onFollowUp = onFollowUp
    }
    private var action: (() -> Void)? { onFollowUp ?? inheritedFollowUp }
    public var body: some View {
        ZStack {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let emoji, !emoji.isEmpty { Text(emoji).font(.system(size: 21)) }
                    else { NativeIcon(name: "MessageCircle", size: 20) }
                }.frame(width: Self.diameter, height: Self.diameter)
                if let terminal { TerminalBadge(terminal: terminal, tone: tone).id(terminal) }
            }
            .opacity(action != nil && (hovered || focused || cardHovered) ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            if let action {
                Button(action: action) { NativeIcon(name: "Send", size: 16).frame(width: Self.diameter, height: Self.diameter) }
                    .buttonStyle(.plain).focused($focused)
                    .opacity(hovered || focused || cardHovered ? 1 : 0)
                    .accessibilityLabel(cardLocalized("发送消息", locale))
                    .help(cardLocalized("发送消息", locale))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter).foregroundStyle(tone)
        .glassEffect(.regular.interactive(action != nil), in: Circle())
        .contentShape(Circle()).onHover { hovered = $0 }
        .focusable(action == nil).focused($focused)
        .overlay(Circle().stroke(focused ? NativePalette.overview.ink.swiftUI : .clear, lineWidth: 1).padding(-3))
        .animation(.easeInOut(duration: 0.14), value: hovered || focused || cardHovered)
        .help(label)
    }
    private var tone: Color {
        switch terminal {
        case .completed: NativePalette.pair(0x367052, 0x99caaa).swiftUI
        case .interrupted: NativePalette.pair(0x76613e, 0xc9b68f).swiftUI
        case .failed: NativePalette.pair(0xb13c38, 0xf4a39a).swiftUI
        case nil: providerColor
        }
    }
}
private struct TerminalBadge: View {
    let terminal: ThreadCardTerminalStatus
    let tone: Color
    @State private var drawn = false
    var body: some View {
        TerminalSymbol(terminal: terminal).trim(from: 0, to: drawn ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: 1.24, lineCap: .round, lineJoin: .round))
            .frame(width: 11, height: 11).padding(2)
            .background(TerminalBadgeSurface(tone: tone))
            .shadow(color: .black.opacity(0.09), radius: 1, y: 0.8)
            .offset(x: 1, y: 1)
            .onAppear { withAnimation(.easeOut(duration: 0.32)) { drawn = true } }
    }
}

/// The source badge uses a specific backdrop filter and translucent color mix,
/// independent of the system's material tint and vibrancy preferences.
private struct TerminalBadgeSurface: View {
    let tone: Color
    var body: some View { Circle().fill(tone.opacity(0.15)).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.55)) }
}
private struct TerminalSymbol: Shape {
    let terminal: ThreadCardTerminalStatus
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch terminal {
        case .failed: path.move(to: .init(x: 4, y: 4)); path.addLine(to: .init(x: 12, y: 12)); path.move(to: .init(x: 12, y: 4)); path.addLine(to: .init(x: 4, y: 12))
        case .interrupted: path.move(to: .init(x: 5, y: 4)); path.addLine(to: .init(x: 5, y: 12)); path.move(to: .init(x: 11, y: 4)); path.addLine(to: .init(x: 11, y: 12))
        case .completed: path.move(to: .init(x: 3, y: 8)); path.addLine(to: .init(x: 6.2, y: 11.2)); path.addLine(to: .init(x: 13, y: 4.5))
        }
        return path.applying(.init(scaleX: rect.width / 16, y: rect.height / 16))
    }
}

private struct ThreadCardLogoKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> AnyView)? = nil
}
public extension EnvironmentValues {
    var threadCardLogo: (@MainActor @Sendable () -> AnyView)? {
        get { self[ThreadCardLogoKey.self] }
        set { self[ThreadCardLogoKey.self] = newValue }
    }
}

public struct ThreadCardBrandLogo: View {
    @Environment(\.threadCardLogo) private var nativeLogo
    public let logoSource: String
    public let label: String
    public let brandKey: String
    @State private var loadedImage: CGImage?
    public init(logoSource: String, label: String, brandKey: String) {
        self.logoSource = logoSource; self.label = label; self.brandKey = brandKey
    }
    public var body: some View {
        Group {
            if let nativeLogo { nativeLogo() }
            else if let loadedImage { Image(decorative: loadedImage, scale: 1).resizable().scaledToFit() }
            else { BrandFallback().stroke(lineWidth: 1).padding(0.5) }
        }
        .frame(width: 12, height: 12).accessibilityLabel(label).help(label)
        .task(id: logoSource) { if nativeLogo == nil { loadedImage = Self.image(logoSource) } }
    }
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    private static func image(_ source: String) -> CGImage? {
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
            let metadata = source[..<comma]
            let payload = String(source[source.index(after: comma)...])
            let data = metadata.contains(";base64") ? Data(base64Encoded: payload)
                : payload.removingPercentEncoding?.data(using: .utf8)
            return data.flatMap(decode)
        }
        if source.hasPrefix("/") { return (try? Data(contentsOf: URL(fileURLWithPath: source))).flatMap(decode) }
        if let url = URL(string: source), url.isFileURL { return (try? Data(contentsOf: url)).flatMap(decode) }
        // Plugins provide packaged assets, never fetch a URL while rendering a card.
        return nil
    }
}
private struct BrandFallback: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: CGRect(x: 2.5, y: 4, width: 19, height: 14), cornerRadius: 2.5)
        for points: [CGPoint] in [[.init(x: 6.5, y: 9.5), .init(x: 12.5, y: 9.5)], [.init(x: 6.5, y: 13), .init(x: 10, y: 13)], [.init(x: 14.5, y: 12.5), .init(x: 17, y: 14.5), .init(x: 19.5, y: 12.5)]] {
            p.move(to: points[0]); points.dropFirst().forEach { p.addLine(to: $0) }
        }
        return p.applying(.init(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
