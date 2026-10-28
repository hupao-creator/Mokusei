import MokuseiCore
import SwiftUI

/// Only mounted turns publish authors: manifests and summaries are not a
/// substitute for the Harness's resolved runtime model and effort.
struct ThreadAuthorPreference: PreferenceKey {
    static let defaultValue: [JSONText: JSONValue] = [:]
    static func reduce(value: inout [JSONText: JSONValue], nextValue: () -> [JSONText: JSONValue]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ThreadAuthorInHeaderKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var threadAuthorInHeader: Bool {
        get { self[ThreadAuthorInHeaderKey.self] }
        set { self[ThreadAuthorInHeaderKey.self] = newValue }
    }
}

struct ThreadAuthorLabel: View {
    let author: JSONValue?
    @Environment(\.locale) private var locale

    private var label: String {
        let model = author?["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let effort = author?["effort"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return "Author: \(model ?? localize("未知模型")) · \(localize(effort ?? "未记录"))"
    }
    var body: some View {
        Text(label).font(NativeTypography.mono(size: 12))
            .lineLimit(1).truncationMode(.middle)
            .help(label).accessibilityLabel(label).textSelection(.enabled)
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
}

struct ThreadReadingHeader: View {
    let author: JSONValue?
    var showsAuthor = true
    var showsFilters = true
    let users: Bool
    let work: Bool
    let toggleUsers: () -> Void
    let toggleWork: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if showsAuthor { ThreadAuthorLabel(author: author).fixedSize() }
                Spacer(minLength: 0)
                if showsFilters { filters }
            }
            VStack(alignment: .leading, spacing: 8) {
                if showsAuthor { ThreadAuthorLabel(author: author).frame(maxWidth: .infinity, alignment: .leading) }
                if showsFilters { filters }
            }
        }
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localize("消息显示"))
        .nativeReadingObservation("author", role: "turn.author", value: author ?? .null)
    }
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { workButton; usersButton }.fixedSize()
            VStack(alignment: .leading, spacing: 4) { workButton; usersButton }
        }
    }
    private var workButton: some View {
        filter(work ? "收起执行过程" : "显示执行过程", icon: "ListFilter",
               id: "work", role: "visibility.work", value: work, action: toggleWork)
    }
    private var usersButton: some View {
        filter(users ? "隐藏用户消息" : "显示用户消息", icon: users ? "EyeOff" : "Eye",
               id: "userMessages", role: "visibility.userMessages", value: users, action: toggleUsers)
    }
    private func filter(_ title: String, icon: String, id: String, role: String, value: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { NativeIcon(name: icon, size: 12); Text(localize(title)) }
                .font(NativeTypography.inter(size: 11)).padding(.vertical, 5)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(localize(value ? "已展开" : "已收起"))
            .nativeReadingAction(id, role: role, label: localize(title), value: .bool(value), action: action)
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
}
