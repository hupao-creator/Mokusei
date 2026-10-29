import SpriteKit
import SwiftUI
import MokuseiPluginAPI

struct NativeOnboardingTagAnimation: View {
    let harnesses: [AnyHarnessPlugin]
    let locale: DesktopLocale
    var visitPlaybackStarted: Binding<Bool>? = nil
    private struct Playback: Equatable {
        let size: CGSize
        let dark: Bool
        let active: Bool
        let locale: DesktopLocale
        let harnesses: [String]
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowVisible = true
    @State private var viewport = CGSize(width: 560, height: 250)
    @State private var scene = NativeOnboardingTagScene()
    @State private var staticFrameReady = false
    @State private var playbackStarted = false
    private var started: Bool {
        get { visitPlaybackStarted?.wrappedValue ?? playbackStarted }
        nonmutating set {
            if let visitPlaybackStarted { visitPlaybackStarted.wrappedValue = newValue }
            else { playbackStarted = newValue }
        }
    }
    private var active: Bool { !reduceMotion && windowVisible && scenePhase == .active }

    var body: some View {
        if !harnesses.isEmpty { animation }
    }

    private var animation: some View {
        SpriteView(scene: scene, isPaused: staticFrameReady, options: [.allowsTransparency])
            .frame(height: 250)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(locale.text("分散的会话被标签归类，便于找到所需内容", "Scattered conversations organize into tags, making them easier to find"))
            .accessibilityIdentifier("tag-capability-animation")
            .background(NativeSettingsWindowVisibility { windowVisible = $0 })
            .task(id: Playback(size: viewport, dark: colorScheme == .dark, active: active, locale: locale, harnesses: harnesses.map { $0.descriptor.id.string })) {
                staticFrameReady = false
                scene.prepare(size: viewport, dark: colorScheme == .dark, harnesses: harnesses, locale: locale)
                guard NativeCapabilityPlayback.shouldPlay(active: active, reduceMotion: reduceMotion,
                                                           started: Binding(get: { started }, set: { started = $0 })) else {
                    scene.organize(animated: false)
                    // Let SpriteKit draw updated textures before pausing its renderer,
                    // including appearance changes made from the separate demo window.
                    do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                    staticFrameReady = true
                    return
                }
                do {
                    // Initial layout may resize the scene before any tokens arrive.
                    // Once playback starts, task restarts only rebuild the final frame.
                    try await Task.sleep(for: .milliseconds(250))
                    NativeCapabilityPlayback.begin(Binding(get: { started }, set: { started = $0 }))
                    for arrival in NativeOnboardingTagScene.arrivals {
                        scene.drop(arrival.index)
                        try await Task.sleep(for: .milliseconds(arrival.pause))
                    }
                    try await Task.sleep(for: .milliseconds(2400))
                    scene.organize(animated: true)
                    try await Task.sleep(for: .milliseconds(1600))
                    staticFrameReady = true
                } catch { return }
            }
            .onDisappear { scene.stop() }
    }
}

/// Physics owns positions until grouping begins; the same nodes then animate into tags.
@MainActor private final class NativeOnboardingTagScene: SKScene {
    private let categories: [(String, Color)] = [
        ("设计", .purple), ("开发", .blue), ("调研", .orange), ("文档", .teal), ("维护", .green)
    ]
    private var tasks: [(String, Int, Int)] { [
        (locale.text("设计登录页面", "Refine login UI"), 0, 0), (locale.text("优化搜索体验", "Improve search"), 1, 1), (locale.text("整理用户访谈", "Review interviews"), 2, 2),
        (locale.text("补充使用指南", "Write user guide"), 3, 1), (locale.text("执行回归检查", "Run regression"), 4, 0), (locale.text("调整窗口布局", "Arrange windows"), 0, 2),
        (locale.text("接入模型接口", "Connect models"), 1, 0), (locale.text("分析竞品体验", "Compare products"), 2, 1), (locale.text("更新开发文档", "Update dev docs"), 3, 2),
        (locale.text("修复会话恢复", "Restore sessions"), 4, 1), (locale.text("打磨标签样式", "Polish tag style"), 0, 0), (locale.text("支持语音输入", "Add voice input"), 1, 2),
        (locale.text("调研快捷操作", "Explore shortcuts"), 2, 0), (locale.text("整理版本说明", "Write release notes"), 3, 1), (locale.text("排查窗口焦点", "Fix window focus"), 4, 2)
    ] }
    static let arrivals: [(index: Int, pause: Int)] = [
        (5, 90), (1, 230), (11, 75), (3, 110), (8, 320),
        (0, 65), (13, 170), (6, 90), (4, 260), (10, 80),
        (7, 140), (14, 65), (2, 210), (12, 110), (9, 180)
    ]
    private var harnesses: [AnyHarnessPlugin] = []
    private var locale = DesktopLocale.chinese
    private let content = SKNode()
    private var tokens: [Int: SKSpriteNode] = [:]
    private var labels: [SKSpriteNode] = []
    private var textures: [SKTexture] = []
    private var groupedTextures: [SKTexture] = []
    private var tokenSize = CGSize(width: 106, height: 34)

    override init() {
        super.init(size: .init(width: 560, height: 250))
        scaleMode = .resizeFill
        backgroundColor = .clear
        physicsWorld.gravity = .init(dx: 0, dy: -7.8)
    }
    required init?(coder: NSCoder) { fatalError("Onboarding scene is created in code") }

