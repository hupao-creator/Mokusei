import ImageIO
import SwiftUI

public struct ThreadCardProviderStatus: View {
    public static let diameter: CGFloat = 44
    public static let cornerClearance: CGFloat = diameter + 8
    public let label: String
    public let brandKey: String
    public let emoji: String?
    public let terminal: ThreadCardTerminalStatus?
    public let completedBackground: Bool
    public let usesRegularGlass: Bool
    @Environment(\.threadCardProviderColor) private var providerColor
    public init(label: String, brandKey: String, emoji: String? = nil,
                terminal: ThreadCardTerminalStatus? = nil, completedBackground: Bool = false, usesRegularGlass: Bool = false) {
        self.label = label; self.brandKey = brandKey; self.emoji = emoji; self.terminal = terminal
        self.completedBackground = completedBackground
        self.usesRegularGlass = usesRegularGlass
    }
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let emoji, !emoji.isEmpty { Text(emoji).font(.system(size: 21)).threadIdentityElement("emoji", detail: false, text: emoji) }
                else { NativeIcon(name: "MessageCircle", size: 20) }
            }.frame(width: Self.diameter, height: Self.diameter)
            if let terminal { TerminalBadge(terminal: terminal, tone: tone).id(terminal) }
        }
        .frame(width: Self.diameter, height: Self.diameter).foregroundStyle(tone)
        .modifier(ThreadCardBadgeMaterial(hasEmoji: emoji?.isEmpty == false,
            completed: terminal == .completed || completedBackground, usesRegularGlass: usesRegularGlass))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
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
private struct ThreadCardBadgeMaterial: ViewModifier {
    let hasEmoji: Bool
    let completed: Bool
    let usesRegularGlass: Bool
    @Environment(\.threadCardUsesFlatMaterials) private var flatMaterials

    @ViewBuilder func body(content: Content) -> some View {
        if usesRegularGlass {
            content.nativeRegularCardGlass(in: Circle(), opaque: NativePalette.overview.accentSoft.swiftUI,
                tint: .mint.opacity(0.12), interactive: true)
        } else if flatMaterials && hasEmoji {
            content.background(completed ? NativePalette.overview.accentSoft.swiftUI
                : NativePalette.overview.surfaceStrong.swiftUI, in: Circle())
        } else if flatMaterials {
            content
                .background(NativePalette.overview.surfaceStrong.swiftUI, in: Circle())
                .overlay(Circle().stroke(NativePalette.overview.lineSoft.swiftUI, lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true))
        } else {
            content.glassEffect(.regular, in: Circle())
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

private struct TerminalBadgeSurface: View {
    let tone: Color
    @Environment(\.threadCardUsesFlatMaterials) private var flatMaterials
    var body: some View {
        if flatMaterials {
            Circle().fill(tone.opacity(0.15))
                .background(NativePalette.overview.surfaceStrong.swiftUI, in: Circle())
                .overlay(Circle().stroke(NativePalette.overview.lineSoft.swiftUI, lineWidth: 0.55)
                    .allowsHitTesting(false).accessibilityHidden(true))
        } else {
            Circle().fill(tone.opacity(0.15)).background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.55))
        }
    }
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

public extension View {
    /// Places card status in the shared upper-right badge seat.
    func threadCardBadge<Badge: View>(@ViewBuilder badge: () -> Badge) -> some View {
        overlay(alignment: .topTrailing) {
            badge().padding(.top, 12).padding(.trailing, 17)
        }
    }
}

private struct ThreadCardArchiveActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
private struct ThreadCardArchivePendingKey: EnvironmentKey {
    static let defaultValue = false
}
public extension EnvironmentValues {
    /// Host-owned archive capability, supplied only for a manually stopped Thread.
    var threadCardArchiveAction: (@MainActor () -> Void)? {
        get { self[ThreadCardArchiveActionKey.self] }
        set { self[ThreadCardArchiveActionKey.self] = newValue }
    }
    var threadCardArchivePending: Bool {
        get { self[ThreadCardArchivePendingKey.self] }
        set { self[ThreadCardArchivePendingKey.self] = newValue }
    }
}

struct ThreadCardArchiveBadge<Content: View>: View {
    let hovered: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.threadCardArchiveAction) private var archive
    @Environment(\.threadCardArchivePending) private var pending
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool

    var body: some View {
        if let archive {
            Button(action: archive) {
                ZStack {
                    content().opacity(hovered || focused ? 0 : 1)
                    NativeIcon(name: "X", size: 20)
                        .frame(width: ThreadCardProviderStatus.diameter, height: ThreadCardProviderStatus.diameter)
                        .foregroundStyle(NativePalette.overview.ink.swiftUI)
                        .background(NativePalette.overview.surfaceStrong.swiftUI, in: Circle())
                        .opacity(hovered || focused ? 1 : 0)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .disabled(pending)
            .onKeyPress(.return) {
                if !pending { archive() }
                return .handled
            }
            .accessibilityLabel((locale.language.languageCode?.identifier == "en" ? "Archive conversation" : "归档会话"))
            .help((locale.language.languageCode?.identifier == "en" ? "Archive conversation" : "归档会话"))
        } else {
            content()
        }
    }
}
