import ChiefCore
import ChiefPluginAPI
import ChiefPluginUI
import SwiftUI

/// A floating close control and one scroll owner, independent of canvas scale.
struct NativeReportCollectionMembers: View {
    let props: [ApplicationThreadProps<NativeReportView>]
    let locale: JSONText
    let close: () -> Void
    let allowsActions: (ApplicationThreadRef) -> Bool
    let openThread: (ApplicationThreadRef) -> Void
    @State private var displayedMembers: [Member]?
    @State private var replayIDs: [CoverIdentity: Int] = [:]
    @State private var completed: [CoverIdentity: Int] = [:]

    private static let exitDuration = 0.16
    private struct Member: Identifiable {
        let id: ApplicationThreadRef
        let props: ApplicationThreadProps<NativeReportView>
        var exitDeadline: ContinuousClock.Instant?

        @MainActor init(_ props: ApplicationThreadProps<NativeReportView>) {
            self.id = props.entry.ref
            self.props = props
        }
    }

    var body: some View {
        let current = Dictionary(uniqueKeysWithValues: props.map { ($0.entry.ref, $0) })
        let members = displayedMembers ?? props.map(Member.init)
        let nextExitDeadline = members.compactMap(\.exitDeadline).min()
        GeometryReader { geometry in
            // At high window zoom the panel can be narrower than a single
            // Overview card. Fit the card layout and its hit targets together.
            let compact = geometry.size.width < NativeGeometry.overviewCard.width
            let layoutWidth = max(geometry.size.width, NativeGeometry.overviewCard.width)
            let scale = max(1, geometry.size.width) / layoutWidth
            let inset: CGFloat = compact ? 14 : 54
            let available = min(1160, layoutWidth - 2 * inset)
            let spacing: CGFloat = 20
            let columns = max(1, Int((available + spacing) / 300))
            let gapsWidth = CGFloat(columns - 1) * spacing
            let width = min(360, (available - gapsWidth) / CGFloat(columns))
            let leadingMargin = (layoutWidth - CGFloat(columns) * width - gapsWidth) / 2
            NativeScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: spacing, alignment: .top), count: columns),
                          alignment: .center, spacing: spacing) {
                    ForEach(members) { displayed in
                        let live = current[displayed.id]
                        let member = live ?? displayed.props
                        let exiting = live == nil
                        let identity = CoverIdentity(reference: member.entry.ref, revision: member.entry.view.coverRevision)
                        let replayID = replayIDs[identity, default: 0]
                        CollectionMemberCard(member: member, width: width,
                            replayID: replayID, initiallyFinished: completed[identity] == replayID,
                            replay: { replayIDs[identity, default: 0] += 1 },
                            onPlaybackCompleted: { reference, revision, generation in
                                completed[CoverIdentity(reference: reference, revision: revision)] = generation
                            },
                            exiting: exiting, allowsActions: { !exiting && allowsActions(member.entry.ref) },
                            openThread: { openThread(member.entry.ref) })
                            .scaleEffect(exiting ? 0.98 : 1)
                            .opacity(exiting ? 0 : 1)
                            .animation(.easeOut(duration: Self.exitDuration), value: exiting)
                            .allowsHitTesting(!exiting)
                            .accessibilityHidden(exiting)
                    }
                }.frame(maxWidth: .infinity)
                    .padding(.horizontal, inset).padding(.top, compact ? 0 : leadingMargin - 8).padding(.bottom, 28)
            }
            // In a single compact column, clear Close vertically for every
            // scroll position. The overlay still owns only the button.
            .padding(.top, compact ? 54 : 0)
            .overlay(alignment: .topLeading) {
                NativeReadingPanelCloseButton(label: applicationText(locale, "关闭", "Close"), onClose: close)
                    .keyboardShortcut(.cancelAction)
                    .padding(14)
            }
            .frame(width: layoutWidth, height: geometry.size.height / scale)
            .scaleEffect(scale, anchor: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .background(NativeReadingPanelFrame(identifier: "collection-members-panel"))
        .onChange(of: props.map(\.entry), initial: true) { _, _ in reconcileMembers(currentIDs: Set(current.keys)) }
        .task(id: nextExitDeadline) {
            guard let nextExitDeadline else { return }
            do {
                try await ContinuousClock().sleep(until: nextExitDeadline)
                try Task.checkCancellation()
                let now = ContinuousClock.now
                displayedMembers?.removeAll { member in
                    member.exitDeadline.map { $0 <= now } ?? false
                }
            } catch { /* Replaced membership or a closed panel cancels the wait. */ }
        }
    }

    private func reconcileMembers(currentIDs: Set<ApplicationThreadRef>) {
        var next = props.map(Member.init)
        if let displayedMembers {
            let deadline = ContinuousClock.now + .seconds(Self.exitDuration)
            // Retain only the outgoing card's last content and seat. A restored
            // reference keeps its mounted identity and drops its old deadline.
            for (index, var member) in displayedMembers.enumerated() where !currentIDs.contains(member.id) {
                member.exitDeadline = member.exitDeadline ?? deadline
                next.insert(member, at: min(index, next.count))
            }
        }
        displayedMembers = next
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
    let exiting: Bool
    let allowsActions: () -> Bool
    let openThread: () -> Void
    @Environment(\.nativeCollectionPanel) private var collectionPanel
    @State private var visible = false
    @State private var source = NativeCollectionPanelSource()

    var body: some View {
        NativeReportCard(props: member,
            projection: .init(previewText: member.entry.view.shortDescription,
                              relatedThreadCount: member.entry.view.relatedExecutions.count),
            openThread: openThread, coverPlayback: visible && !exiting && collectionPanel?.readingMember == nil ? .playingOnce : .paused,
            coverReplayID: replayID, coverInitiallyFinished: initiallyFinished,
            onCoverPlaybackCompleted: onPlaybackCompleted,
            showsArchiveAction: true, allowsActions: allowsActions, memberSource: source)
            .frame(height: member.entry.view.hasCover ? NativeReportCoverLayout.height(for: width) + 160 : 208)
            .background(NativeCollectionPanelAnchor(source))
            .background(NativePalette.overview.surface.swiftUI, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(NativePalette.overview.lineSoft.swiftUI) }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .onHover { inside in if inside && visible && !exiting && collectionPanel?.readingMember == nil { replay() } }
    }
}
