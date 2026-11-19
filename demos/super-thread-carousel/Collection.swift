import Foundation
import Observation
import MokuseiPluginAPI
@testable import MokuseiUI

struct ReportSample: Identifiable {
    let id: String
    let title: String
    let emoji: String
    let summary: String
    let tags: [String]
    let color: String
    let symbol: String
    let caption: String
    let minutesSinceClose: Double?
    var hasCover = true

    static let samples: [Self] = [
        .init(id: "navigation", title: "让导航回到内容本身", emoji: "🧭",
              summary: "统一阅读入口与返回路径，让每一次切换都保留上下文。", tags: ["产品", "原生"],
              color: "#325a55", symbol: "↗", caption: "A clearer way through.", minutesSinceClose: 25),
        .init(id: "typography", title: "阅读的节奏", emoji: "📖",
              summary: "从字体、留白到信息密度，梳理长篇阅读的层次与节奏。", tags: ["产品"],
              color: "#73513f", symbol: "Aa", caption: "Room for every thought.", minutesSinceClose: 18),
        .init(id: "delivery", title: "一次可靠的交付", emoji: "🚀",
              summary: "收拢构建、验证和发布的证据，让工作以清晰的结果结束。", tags: ["工程"],
              color: "#494f78", symbol: "◎", caption: "From work to outcome.", minutesSinceClose: 11),
        .init(id: "recent", title: "新的工作台", emoji: "🌱",
              summary: "将工作入口放在触手可及的位置，同时保持画布安静。", tags: ["产品"],
              color: "#596447", symbol: "+", caption: "Space to begin again.", minutesSinceClose: 3),
        .init(id: "unread", title: "细节里的原生体验", emoji: "✨",
              summary: "从键盘路径到触控板手势，整理尚待查看的原生交互提案。", tags: ["原生", "未读"],
              color: "#5c5871", symbol: "✳", caption: "Small things, considered.", minutesSinceClose: nil)
    ] + (1...4).map { index in
        .init(id: "new-\(index)", title: "新报告 \(index)", emoji: "📄",
              summary: "尚未访问的报告保留在画布中。", tags: ["工程"],
              color: "#494f78", symbol: "▤", caption: "New report \(index)", minutesSinceClose: nil)
    }
    static let panelSamples: [Self] = (4...9).map { index in
        .init(id: "panel-\(index)", title: "面板成员 \(index)", emoji: "📚",
              summary: "用于检查完整成员、长列表滚动和无封面卡片。", tags: ["产品"],
              color: "#325a55", symbol: "\(index)", caption: "Collection member \(index)",
              minutesSinceClose: 20, hasCover: index != 9)
    }
}

struct CollectionProjection {
    let members: [ReportSample]
    let individual: [ReportSample]

    init(reports: [ReportSample], tag: String, closedAt: [String: Date], now: Date) {
        let visible = reports.filter { tag == "全部" || $0.tags.contains(tag) }
        let policy = ApplicationOverviewCollectionPolicy(closedBefore: 300, footprint: .init(columns: 1, rows: 2))
        let eligible = visible.filter { policy.includes(lastClosed: closedAt[$0.id], now: now) }
        var budget = NativeOverviewCollectionBudget(expandedCells: visible.reduce(0) { $0 + ($1.hasCover ? 2 : 1) })
        let count = budget.memberCount(eligible: eligible.map { .init(columns: 1, rows: $0.hasCover ? 2 : 1) },
                                       collection: policy.footprint)
        members = Array(eligible.prefix(count))
        let collected = Set(members.map(\.id))
        individual = visible.filter { !collected.contains($0.id) }
    }
}

struct CarouselSelection {
    private(set) var id: String
    init(first: String) { id = first }
    mutating func select(_ id: String) { self.id = id }
    mutating func step(_ direction: Int, members: [ReportSample]) {
        guard !members.isEmpty else { return }
        let index = members.firstIndex { $0.id == id } ?? 0
        id = members[(index + direction % members.count + members.count) % members.count].id
    }
    mutating func reconcile(members: [ReportSample]) {
        if !members.contains(where: { $0.id == id }), let first = members.first { id = first.id }
    }
}

@MainActor @Observable final class DemoModel {
    static let tags = ["全部", "产品", "原生", "工程", "未读"]
    var manyMembers = false
    var reports: [ReportSample] { ReportSample.samples + (manyMembers ? ReportSample.panelSamples : []) }
    var tag = "全部"
    var closedAt: [String: Date] = [:]
    var now: Date
    var offset: TimeInterval = 0
    var reading: ReportSample?

    init(now: Date = .now) { self.now = now; reset(at: now) }
    var projection: CollectionProjection {
        .init(reports: reports, tag: tag, closedAt: closedAt, now: now)
    }
    func reset(at date: Date = .now) {
        offset = 0; now = date; reading = nil
        closedAt = Dictionary(uniqueKeysWithValues: (ReportSample.samples + ReportSample.panelSamples).compactMap { report in
            report.minutesSinceClose.map { (report.id, date.addingTimeInterval(-$0 * 60)) }
        })
    }
    func open(_ report: ReportSample) { reading = report }
    // Explicit fixture for a qualifying long read; real visit semantics are
    // exported by ProductionProjection through the production Host.
    func closeAfterLongRead(_ report: ReportSample) { closedAt[report.id] = now }
    func tick(at date: Date = .now) { now = date.addingTimeInterval(offset) }
    func advanceDemoTime() { offset += 600; tick() }

    // A windowless data export uses the same projection and selection as the UI.
    // It does not mount AppKit/WebKit or claim to verify gestures or pixels.
    static func describe() throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let model = DemoModel(now: instant)
        func snapshot(_ name: String) -> [String: Any] {
            ["scenario": name, "tag": model.tag,
             "collection": model.projection.members.map(\.id),
             "individual": model.projection.individual.map(\.id)]
        }
        var rows = [[String: Any]]()
        for tag in tags { model.tag = tag; rows.append(snapshot("initial")) }
        model.tag = "全部"
        var selection = CarouselSelection(first: model.projection.members[0].id)
        var pages = [selection.id]
        for _ in 0..<3 { selection.step(1, members: model.projection.members); pages.append(selection.id) }
        rows.append(["scenario": "carousel-forward-wrap", "pages": pages])
        selection.step(-1, members: model.projection.members)
        rows.append(["scenario": "carousel-backward-wrap", "page": selection.id])
        model.closedAt["delivery"] = instant.addingTimeInterval(-300)
        rows.append(snapshot("exactly-five-minutes"))
        model.now = instant.addingTimeInterval(0.001)
        rows.append(snapshot("over-five-minutes"))
        model.reset(at: instant); model.closeAfterLongRead(model.reports[0]); rows.append(snapshot("long-read-close-first"))
        selection.select("navigation"); selection.reconcile(members: model.projection.members)
        rows.append(["scenario": "removed-selection", "page": selection.id])
        model.closeAfterLongRead(model.reports[1]); rows.append(snapshot("long-read-close-second-dissolves-collection"))
        model.now = instant.addingTimeInterval(301); rows.append(snapshot("later-rejoins-never-opened-stays-out"))
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
