import MokuseiPluginAPI
import SwiftUI

struct ThreadCardGitExtension: View {
    let status: HarnessGitStatus
    @Environment(\.locale) private var locale
    private var chinese: Bool { locale.language.languageCode?.identifier == "zh" }
    private var branch: String { status.branch?.string ?? status.head.map { "HEAD · \($0.string.prefix(8))" } ?? "HEAD" }
    private var ink: Color { NativePalette.overview.ink.swiftUI }
    private var secondary: Color { NativePalette.overview.muted.swiftUI }
    private var addedColor: Color { NativePalette.pair(0x238341, 0x6ec487).swiftUI }
    private var deletedColor: Color { NativePalette.pair(0xb44338, 0xe18d82).swiftUI }
    private var lineStatsNotice: String? {
        switch status.lineStatsError {
        case .tooLarge: return chinese ? "行数超出统计上限" : "Line count limit exceeded"
        case .timeout: return chinese ? "行数统计超时" : "Line count timed out"
        case .unavailable, .inaccessible: return chinese ? "行数统计不可用" : "Line counts unavailable"
        case nil: return status.additions == nil || status.deletions == nil
            ? (chinese ? "行数未知" : "Line counts unknown") : nil
        }
    }
    private var staleNotice: String? {
        status.error == nil ? nil : (chinese ? "上次读取，可能已过期" : "Last read; may be stale")
    }
    private var help: String {
        [staleNotice, lineStatsNotice, chinese ? "相对 HEAD 的净改动，含未跟踪文件" : "Net changes against HEAD, including untracked files"]
            .compactMap { $0 }.joined(separator: "; ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RollingNumberText(value: String(status.changed), fontSize: 30, color: ink)
                Text(chinese ? "个文件" : status.changed == 1 ? "file" : "files")
                    .cardFont(size: 11).foregroundStyle(secondary)
            }
            Group {
                if let lineStatsNotice {
                    Text(lineStatsNotice).cardFont(size: 11).foregroundStyle(secondary)
                } else if let additions = status.additions, let deletions = status.deletions {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        lineCount(additions, sign: "+", color: addedColor, label: chinese ? "新增行" : "Added lines")
                        lineCount(deletions, sign: "−", color: deletedColor, label: chinese ? "删除行" : "Deleted lines")
                    }
                }
            }.padding(.top, 6)
            if let staleNotice {
                Text(staleNotice).cardFont(size: 10).foregroundStyle(secondary).padding(.top, 6)
            }
            Text(branch).cardFont(size: 11).foregroundStyle(secondary)
                .lineLimit(1).truncationMode(.middle).help(branch)
                .padding(.top, 8)
        }
        .opacity(status.error == nil ? 1 : 0.65)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([chinese ? "Git，\(status.changed) 个文件，\(branch)" : "Git, \(status.changed) files, \(branch)",
            lineStatsNotice ?? "+\(status.additions ?? 0), −\(status.deletions ?? 0)", staleNotice].compactMap { $0 }.joined(separator: "; "))
    }
    private func lineCount(_ value: Int, sign: String, color: Color, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(sign).cardFont(size: 17, monospaced: true)
            RollingNumberText(value: String(value), fontSize: 17, color: color)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
