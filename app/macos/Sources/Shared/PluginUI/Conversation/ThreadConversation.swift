import AppKit
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import WebKit

public struct ThreadConversationExecution: Hashable, Sendable {
    public let id: JSONText
    public let title: String?
    public let prompt: String
    public let answer: String
    public let completedAt: Double?
    public let readable: Bool
    public init(id: JSONText, title: String? = nil, prompt: String, answer: String, completedAt: Double? = nil, readable: Bool = true) {
        self.id = id; self.title = title; self.prompt = prompt; self.answer = answer; self.completedAt = completedAt; self.readable = readable
    }
}

extension ThreadConversationRow {
    // Never substitute the mutable Thread title or another execution's prompt.
    var executionTitle: String { execution?.title ?? formatThreadTimestamp(createdAt) }
}

/// Short-lived render projection. Each Harness owns interpretation, ordering, and the content node.
public struct ThreadConversationRow: Identifiable {
    public let id: JSONText
    public let createdAt: Double
    public let execution: ThreadConversationExecution?
    public let history: Bool
    public let node: AnyView
    public init(id: JSONText, createdAt: Double, execution: ThreadConversationExecution? = nil,
                history: Bool = false, node: AnyView) {
        self.id = id; self.createdAt = createdAt; self.execution = execution; self.history = history; self.node = node
    }
}

public struct ThreadConversationReadingTarget: Hashable, Sendable {
    public enum Mode: String, Sendable { case current, history }
    public let requestId: JSONText
    public let mode: Mode
    public let executionId: JSONText
    public let anchorId: JSONText?
    public let follow: Bool
    public let hasMessageTarget: Bool
    public let position: HarnessReadingTarget.Position
    public init(requestId: JSONText, mode: Mode, executionId: JSONText, anchorId: JSONText? = nil, position: HarnessReadingTarget.Position = .start, follow: Bool = false, hasMessageTarget: Bool = false) {
        self.requestId = requestId; self.mode = mode; self.executionId = executionId; self.anchorId = anchorId; self.position = position; self.follow = follow; self.hasMessageTarget = hasMessageTarget
    }
}

private enum ConversationDestination: Equatable {
    case document(inline: JSONText?)
    case history(JSONText)
    case unavailable
}
private struct HistoryVisitID: Hashable {
    let row: JSONText?
    let request: JSONText?
    let revision: Int
}

/// History construction, filtering, and read requests share one row identity space.
public struct ThreadConversation: View {
    public let threadId: JSONText
    public let title: String
    public let icon: String?
    public let rows: [ThreadConversationRow]
    public let readingTarget: ThreadConversationReadingTarget?
    public let running: Bool
    public let runningTurnId: JSONText?
    /// Includes waiting for input, which must retain the scroll action without
    /// changing the running-only work visibility and opening behavior.
    public let activeExecutionId: JSONText?
    public let context: HarnessRenderContext?
    public let actions: AnyView?
    public let emptyState: AnyView?
    public let renderRow: ((JSONText) -> AnyView)?
    @Environment(\.nativeThreadReservesHistoryRail) private var reservesHistoryRail
    @Environment(\.locale) private var locale
    @Environment(\.nativeReadingContentHandoff) private var contentHandoff
    @Environment(\.threadDetailNavigation) private var navigation
    @Environment(\.threadDetailRootNavigation) private var rootNavigation
    @State private var authors: [JSONText: JSONValue] = [:]
    @State private var sidebarFocusRevision = 0
    @State private var userMessages = false
    @Environment(\.threadAgentDetail) private var agentDetail
    @Environment(\.threadRelatedExecution) private var relatedExecution
    @State private var manualWork: Bool?
    @State private var destination: ConversationDestination = .document(inline: nil)
    @State private var consumedRequest: JSONText?
    @State private var requestedDestination: ConversationDestination?
    @State private var acceptedAnchor: JSONText?
    @State private var locatedRequest: JSONText?
    @State private var navigationRevision = 0
    @State private var pageMotion = NativeReadingPageMotion()
    @State private var pageDirection: CGFloat = -1
    @State private var navigationToken: UUID?
    @State private var initializedThread: JSONText?
    @State private var hasMountedCurrentDocument = false

