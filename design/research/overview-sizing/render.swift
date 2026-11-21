// Build against this checkout's ChiefPluginUI. An unordered window drives
// SwiftUI appearance without opening Chief or taking keyboard focus.
import AppKit
import ChiefCore
import ChiefPluginUI
import SwiftUI

struct Sample {
    let label: String
    let width: CGFloat
    let height: CGFloat
}

@main
struct SizingSheet {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let samples = [
            Sample(label: "初始窗", width: 197.6, height: 136),
            Sample(label: "14 英寸", width: 264, height: 166),
            Sample(label: "16 英寸", width: 307.2, height: 199.75),
            Sample(label: "1920 工作区", width: 345.6, height: 190.5),
            Sample(label: "2560 工作区", width: 473.6, height: 280.5),
            Sample(label: "固定候选", width: 384, height: 240),
            Sample(label: "现行", width: 414, height: 253)
        ]
        let intervention = ThreadCardIntervention(id: JSONText("confirm"), title: "是否允许将本次检查结果写入共享文档？",
            detail: "写入后其他成员可以查看。请先核对文档标题和目标位置。",
            actions: ["允许一次", "始终允许", "拒绝"].map { .init(id: JSONText($0), label: $0) })
        let presentation = try composeThreadCard(.standard(extensions: [.intervention(intervention)]),
                                                  layoutContext: .init(availableCols: 3))
        let identity = ThreadCardIdentityView(title: "核对跨显示器的四组检查结果与发布前验收清单",
            state: "等待确认", model: "Codex · Review", effort: "High",
            steer: "请核对本次更改范围和依赖版本",
            excerpt: "正在核对摘要与原始记录。第一项已经完成，第二项需要对照附件。请保留上次讨论中的条件与例外，再确认是否交付。")
        let sheet = VStack(alignment: .leading, spacing: 14) {
            ForEach(samples.indices, id: \.self) { index in
                let sample = samples[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(sample.label)   ·   \(sample.width.formatted()) × \(sample.height.formatted()) pt")
                        .font(.system(size: 14, weight: .medium))
                    HarnessThreadCard(identity: identity, presentation: presentation,
                                      onRespond: { _ in }, emoji: "🌿")
                        .frame(width: sample.width * CGFloat(presentation.size.cols) + CGFloat(presentation.size.cols - 1) * 16,
                               height: sample.height * CGFloat(presentation.size.rows) + CGFloat(presentation.size.rows - 1) * 16)
                        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 22))
                        .environment(\.threadCardUsesFlatMaterials, true)
                }
            }
        }
        .padding(18).background(Color(white: 0.93)).environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "zh-CN"))
        .environment(\.scenePhase, .active)
        let host = NSHostingView(rootView: sheet)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.coderInvalidValue) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Permission fixture \(presentation.size.cols)×\(presentation.size.rows), \(size) pt, \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) px")
    }
}