    func prepare(size: CGSize, dark: Bool, harnesses: [AnyHarnessPlugin], locale: DesktopLocale) {
        stop()
        self.harnesses = harnesses; self.locale = locale
        self.size = size
        tokenSize.width = min(106, size.width / 5 - 6)
        // The walls extend above the visible scene so entries can fall through its top.
        // Only the physics body exists: no container surface or outline is rendered.
        physicsBody = SKPhysicsBody(edgeLoopFrom: .init(x: 8, y: 12, width: size.width - 16, height: size.height + 260))
        physicsBody?.friction = 0.7
        physicsBody?.restitution = 0.22
        let scheme: ColorScheme = dark ? .dark : .light
        textures = tasks.map { task in
            texture(tokenLabel(task, grouped: false, dark: dark).environment(\.colorScheme, scheme))
        }
        groupedTextures = tasks.map { task in
            texture(tokenLabel(task, grouped: true, dark: dark).environment(\.colorScheme, scheme))
        }
        labels = categories.enumerated().map { index, category in
            let label = VStack(spacing: 10) {
                Text(locale.text(category.0, ["Design", "Build", "Research", "Docs", "Upkeep"][index])).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(category.1.opacity(dark ? 0.18 : 0.09), in: Capsule())
                Capsule().fill(category.1.opacity(0.25)).frame(width: 1, height: 12)
            }.environment(\.colorScheme, scheme)
            let texture = texture(label)
            let pixels = texture.size()
            return SKSpriteNode(texture: texture, size: .init(width: pixels.width / 2, height: pixels.height / 2))
        }
        reset()
    }

    func reset() {
        removeAllActions()
        content.removeAllActions()
        content.removeAllChildren()
        tokens.removeAll()
        content.alpha = 1
        if content.parent == nil { addChild(content) }
        for (index, label) in labels.enumerated() {
            label.removeAllActions()
            label.alpha = 0
            label.position = .init(x: size.width / 5 * (CGFloat(index) + 0.5), y: size.height - 32)
            content.addChild(label)
        }
    }

    func drop(_ index: Int) {
        let node = makeToken(index)
        let fractions: [CGFloat] = [0.28, 0.64, 0.40, 0.75, 0.22, 0.57, 0.46, 0.82, 0.33, 0.70, 0.18, 0.52, 0.62, 0.38, 0.79]
        let margin = tokenSize.width / 2 + 12
        node.position = .init(x: margin + fractions[index] * (size.width - 2 * margin), y: size.height + 28)
        node.zRotation = CGFloat(index * 13 % 19 - 9) * 0.025
        let body = SKPhysicsBody(rectangleOf: tokenSize)
        body.mass = 0.2
        body.friction = 0.65
        body.restitution = 0.3
        body.linearDamping = 0.5
        body.angularDamping = 1.8
        body.velocity = .init(dx: CGFloat(index * 37 % 161 - 80), dy: -45)
        body.angularVelocity = CGFloat(index * 11 % 17 - 8) * 0.14
        body.usesPreciseCollisionDetection = true
        node.physicsBody = body
    }

    func organize(animated: Bool) {
        for label in labels {
            if animated { label.run(.fadeIn(withDuration: 0.3)) }
            else { label.alpha = 1 }
        }
        for index in tasks.indices {
            let node = tokens[index] ?? makeToken(index)
            let category = tasks[index].1
            let row = tasks[..<index].filter { $0.1 == category }.count
            let destination = CGPoint(x: size.width / 5 * (CGFloat(category) + 0.5), y: size.height - 101 - CGFloat(row) * 48)
            // Stop the solver before applying layout actions; otherwise gravity and
            // the category animation would both write each token's transform.
            node.physicsBody = nil
            node.removeAllActions()
            node.texture = groupedTextures[index]
            if animated {
                let movement = SKAction.group([
                    .move(to: destination, duration: 0.95),
                    .rotate(toAngle: 0, duration: 0.75, shortestUnitArc: true)
                ])
                movement.timingMode = .easeInEaseOut
                node.run(.sequence([.wait(forDuration: Double(index) * 0.035), movement]))
            } else {
                node.position = destination
                node.zRotation = 0
            }
        }
    }

    func stop() {
        removeAllActions()
        content.removeAllActions()
        content.removeAllChildren()
        tokens.removeAll()
    }

    private func makeToken(_ index: Int) -> SKSpriteNode {
        let node = SKSpriteNode(texture: textures[index], size: tokenSize)
        tokens[index] = node
        content.addChild(node)
        return node
    }

    private func tokenLabel(_ task: (String, Int, Int), grouped: Bool, dark: Bool) -> some View {
        HStack(spacing: 6) {
            harnesses[task.2 % harnesses.count].logo(size: 14).frame(width: 14, height: 14)
            Text(task.0).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 6).frame(width: tokenSize.width, height: tokenSize.height)
        .background(Color(white: dark ? 0.17 : 1), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(grouped ? categories[task.1].1.opacity(0.3) : Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private func texture<Content: View>(_ content: Content) -> SKTexture {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { preconditionFailure("Could not render the onboarding token") }
        let texture = SKTexture(cgImage: image)
        return texture
    }
}