    public init(threadId: JSONText, title: String, icon: String? = nil, rows: [ThreadConversationRow],
                readingTarget: ThreadConversationReadingTarget? = nil, running: Bool = false,
                runningTurnId: JSONText? = nil, activeExecutionId: JSONText? = nil, context: HarnessRenderContext? = nil,
                actions: AnyView? = nil, emptyState: AnyView? = nil, renderRow: ((JSONText) -> AnyView)? = nil) {
        self.threadId = threadId; self.title = title; self.icon = icon; self.rows = rows
        self.readingTarget = readingTarget; self.running = running; self.runningTurnId = runningTurnId
        self.activeExecutionId = activeExecutionId ?? runningTurnId
        self.context = context; self.actions = actions; self.emptyState = emptyState; self.renderRow = renderRow
    }
    private var executionCard: Bool {
        if case .execution = context?.presentation { return true }; return false
    }
    private var excluded: Set<JSONText> {
        if case let .main(ids) = context?.presentation { return Set(ids) }; return []
    }
    private var visibleRows: [ThreadConversationRow] {
        if case let .execution(id) = context?.presentation { return rows.filter { $0.execution?.id == id } }
        let excluded = excluded
        return rows.filter { row in row.execution.map { !excluded.contains($0.id) } ?? true }
    }
    private var lastExecutionIndex: Int? { visibleRows.lastIndex { $0.execution != nil } }
    private var historicalIDs: Set<JSONText> {
        guard let lastExecutionIndex else { return [] }
        return Set(visibleRows.prefix(lastExecutionIndex).filter { $0.execution != nil }.map(\.id))
    }
    private var tocRows: [ThreadConversationRow] { visibleRows.filter { $0.execution != nil || $0.history } }
    private var currentRow: ThreadConversationRow? { visibleRows.last { $0.execution != nil } }
    private var selectedRowID: JSONText? {
        if case .history = destination { return selectedPage?.id }
        if case .unavailable = destination { return nil }
        return inlineRow ?? currentRow?.id
    }
    private var effectiveRunningID: JSONText? {
        guard let runningTurnId, !excluded.contains(runningTurnId) else { return nil }
        if case let .execution(id) = context?.presentation, id != runningTurnId { return nil }
        return runningTurnId
    }
    private var selectedIsRunning: Bool {
        running && effectiveRunningID != nil && visibleRows.first { $0.id == selectedRowID }?.execution?.id == effectiveRunningID
    }
    private var allowsJumpToLatest: Bool {
        guard let activeExecutionId, !excluded.contains(activeExecutionId) else { return false }
        if case let .execution(id) = context?.presentation, id != activeExecutionId { return false }
        return true
    }
    private var work: Bool { !relatedExecution && (executionCard || selectedIsRunning || (manualWork ?? (effectiveRunningID != nil))) }
    private var visibility: ThreadDetailVisibility {
        ThreadDetailVisibility(userMessages: !agentDetail && (executionCard || userMessages), work: work,
                               workTurnID: executionCard || manualWork == true ? nil : effectiveRunningID,
                               messageAnchorID: destination == requestedDestination ? acceptedAnchor : nil)
    }
    private var inlineRow: JSONText? {
        if case let .document(inline) = destination { return inline }; return nil
    }
    private var readingPage: Bool {
        if case .document = destination { return false }; return true
    }
    private var selectedPage: ThreadConversationRow? {
        if case let .history(id) = destination { return visibleRows.first { $0.id == id } }
        return nil
    }
    private var resultVisit: Bool {
        readingTarget?.position == .result && destination == requestedDestination
    }
    // A requested document is the host route's entry, regardless of scroll
    // position. The retained current document is not a previous visit until
    // explicit in-thread navigation clears requestedDestination.
    private var entryRoute: Bool {
        requestedDestination != nil && destination == requestedDestination && rootNavigation != nil
    }
    private var runningStartVisit: Bool {
        agentDetail && running && effectiveRunningID != nil && readingTarget?.executionId == effectiveRunningID
            && readingTarget?.position == .start && readingTarget?.hasMessageTarget == false && readingTarget?.anchorId == nil
    }
    private var scrollTarget: ThreadTimelineReadingTarget? {
        guard destination == requestedDestination, let consumedRequest else { return nil }
        // A default execution link has no message anchor. Register its row while
        // the scoped body loads, then keep following all subsequent layout growth.
        let anchor = runningStartVisit ? visibleRows.first { $0.execution?.id == effectiveRunningID }?.id : acceptedAnchor
        guard let anchor else { return nil }
        return ThreadTimelineReadingTarget(requestId: consumedRequest, anchorId: anchor,
            follow: runningStartVisit || (readingTarget?.position == .result && readingTarget?.follow == true))
    }
    public var body: some View {
        Group {
            if case let .row(id) = context?.content {
                if let row = visibleRows.first(where: { $0.id == id }) { row.node.nativeReadingContentReady() }
                else if !rows.contains(where: { $0.id == id }) {
                    Text(localize("这轮对话已不可用。")).foregroundStyle(NativePalette.thread.danger.swiftUI)
                        .nativeReadingContentReady()
                }
            } else if initializedThread != threadId {
                // Resolve the entry request before mounting any reader. Otherwise
                // a direct history/result visit first loads the current execution
                // and starts a second page entrance while both bodies lay out.
                // A surface placeholder creates NativeThreadOpeningContent,
                // which mounts another conversation under an identity visit.
                // Admission must remain a leaf or layout recurses before onChange.
                NativeReadingPlaceholder(placement: .inline)
            } else {
                readingLayout.nativeReadingScope(interactionScope)
            }
        }
        // This layout owns the rail. Nested loading/error rows already sit to
        // its right and must not reserve another rail of their own.
        .environment(\.nativeThreadReservesHistoryRail, false)
        .nativeLayoutLog("conversation.reader")
        .font(NativeTypography.inter(size: 16))
        .environment(\.nativeInteractionQuestionInDocument, true)
        .foregroundStyle(NativePalette.thread.ink.swiftUI)
        .background(NativePalette.thread.canvas.swiftUI)
        .onChange(of: threadId, initial: true) { _, _ in
            userMessages = false; manualWork = nil
            hasMountedCurrentDocument = false
            destination = .document(inline: nil); consumedRequest = nil; requestedDestination = nil; acceptedAnchor = nil; locatedRequest = nil
            consumeReadingTarget()
            initializedThread = threadId
        }
        .onChange(of: effectiveRunningID) { _, _ in manualWork = nil }
        .onChange(of: readingTarget) { _, _ in consumeReadingTarget() }
        .onChange(of: visibleRows.map(\.id)) { _, _ in promoteCurrentPage(); consumeReadingTarget() }
        .onChange(of: visibleRows.map { $0.execution?.readable }) { _, _ in consumeReadingTarget() }
        .onChange(of: readingPage && !entryRoute, initial: true) { _, open in
            if let token = navigationToken { navigation?.unregister(token); navigationToken = nil }
            if open {
                navigationToken = navigation?.register(ThreadDetailBackAction(label: localize("返回当前会话"), onBack: closeHistory))
            }
        }
        .onDisappear { if let token = navigationToken { navigation?.unregister(token) } }
        .onChange(of: index, initial: true) { _, value in
            if case .row = context?.content { return }
            if case .main = context?.presentation { context?.onIndexChange(value) }
        }
    }
    private var index: ThreadConversationIndex {
        ThreadConversationIndex(executionIDs: rows.compactMap { $0.execution?.id },
                                hasInheritedHistory: rows.contains { $0.history || $0.execution?.readable == false })
    }
    private var readingLayout: some View {
        GeometryReader { bounds in
            HStack(spacing: 0) {
                if !executionCard && (tocRows.count > 1 || tocRows.contains(where: \.history) || readingPage) {
                    ThreadHistorySidebar(rows: tocRows, selected: selectedRowID, current: currentRow?.id,
                        availableWidth: bounds.size.width, focusRevision: sidebarFocusRevision, select: selectRow)
                        .padding(.leading, 4).padding(.vertical, 64)
                        .nativeReadingScope("sidebar")
                        .zIndex(1)
                }
                if !executionCard && reservesHistoryRail && !(tocRows.count > 1 || tocRows.contains(where: \.history) || readingPage) {
                    Color.clear.frame(width: 48)
                }
                pageStack
            }
            .nativeReadingExitCommand(perform: readingPage ? { closeHistory() } : nil)
        }
    }
    private var pageStack: some View {
        GeometryReader { _ in
            NativeReadingPageStack(open: readingPage, identity: readingIdentity, motion: pageMotion,
                                   axis: .vertical,
                                   direction: pageDirection,
                                   onClose: finishClosingHistory) {
                if hasMountedCurrentDocument || !readingPage || !entryRoute {
                    HarnessMessageTimeline(timelineKey: threadId,
                        documentKey: agentDetail && !executionCard ? currentRow?.id : nil, rows: documentRows,
                        toolbar: AnyView(documentHeader()), emptyState: effectiveEmptyState,
                        contentTopInset: executionCard || agentDetail ? 12 : nil,
                        suspended: readingPage, followOutput: true,
                        allowsJumpToLatest: allowsJumpToLatest,
                        opensAtBottom: agentDetail && running && effectiveRunningID != nil && requestedDestination == nil,
                        followKey: effectiveRunningID,
                        followPaused: inlineRow.map { historicalIDs.contains($0) } == true,
                        onJumpToLatest: {
                            destination = .document(inline: nil); requestedDestination = nil; acceptedAnchor = nil
                        }, showOlderRows: false, pinnedRowId: inlineRow,
                        readingTarget: readingPage ? nil : scrollTarget,
                        readingVisitId: destination == requestedDestination ? consumedRequest : nil, locatedRequestId: locatedRequest,
                        onLocated: { locatedRequest = $0 })
                        .environment(\.threadDetailVisibility, visibility)
                        .environment(\.threadAuthorInHeader, true)
                        .onPreferenceChange(ThreadAuthorPreference.self) { authors = $0 }
                        .environment(\.nativeInteractionQuestionInDocument, true)
                        .allowsHitTesting(!readingPage).accessibilityHidden(readingPage)
                        .nativeReadingScope("current")
                        .nativeReadingActive(!readingPage && !pageMotion.active)
                        .transformPreference(NativeReadingContentRevealStatusKey.self) { status in
                            if readingPage { status = .init() }
                        }
                        .onAppear { hasMountedCurrentDocument = true }
                } else {
                    // A direct history route exits to its host. There is no
                    // previous current document to restore or pre-render. Once
                    // current participates, retain its actual scroll state.
                    Color.clear
                }
            } front: {
                if readingPage {
                    historyPage()
                        .background(NativePalette.thread.canvas.swiftUI)
                        .environment(\.nativeInteractionQuestionInDocument, true)
                }
            }
            .clipped()
        }.padding(.vertical, (agentDetail && !executionCard) || (executionCard && !relatedExecution) ? 0 : 12)
            .transformPreference(NativeReadingContentRevealStatusKey.self) { status in
                // Empty/error history pages have no turn to hold the boundary
                // while their own reading stack is still travelling.
                status.revealing = status.revealing || pageMotion.active
            }
            .nativeReadingObservation("state", role: "conversation", value: .object([
                "destination": .text(readingPage ? selectedPage == nil ? "unavailable" : "history" : "current"),
                "historyRow": selectedPage.map { .string($0.id) } ?? .null,
                "selectedRow": selectedRowID.map(JSONValue.string) ?? .null,
                "userMessages": .bool(!agentDetail && userMessages), "work": .bool(work),
                "rowCount": .integer(visibleRows.count), "historicalCount": .integer(historicalIDs.count),
                "transitioning": .bool(pageMotion.active)
            ]))
    }
    private var interactionScope: String {
        if case let .execution(id) = context?.presentation { return "execution." + nativeReadingInteractionKey(id) }
        return "conversation." + nativeReadingInteractionKey(threadId)
    }
    private var readingIdentity: JSONText {
        let values: [JSONText?] = [threadId, consumedRequest, selectedPage?.id, JSONText(String(navigationRevision))]
        return JSONText(codeUnits: values.flatMap { value -> [UInt16] in
            guard let value else { return Array("-:".utf16) }
            return Array("\(value.codeUnits.count):".utf16) + value.codeUnits
        })
    }
    private func documentHeader() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !executionCard || relatedExecution { heading(documentTitle, emoji: icon ?? "📝") }
            if let actions { actions.padding(.top, 15) }
            if !rows.isEmpty {
                let selected = selectedRowID
                let authorID = visibleRows.first { $0.id == selected }?.execution?.id
                ThreadReadingHeader(author: authorID.flatMap { authors[$0] }, showsAuthor: authorID != nil,
                    showsFilters: !executionCard, showsWorkFilter: !selectedIsRunning, users: userMessages, work: work,
                    toggleUsers: { userMessages.toggle() }, toggleWork: { manualWork = !work })
                    .padding(.top, executionCard && !relatedExecution ? 0 : 12).padding(.bottom, executionCard ? 12 : 16)
            } else { Color.clear.frame(height: 16) }
        }
    }
    private var documentTitle: String {
        if relatedExecution, let row = visibleRows.first(where: { $0.id == selectedRowID }) {
            return row.executionTitle
        }
        // Main can retain an older execution while the newest one lives in a
        // Sidecard. Its heading must not borrow the newest catalog title.
        if agentDetail, let row = visibleRows.first(where: { $0.id == selectedRowID }),
           row.execution != nil, row.execution?.id != rows.last(where: { $0.execution != nil })?.execution?.id {
            return row.executionTitle
        }
        return title
    }
    private func heading(_ title: String, emoji: String) -> some View {
        NativeThreadHeading(title: title, emoji: emoji)
    }

    private var documentRows: [ThreadTimelineRow] {
        let historical = historicalIDs
        // The sidebar owns history navigation. Do not keep empty historical
        // slots in the content window or acquire their scoped body resources.
        return visibleRows.filter { row in
            !row.history && (!historical.contains(row.id) || row.id == inlineRow)
        }.map { row in
            ThreadTimelineRow(id: row.id, createdAt: row.createdAt, node: content(row))
        }
    }
    private func content(_ row: ThreadConversationRow) -> AnyView {
        let content: AnyView
        if case .manifest = context?.content, let renderRow { content = renderRow(row.id) }
        else { content = AnyView(row.node.nativeReadingContentReady()) }
        return AnyView(content.environment(\.nativeReadingContentReady,
            row.execution?.id == contentHandoff?.executionID ? contentHandoff?.ready : nil))
    }
    private func historyPage() -> some View {
        ThreadHistoryDocument(threadId: threadId, page: selectedPage, rowContent: selectedPage.map(content),
                              active: resultVisit ? readingTarget?.follow == true : selectedPage?.execution?.id == effectiveRunningID,
                              running: running && effectiveRunningID != nil && selectedPage?.execution?.id == effectiveRunningID,
                              allowsJumpToLatest: allowsJumpToLatest && selectedPage?.execution?.id == activeExecutionId,
                              result: resultVisit, readingTarget: scrollTarget,
                              readingVisitId: destination == requestedDestination ? consumedRequest : nil,
                              locatedRequestId: locatedRequest, onLocated: { locatedRequest = $0 },
                              backLabel: (entryRoute ? rootNavigation?.label : nil) ?? localize("返回当前会话"),
                              focusHeading: destination == requestedDestination && contentHandoff == nil, onBack: closeHistory)
        .id(HistoryVisitID(row: selectedPage?.id, request: consumedRequest, revision: navigationRevision))
        .nativeReadingScope("history")
        .nativeReadingActive(!pageMotion.active)
    }
    private var effectiveEmptyState: AnyView {
        if let emptyState { return AnyView(emptyState.nativeReadingContentReady()) }
        if executionCard { return AnyView(NativeReadingPlaceholder(placement: .inline)) }
        return AnyView(ThreadDetailEmptyState().nativeReadingContentReady())
    }
    private func closeHistory() {
        if entryRoute { rootNavigation?.onBack(); return }
        setPageDirection(toward: currentRow?.id, returning: true)
        pageMotion.close()
    }
    private func finishClosingHistory() {
        destination = .document(inline: nil); requestedDestination = nil; acceptedAnchor = nil
        navigationRevision += 1; sidebarFocusRevision += 1
    }
    private func selectRow(_ id: JSONText) {
        guard visibleRows.contains(where: { $0.id == id }) else { return }
        // Re-selecting a settled history page must not retire its live resource.
        // During Back or an external reading visit, selection still changes ownership.
        if case let .history(selected) = destination, selected == id, !pageMotion.active, requestedDestination == nil { return }
        // Invalidate an interrupted Back animation before selecting another
        // turn; its delayed completion must not replace the new destination.
        pageMotion.cancel()
        setPageDirection(toward: id, returning: id == currentRow?.id && readingPage)
        requestedDestination = nil; acceptedAnchor = nil
        if id == currentRow?.id {
            if readingPage { pageMotion.close(); return }
            destination = .document(inline: nil)
        } else {
            destination = .history(id)
        }
        navigationRevision += 1
    }
    private func setPageDirection(toward id: JSONText?, returning: Bool = false) {
        let indexRows = tocRows
        let previousID = selectedRowID
        guard let previous = indexRows.firstIndex(where: { $0.id == previousID }),
              let target = indexRows.firstIndex(where: { $0.id == id }), previous != target else {
            pageDirection = 0
            return
        }
        // Closing moves the front out, so its travel is the inverse of the
        // incoming current document. History replacements use insertion travel.
        let incoming: CGFloat = target > previous ? 1 : -1
        pageDirection = returning ? -incoming : incoming
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
    private func consumeReadingTarget() {
        guard let target = readingTarget, !excluded.contains(target.executionId) else {
            // A removed public request returns to the current document. An
            // already-absent request leaves manually opened history alone.
            if consumedRequest != nil {
                consumedRequest = nil; requestedDestination = nil; acceptedAnchor = nil; locatedRequest = nil
                destination = .document(inline: nil); navigationRevision += 1
            }
            return
        }
        let index = visibleRows.firstIndex { $0.execution?.id == target.executionId && $0.execution?.readable != false }
        if consumedRequest == target.requestId {
            guard destination == requestedDestination else { return }
            // Lifecycle delivery can precede the reader's manifest. Reconcile
            // availability without inventing a new visit or changing its target.
            if destination == .unavailable, index != nil { locatedRequest = nil }
            else if destination != .unavailable, index == nil { locatedRequest = nil }
            else {
                if acceptedAnchor == nil { acceptedAnchor = target.anchorId }
                return
            }
        }
        consumedRequest = target.requestId
        acceptedAnchor = target.position == .result ? threadExecutionResultAnchor(target.executionId) : target.anchorId
        if let index {
            let id = visibleRows[index].id
            setPageDirection(toward: id)
            // A result visit owns exactly one execution, including while it is
            // current. A successor cannot move its content or following target.
            destination = target.position == .result ? .history(id)
                : target.mode == .current || index == lastExecutionIndex ? .document(inline: id) : .history(id)
        } else { destination = .unavailable }
        requestedDestination = destination
    }
    private func promoteCurrentPage() {
        if case let .document(inline?) = destination, !visibleRows.contains(where: { $0.id == inline }) {
            destination = .document(inline: nil)
        }
        guard !resultVisit, case let .history(id) = destination, visibleRows.contains(where: { $0.id == id && !$0.history }), !historicalIDs.contains(id) else { return }
        let promoted = ConversationDestination.document(inline: id)
        if requestedDestination == destination { requestedDestination = promoted }
        destination = promoted
    }
}

