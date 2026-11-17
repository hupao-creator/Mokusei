import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// A fixed reading header and one scroll owner, independent of canvas scale.
struct NativeReportCollectionMembers: View {
    let props: [ApplicationThreadProps<NativeReportView>]
    let locale: JSONText
    let close: () -> Void
    let allowsActions: (ApplicationThreadRef) -> Bool
    let openThread: (ApplicationThreadRef) -> Void

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 500 ? 16 : 28
            let available = max(1, min(1160, geometry.size.width - 2 * inset))
            let columns = max(1, Int((available + 20) / 300))
            let width = min(360, (available - CGFloat(columns - 1) * 20) / CGFloat(columns))
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    NativeReadingPanelCloseButton(label: applicationText(locale, "关闭", "Close"), onClose: close)
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                    Text(applicationText(locale, "全部 Super Thread", "All Super Threads"))
                        .font(NativeTypography.inter(size: 16, weight: 620)).lineLimit(1)
                    Text("\(props.count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Color.clear.frame(width: 32, height: 32)
                }.padding(14)
                NativeScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 20, alignment: .top), count: columns),
                              alignment: .center, spacing: 20) {
                        ForEach(props, id: \.entry.ref) { member in
                            NativeReportCard(props: member,
                                projection: .init(previewText: member.entry.view.shortDescription,
                                                  relatedThreadCount: member.entry.view.relatedExecutions.count),
                                openThread: { openThread(member.entry.ref) },
                                allowsActions: { allowsActions(member.entry.ref) })
                                .frame(height: member.entry.view.hasCover
                                    ? NativeReportCoverLayout.height(for: width) + 168 : 164)
                                .background(NativePalette.overview.surface.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                                .overlay { RoundedRectangle(cornerRadius: 22).stroke(NativePalette.overview.lineSoft.swiftUI) }
                        }
                    }.frame(maxWidth: .infinity)
                        .padding(.horizontal, inset).padding(.top, 12).padding(.bottom, 28)
                }
            }
        }
        .background(NativePalette.thread.canvas.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .background(NativeReadingPanelFrame(identifier: "collection-members-panel"))
    }
}
