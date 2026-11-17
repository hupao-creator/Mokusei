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
    @State private var replayIDs: [CoverIdentity: Int] = [:]
    @State private var completed: [CoverIdentity: Int] = [:]

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
                            let identity = CoverIdentity(reference: member.entry.ref, revision: member.entry.view.coverRevision)
                            let replayID = replayIDs[identity, default: 0]
                            CollectionMemberCard(member: member, width: width,
                                replayID: replayID, initiallyFinished: completed[identity] == replayID,
                                replay: { replayIDs[identity, default: 0] += 1 },
                                onPlaybackCompleted: { reference, revision, generation in
                                    completed[CoverIdentity(reference: reference, revision: revision)] = generation
                                },
                                allowsActions: { allowsActions(member.entry.ref) },
                                openThread: { openThread(member.entry.ref) })
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

private struct CoverIdentity: Hashable {
    let reference: ApplicationThreadRef
    let revision: JSONText
}

/// Playback history belongs to the panel visit, independent of WebKit appearance.
private struct CollectionMemberCard: View {
    let member: ApplicationThreadProps<NativeReportView>
    let width: CGFloat
    let replayID: Int
    let initiallyFinished: Bool
    let replay: () -> Void
    let onPlaybackCompleted: (ApplicationThreadRef, JSONText, Int) -> Void
    let allowsActions: () -> Bool
    let openThread: () -> Void
    @State private var visible = false

    var body: some View {
        NativeReportCard(props: member,
            projection: .init(previewText: member.entry.view.shortDescription,
                              relatedThreadCount: member.entry.view.relatedExecutions.count),
            openThread: openThread, coverPlayback: visible ? .playingOnce : .paused,
            coverReplayID: replayID, coverInitiallyFinished: initiallyFinished,
            onCoverPlaybackCompleted: onPlaybackCompleted,
            showsArchiveAction: true, allowsActions: allowsActions)
            .frame(height: member.entry.view.hasCover ? NativeReportCoverLayout.height(for: width) + 212 : 208)
            .background(NativePalette.overview.surface.swiftUI, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(NativePalette.overview.lineSoft.swiftUI) }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .onHover { inside in if inside && visible { replay() } }
    }
}