public struct ThreadDetailEmptyState: View {
    @Environment(\.locale) private var locale
    public init() {}
    public var body: some View {
        Text("""
               .            *
                    /\\_/\\
                   ( o.o )       .
                    > ^ <
               .-------------.
               |             |
               |   > hello   |
               |_____________|
                /___________\\
        """)
        .font(.system(size: 14, design: .monospaced)).lineSpacing(3)
        .foregroundStyle(NativePalette.thread.muted.swiftUI).frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityLabel(NativePluginLocalization.localize("一只小猫坐在电脑后面，等待新的想法。", locale: locale))
    }
}

private struct ThreadHistoryDocument: View {
    let threadId: JSONText
    let page: ThreadConversationRow?
    let rowContent: AnyView?
    let active: Bool
    let running: Bool
    let allowsJumpToLatest: Bool
    let result: Bool
    let readingTarget: ThreadTimelineReadingTarget?
    let readingVisitId: JSONText?
    let locatedRequestId: JSONText?
    let onLocated: (JSONText) -> Void
    let backLabel: String
    let focusHeading: Bool
    let onBack: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.threadAgentDetail) private var agentDetail
    @State private var users = false
    @State private var authors: [JSONText: JSONValue] = [:]
    @State private var manualWork: Bool?
    private var work: Bool { running || (manualWork ?? (result && active)) }
    @Environment(\.nativeReadingInteractionActive) private var readingActive
    @FocusState private var headingFocused: Bool
    var body: some View {
        HarnessMessageTimeline(timelineKey: page?.id ?? threadId,
            rows: page.map { [ThreadTimelineRow(id: $0.id, createdAt: $0.createdAt, node: rowContent ?? $0.node)] } ?? [],
            toolbar: AnyView(header), emptyState: AnyView(Text(localize("链接指向的执行不可用。")).nativeReadingContentReady()),
            contentTopInset: agentDetail ? 12 : nil,
            followOutput: result || (running && readingTarget?.follow == true), allowsJumpToLatest: allowsJumpToLatest,
            followKey: active ? page?.execution?.id : nil,
            readingTarget: readingTarget, readingVisitId: readingVisitId, locatedRequestId: locatedRequestId, onLocated: onLocated)
            .environment(\.threadDetailVisibility, ThreadDetailVisibility(userMessages: !agentDetail && users, work: work, messageAnchorID: readingTarget?.anchorId))
            .environment(\.threadAuthorInHeader, page?.execution != nil)
            .onPreferenceChange(ThreadAuthorPreference.self) { authors = $0 }
            .nativeReadingExitCommand(perform: readingActive ? onBack : nil).onAppear { if focusHeading { headingFocused = true } }
            .nativeReadingEscape(perform: readingActive ? onBack : nil)
            .nativeReadingAction("close", role: "history.close", label: backLabel, action: onBack)
            .nativeReadingObservation("state", role: "history", value: .object([
                "rowId": page.map { .string($0.id) } ?? .null,
                "userMessages": .bool(!agentDetail && users), "work": .bool(work)
            ]))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let page { Text(emoji(page.id)).font(.system(size: 44)).accessibilityHidden(true) }
            Text(historyTitle)
                .font(NativeTypography.inter(size: 40, weight: 650)).tracking(-0.8)
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(historyTitle)
                .foregroundStyle(NativePalette.thread.inkStrong.swiftUI).accessibilityAddTraits(.isHeader)
                .focusable().focusEffectDisabled().focused($headingFocused)
            if page != nil {
                ThreadReadingHeader(author: page?.execution.flatMap { authors[$0.id] }, showsAuthor: page?.execution != nil,
                    showsWorkFilter: !running, users: users, work: work, toggleUsers: { users.toggle() }, toggleWork: toggleWork)
                Divider().overlay(NativePalette.thread.lineSoft.swiftUI)
            }
        }.padding(.bottom, 28)
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
    private var historyTitle: String {
        guard let page else { return localize("历史执行不可用") }
        if !agentDetail { return page.execution?.prompt ?? localize("历史对话") }
        return page.execution == nil ? localize("历史对话") : page.executionTitle
    }
    private func toggleWork() { manualWork = !work }
    private func emoji(_ id: JSONText) -> String {
        let emojis = ["🌿", "🪐", "🧩", "🎨", "🦊", "🌊", "🍋", "🪁", "💡", "🌻", "🐳", "🏕️"]
        let hash = id.codeUnits.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return emojis[Int(hash % UInt32(emojis.count))]
    }
}

private struct NativeReadingInputCancellationKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Bool)? = nil
}

public extension EnvironmentValues {
    /// The resident composer may fold before a reading route handles Escape.
    /// Native editors, IME and transient controls still own cancellation first.
    var nativeReadingInputCancellation: (@MainActor () -> Bool)? {
        get { self[NativeReadingInputCancellationKey.self] }
        set { self[NativeReadingInputCancellationKey.self] = newValue }
    }
}

/// Result positioning can leave no SwiftUI focus target after scrolling. Only
/// the mounted active document owns this fallback; sibling focus and native
/// editing/menu cancellation must retain their existing handlers.
public extension View {
    /// Scope Escape to this native reading viewport while leaving editors,
    /// composition, menus and sibling surfaces with their own cancellation.
    /// WebKit documents use their trusted DOM key handler instead.
    func nativeReadingEscape(perform action: (() -> Void)?) -> some View {
        background(ThreadHistoryEscapeHandler(back: action))
    }

    /// Keep SwiftUI's focused-child cancellation order while sharing the
    /// resident input priority used by the native reading fallback.
    func nativeReadingExitCommand(perform action: (() -> Void)?) -> some View {
        modifier(NativeReadingExitCommand(action: action))
    }
}

private struct NativeReadingExitCommand: ViewModifier {
    let action: (() -> Void)?
    @Environment(\.nativeReadingInputCancellation) private var cancelInput
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.onExitCommand(perform: action.map { action in
            {
                guard enabled else { return }
                // This is a responder-scoped fallback after native/menu dispatch,
                // not another window-wide key monitor. Preserve other exit commands.
                if let event = NSApp.currentEvent, event.type == .keyDown,
                   event.keyCode != 53 || !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                    action(); return
                }
                guard let window = NSApp.currentEvent?.window ?? NSApp.keyWindow else { return }
                switch NativeReadingCancellation.owner(in: window) {
                case .native, .handled: return
                case .reading: if cancelInput?() != true { action() }
                }
            }
        })
    }
}

