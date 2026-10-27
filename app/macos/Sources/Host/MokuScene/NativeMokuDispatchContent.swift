import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

/// The approved single row lives inside the production Talk glass and eyes.
struct NativeMokuDispatchContent: View {
    let dispatch: NativeMokuDispatch
    let harness: AnyHarnessPlugin?
    let onDetail: () -> Void
    @Environment(\.locale) private var locale
    private var chinese: Bool { locale.language.languageCode?.identifier == "zh" }

    var body: some View {
        Button(action: onDetail) {
            HStack(spacing: 8) {
                if let harness { harness.logo(size: 15).help(harness.descriptor.displayName.string) }
                else { Image(systemName: "arrow.up.forward.app").frame(width: 15).help(dispatch.harnessID.string) }
                Text(dispatch.sentence(chinese: chinese))
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("moku-dispatch-status")
                if !dispatch.configuration.isEmpty {
                    HStack(spacing: 3) {
                        if let model = dispatch.model { Text(model).truncationMode(.middle) }
                        if let thinking = dispatch.thinking {
                            if dispatch.model != nil { Text("·") }
                            Text(thinking).layoutPriority(1)
                        }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
                    .help(dispatch.configuration)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(dispatch.configuration)
                    .accessibilityIdentifier("moku-dispatch-configuration")
                }
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .help(chinese ? "查看输入内容与派发详情" : "View input and dispatch details")
        .accessibilityIdentifier("moku-dispatch-details")
        .animation(.easeInOut(duration: 0.22), value: dispatch)
    }
}

struct NativeMokuDispatchDetail: View {
    let dispatch: NativeMokuDispatch
    let harness: AnyHarnessPlugin?
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    private func localize(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                if let harness { harness.logo(size: 22) }
                Text(harness?.descriptor.displayName.string ?? dispatch.harnessID.string)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel(localize("关闭派发详情", "Close dispatch details"))
            }
            Text(localize("输入内容", "Input content")).font(.system(size: 20, weight: .semibold))
            ScrollView {
                Text(dispatch.prompt ?? localize("输入内容不可用", "Input content unavailable"))
                    .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    field(localize("状态", "Status"), dispatch.sentence(chinese: locale.language.languageCode?.identifier == "zh"))
                    if let model = dispatch.model { field(localize("模型", "Model"), model) }
                    if let thinking = dispatch.thinking { field("Thinking", thinking) }
                    if let provider = dispatch.provider { field("Provider", provider) }
                    if let thread = dispatch.threadID { field("Thread", thread) }
                    if let error = dispatch.error { field(localize("错误", "Error"), error) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
        }.padding(30).frame(width: 490)
            .accessibilityIdentifier("moku-dispatch-input-detail")
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Resolve inside the sheet's body so catalog changes invalidate the selected
/// operation even while a different talk or dispatch owns the Dock.
struct NativeMokuDispatchSheet: View {
    let selected: NativeMokuTalkMessage
    let presentation: NativeMokuWorkspacePresentation?
    var body: some View {
        let message = NativeMokuTalkMessage.dispatch(id: selected.id, in: presentation?.workspace.catalog.moku) ?? selected
        if let dispatch = message.dispatch {
            NativeMokuDispatchDetail(dispatch: dispatch,
                harness: try? presentation?.workspace.plugins.harnesses.require(dispatch.harnessID))
        }
    }
}
