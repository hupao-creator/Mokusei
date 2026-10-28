import SwiftUI
import MokuseiCore
import MokuseiPluginAPI

public struct ThreadConversationExecution: Hashable, Sendable {
    public let id: JSONText
    public let prompt: String
    public let answer: String
    public let completedAt: Double?
    public let readable: Bool
    public init(id: JSONText, prompt: String, answer: String, completedAt: Double? = nil, readable: Bool = true) {
        self.id = id; self.prompt = prompt; self.answer = answer; self.completedAt = completedAt; self.readable = readable
    }
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
    public let position: HarnessReadingTarget.Position
    public init(requestId: JSONText, mode: Mode, executionId: JSONText, anchorId: JSONText? = nil, position: HarnessReadingTarget.Position = .start, follow: Bool = false) {
        self.requestId = requestId; self.mode = mode; self.executionId = executionId; self.anchorId = anchorId; self.position = position; self.follow = follow
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
    public let context: HarnessRenderContext?
    public let actions: AnyView?
    public let emptyState: AnyView?
    public let renderRow: ((JSONText) -> AnyView)?
    @Environment(\.locale) private var locale
    @Environment(\.threadDetailNavigation) private var navigation
    @State private var authors: [JSONText: JSONValue] = [:]
    @State private var sidebarFocusRevision = 0
    @State private var userMessages = false
    @State private var manualWork: Bool?
    @State private var destination: ConversationDestination = .document(inline: nil)
    @State private var consumedRequest: JSONText?
    @State private var requestedDestination: ConversationDestination?
    @State private var acceptedAnchor: JSONText?
    @State private var locatedRequest: JSONText?
    @State private var navigationRevision = 0
    @State private var pageMotion = NativeReadingPageMotion()
    @State private var navigationToken: UUID?

    public init(threadId: JSONText, title: String, icon: String? = nil, rows: [ThreadConversationRow],
                readingTarget: ThreadConversationReadingTarget? = nil, running: Bool = false,
                runningTurnId: JSONText? = nil, context: HarnessRenderContext? = nil,
                actions: AnyView? = nil, emptyState: AnyView? = nil, renderRow: ((JSONText) -> AnyView)? = nil) {
        self.threadId = threadId; self.title = title; self.icon = icon; self.rows = rows
        self.readingTarget = readingTarget; self.running = running; self.runningTurnId = runningTurnId
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
    private var work: Bool { executionCard || (manualWork ?? (effectiveRunningID != nil)) }
    private var visibility: ThreadDetailVisibility {
        ThreadDetailVisibility(userMessages: executionCard || userMessages, work: work,
                               workTurnID: executionCard || manualWork != nil ? nil : effectiveRunningID)
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
    private var scrollTarget: ThreadTimelineReadingTarget? {
        guard destination == requestedDestination, let consumedRequest, let acceptedAnchor else { return nil }
        return ThreadTimelineReadingTarget(requestId: consumedRequest, anchorId: acceptedAnchor,
            follow: readingTarget?.position == .result && readingTarget?.follow == true)
    }
    public var body: some View {
        Group {
            if case let .row(id) = context?.content {
                if let row = visibleRows.first(where: { $0.id == id }) { row.node }
                else if !rows.contains(where: { $0.id == id }) {
                    Text(localize("这轮对话已不可用。")).foregroundStyle(NativePalette.thread.danger.swiftUI)
                }
            } else {
                readingLayout.nativeReadingScope(interactionScope)
            }
        }
        .font(NativeTypography.inter(size: 16))
        .environment(\.nativeInteractionQuestionInDocument, true)
        .foregroundStyle(NativePalette.thread.ink.swiftUI)
        .background(NativePalette.thread.canvas.swiftUI)
        .onChange(of: threadId, initial: true) { _, _ in
            userMessages = false; manualWork = nil
            destination = .document(inline: nil); consumedRequest = nil; requestedDestination = nil; acceptedAnchor = nil; locatedRequest = nil
            consumeReadingTarget()
        }
        .onChange(of: effectiveRunningID) { _, _ in manualWork = nil }
        .onChange(of: readingTarget) { _, _ in consumeReadingTarget() }
        .onChange(of: visibleRows.map(\.id)) { _, _ in promoteCurrentPage(); consumeReadingTarget() }
        .onChange(of: visibleRows.map { $0.execution?.readable }) { _, _ in consumeReadingTarget() }
        .onChange(of: readingPage) { _, open in
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
                pageStack
            }
            .onKeyPress(.escape) {
                guard readingPage else { return .ignored }
                closeHistory()
                return .handled
            }
        }
    }
    private var pageStack: some View {
        GeometryReader { _ in
            NativeReadingPageStack(open: readingPage, identity: readingIdentity, motion: pageMotion,
                                   onClose: finishClosingHistory) {
                HarnessMessageTimeline(timelineKey: threadId, rows: documentRows,
                    toolbar: AnyView(documentHeader()), emptyState: effectiveEmptyState,
                    suspended: readingPage, followOutput: true, followKey: effectiveRunningID,
                    followPaused: inlineRow.map { historicalIDs.contains($0) } == true,
                    onJumpToLatest: {
                        destination = .document(inline: nil); requestedDestination = nil; acceptedAnchor = nil
                    }, showOlderRows: false, pinnedRowId: inlineRow,
                    readingTarget: readingPage ? nil : scrollTarget, locatedRequestId: locatedRequest,
                    onLocated: { locatedRequest = $0 })
                    .environment(\.threadDetailVisibility, visibility)
                    .environment(\.threadAuthorInHeader, true)
                    .onPreferenceChange(ThreadAuthorPreference.self) { authors = $0 }
                    .environment(\.nativeInteractionQuestionInDocument, true)
                    .allowsHitTesting(!readingPage).accessibilityHidden(readingPage)
                    .nativeReadingScope("current")
                    .nativeReadingActive(!readingPage && !pageMotion.active)
            } front: {
                if readingPage {
                    historyPage()
                        .background(NativePalette.thread.canvas.swiftUI)
                        .environment(\.nativeInteractionQuestionInDocument, true)
                }
            }
            .clipped()
        }.padding(.vertical, 12)
            .nativeReadingObservation("state", role: "conversation", value: .object([
                "destination": .text(readingPage ? selectedPage == nil ? "unavailable" : "history" : "current"),
                "historyRow": selectedPage.map { .string($0.id) } ?? .null,
                "selectedRow": selectedRowID.map(JSONValue.string) ?? .null,
                "userMessages": .bool(userMessages), "work": .bool(work),
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
            heading(title, emoji: icon ?? "📝")
            if let actions { actions.padding(.top, 15) }
            if !rows.isEmpty {
                let selected = selectedRowID
                let authorID = visibleRows.first { $0.id == selected }?.execution?.id
                ThreadReadingHeader(author: authorID.flatMap { authors[$0] }, showsAuthor: authorID != nil,
                    showsFilters: !executionCard, users: userMessages, work: work,
                    toggleUsers: { userMessages.toggle() }, toggleWork: { manualWork = !work })
                    .padding(.top, 12).padding(.bottom, 16)
            } else { Color.clear.frame(height: 16) }
        }
    }
    private func heading(_ title: String, emoji: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(emoji).font(.system(size: 44)).accessibilityHidden(true)
            Text(title).font(NativeTypography.inter(size: 40, weight: 650))
                .tracking(-0.8).lineLimit(2).truncationMode(.tail)
                .foregroundStyle(NativePalette.thread.inkStrong.swiftUI)
                .frame(maxWidth: .infinity, alignment: .leading).help(title)
                .accessibilityAddTraits(.isHeader)
        }
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
        if case .manifest = context?.content, let renderRow { return renderRow(row.id) }
        return row.node
    }
    private func historyPage() -> some View {
        ThreadHistoryDocument(threadId: threadId, page: selectedPage, rowContent: selectedPage.map(content),
                              active: resultVisit ? readingTarget?.follow == true : selectedPage?.execution?.id == effectiveRunningID,
                              result: resultVisit, readingTarget: scrollTarget, locatedRequestId: locatedRequest, onLocated: { locatedRequest = $0 },
                              showBack: navigation == nil, focusHeading: destination == requestedDestination, onBack: closeHistory)
        .id(HistoryVisitID(row: selectedPage?.id, request: consumedRequest, revision: navigationRevision))
        .nativeReadingScope("history")
        .nativeReadingActive(!pageMotion.active)
    }
    private var effectiveEmptyState: AnyView {
        if let emptyState { return emptyState }
        if executionCard { return AnyView(Text(localize("正在读取") + "…").foregroundStyle(NativePalette.thread.muted.swiftUI).padding(.vertical, 16)) }
        return AnyView(ThreadDetailEmptyState())
    }
    private func closeHistory() {
        pageMotion.close()
    }
    private func finishClosingHistory() {
        destination = .document(inline: nil); requestedDestination = nil; acceptedAnchor = nil
        navigationRevision += 1; sidebarFocusRevision += 1
    }
    private func selectRow(_ id: JSONText) {
        guard visibleRows.contains(where: { $0.id == id }) else { return }
        // Re-selecting a settled history page must not retire its live resource.
        // During Back or an external result visit, selection still changes ownership.
        if case let .history(selected) = destination, selected == id, !pageMotion.active, !resultVisit { return }
        // Invalidate an interrupted Back animation before selecting another
        // turn; its delayed completion must not replace the new destination.
        pageMotion.cancel()
        requestedDestination = nil; acceptedAnchor = nil
        if id == currentRow?.id {
            destination = .document(inline: nil)
        } else {
            destination = .history(id)
        }
        navigationRevision += 1
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
        .padding(.top, 48).padding(.bottom, 60)
        .accessibilityLabel(NativePluginLocalization.localize("一只小猫坐在电脑后面，等待新的想法。", locale: locale))
    }
}

private struct ThreadHistoryDocument: View {
    let threadId: JSONText
    let page: ThreadConversationRow?
    let rowContent: AnyView?
    let active: Bool
    let result: Bool
    let readingTarget: ThreadTimelineReadingTarget?
    let locatedRequestId: JSONText?
    let onLocated: (JSONText) -> Void
    let showBack: Bool
    let focusHeading: Bool
    let onBack: () -> Void
    @Environment(\.locale) private var locale
    @State private var users = false
    @State private var authors: [JSONText: JSONValue] = [:]
    @State private var manualWork: Bool?
    private var work: Bool { manualWork ?? (result && active) }
    @FocusState private var headingFocused: Bool
    var body: some View {
        HarnessMessageTimeline(timelineKey: page?.id ?? threadId,
            rows: page.map { [ThreadTimelineRow(id: $0.id, createdAt: $0.createdAt, node: rowContent ?? $0.node)] } ?? [],
            toolbar: AnyView(header), emptyState: AnyView(Text(localize("链接指向的执行不可用。"))),
            followOutput: result, followKey: active ? page?.execution?.id : nil,
            readingTarget: readingTarget, locatedRequestId: locatedRequestId, onLocated: onLocated)
            .environment(\.threadDetailVisibility, ThreadDetailVisibility(userMessages: users, work: work))
            .environment(\.threadAuthorInHeader, page?.execution != nil)
            .onPreferenceChange(ThreadAuthorPreference.self) { authors = $0 }
            .overlay(alignment: .topLeading) {
                if showBack { Button(action: onBack) { NativeIcon(name: "ArrowLeft", size: 17).frame(width: 32, height: 30) }
                    .buttonStyle(.plain).background(NativePalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(NativePalette.thread.line.swiftUI))
                    .padding(16).help(localize("返回当前会话")).accessibilityLabel(localize("返回当前会话"))
                }
            }.nativeOnExitCommand(perform: onBack).onAppear { if focusHeading { headingFocused = true } }
            .nativeReadingAction("close", role: "history.close", label: localize("返回当前会话"), action: onBack)
            .nativeReadingObservation("state", role: "history", value: .object([
                "rowId": page.map { .string($0.id) } ?? .null,
                "userMessages": .bool(users), "work": .bool(work)
            ]))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let page { Text(emoji(page.id)).font(.system(size: 44)).accessibilityHidden(true) }
            Text(page.map { $0.execution?.prompt ?? localize("历史对话") } ?? localize("历史执行不可用"))
                .font(NativeTypography.inter(size: 40, weight: 650)).tracking(-0.8)
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(page?.execution?.prompt ?? localize("历史执行不可用"))
                .foregroundStyle(NativePalette.thread.inkStrong.swiftUI).accessibilityAddTraits(.isHeader)
                .focusable().focusEffectDisabled().focused($headingFocused)
            if page != nil {
                ThreadReadingHeader(author: page?.execution.flatMap { authors[$0.id] }, showsAuthor: page?.execution != nil,
                    users: users, work: work, toggleUsers: toggleUsers, toggleWork: toggleWork)
                Divider().overlay(NativePalette.thread.lineSoft.swiftUI)
            }
        }.padding(.bottom, 28)
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
    private func toggleUsers() { users.toggle() }
    private func toggleWork() { manualWork = !work }
    private func emoji(_ id: JSONText) -> String {
        let emojis = ["🌿", "🪐", "🧩", "🎨", "🦊", "🌊", "🍋", "🪁", "💡", "🌻", "🐳", "🏕️"]
        let hash = id.codeUnits.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return emojis[Int(hash % UInt32(emojis.count))]
    }
}