/// Both native monitoring and SwiftUI exit delivery cross the input boundary.
/// Editors and native transient controls must keep cancellation at either entry.
private enum NativeReadingCancellation {
    enum Owner { case native, handled, reading }
    @MainActor static func owner(in window: NSWindow) -> Owner {
        guard window.attachedSheet == nil, NSApp.modalWindow == nil,
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
              (window.firstResponder as? NSTextView)?.isEditable != true else { return .native }
        var responder = window.firstResponder
        while let current = responder, current !== window {
            // WebKit's trusted DOM handler owns its editors and HTML dialogs.
            if current is WKWebView { return .native }
            if (current as? NativeSettingsEscapeCancelling)?.cancelSettingsPresentation() == true { return .handled }
            responder = current.nextResponder
        }
        return (window.childWindows ?? []).contains { $0.isVisible } ? .native : .reading
    }
}

private struct ThreadHistoryEscapeHandler: NSViewRepresentable {
    let back: (() -> Void)?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReadingInputCancellation) private var cancelInput
    func makeNSView(context: Context) -> EscapeView { EscapeView(back: enabled ? back : nil) }
    func updateNSView(_ view: EscapeView, context: Context) {
        view.back = enabled ? back : nil
        view.cancelInput = cancelInput
    }
    static func dismantleNSView(_ view: EscapeView, coordinator: ()) { view.dispose() }

    @MainActor final class EscapeView: NSView {
        var back: (() -> Void)?
        var cancelInput: (@MainActor () -> Bool)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var menus = Set<ObjectIdentifier>()
        init(back: (() -> Void)?) {
            self.back = back
            super.init(frame: .zero)
            setAccessibilityElement(false)
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let menu = note.object as? NSMenu else { return }
                    let identity = ObjectIdentifier(menu), began = name == NSMenu.didBeginTrackingNotification
                    MainActor.assumeIsolated {
                        if began { self?.menus.insert(identity) }
                        else { self?.menus.remove(identity) }
                    }
                })
            }
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let back = self.back, let window = self.window,
                          event.window === window, !self.isHiddenOrHasHiddenAncestor, self.menus.isEmpty,
                          event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                    // Transient popovers can keep events addressed to an anchor
                    // in a sibling surface. Its explicit cancellation owner acts first.
                    switch NativeReadingCancellation.owner(in: window) {
                    case .native: return false
                    case .handled: return true
                    case .reading: break
                    }
                    if let responder = window.firstResponder as? NSView, responder !== window.contentView {
                        let point = responder.convert(CGPoint(x: responder.bounds.midX, y: responder.bounds.midY), to: nil)
                        guard self.bounds.contains(self.convert(point, from: nil)) else { return false }
                    }
                    // SwiftUI siblings share a hosting responder. Their focused
                    // AX element identifies which document owns cancellation.
                    if let focused = window.accessibilityFocusedUIElement as? any NSAccessibilityProtocol {
                        let frame = focused.accessibilityFrame()
                        if !frame.isEmpty, frame.width < window.frame.width || frame.height < window.frame.height {
                            let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
                            guard self.bounds.contains(self.convert(point, from: nil)) else { return false }
                        }
                    }
                    if self.cancelInput?() != true { back() }
                    return true
                }
                return handled ? nil : event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        func dispose() {
            back = nil; cancelInput = nil
            removeMonitor()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll(); menus.removeAll()
        }
    }
}
