import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Only facts read by selection/ordering belong in this key. Content, progress
/// and revision changes still project fresh cards, without rebuilding every
/// directory and semantic filter. Array order matters for equal creation dates.
final class NativeOverviewMembershipFacts: Equatable {
    private struct Thread: Equatable {
        let id: JSONText
        let createdAt: Double
        let cwd: JSONText
        let directoryScope: JSONText
        let directoryTag: JSONText
        let tags: [JSONText]
        let emojis: [JSONText: JSONText]
        let visible: Bool
        let executionID: JSONText?

        init(_ thread: HarnessThread) {
            id = thread.id; createdAt = thread.createdAt; cwd = thread.cwd
            directoryScope = thread.directoryScope; directoryTag = thread.directoryTag
            tags = thread.tags; emojis = thread.tagEmojis
            visible = !thread.isHiddenFromUser && thread.archived != true
            executionID = thread.observation.latestExecution?.executionID
        }
    }
    private struct Application: Equatable {
        let ref: ApplicationThreadRef
        let createdAt: Double
        let scope: JSONText?
        let tags: ApplicationTagProjection
        let visible: Bool
        let directoryOnly: Bool
        let coveredExecutions: [ApplicationExecutionRef]

        init(_ item: NativeOverviewApplicationEntry) {
            ref = item.entry.ref; createdAt = item.entry.createdAt; scope = item.entry.scope
            tags = item.entry.tags; visible = !item.entry.archived && item.visible
            directoryOnly = item.directoryOnly; coveredExecutions = item.coveredExecutions
        }
    }
    private var threads: [JSONText: Thread]
    private var applications: [ApplicationThreadRef: Application]
    private var threadOrder: [JSONText]?
    private var applicationOrder: [ApplicationThreadRef]?
    private let locale: String

    init(threads: [HarnessThread], applications: [NativeOverviewApplicationEntry]) {
        self.threads = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, Thread($0)) })
        self.applications = Dictionary(uniqueKeysWithValues: applications.map { ($0.entry.ref, Application($0)) })
        threadOrder = threads.map(\.id)
        applicationOrder = applications.map(\.entry.ref)
        locale = Locale.current.identifier
    }

    static func == (lhs: NativeOverviewMembershipFacts, rhs: NativeOverviewMembershipFacts) -> Bool {
        lhs.threads == rhs.threads && lhs.applications == rhs.applications && lhs.locale == rhs.locale
            && lhs.threadOrder == rhs.threadOrder && lhs.applicationOrder == rhs.applicationOrder
    }
    func update(_ thread: HarnessThread?, id: JSONText) {
        let next = thread.flatMap { $0.moku == true ? nil : Thread($0) }
        if (threads[id] == nil) != (next == nil) { threadOrder = nil }
        threads[id] = next
    }
    func update(_ item: NativeOverviewApplicationEntry?, previous: ApplicationThreadRef?) {
        if let previous, previous != item?.entry.ref { applications.removeValue(forKey: previous); applicationOrder = nil }
        if let item {
            if applications[item.entry.ref] == nil { applicationOrder = nil }
            applications[item.entry.ref] = Application(item)
        }
    }

    var localeIsCurrent: Bool { locale == Locale.current.identifier }
    func matches(_ thread: HarnessThread?, id: JSONText) -> Bool {
        threads[id] == thread.flatMap { $0.moku == true ? nil : Thread($0) }
    }
    func matches(_ application: NativeOverviewApplicationEntry?, ref: ApplicationThreadRef) -> Bool {
        applications[ref] == application.map(Application.init)
    }
}

/// Workspace-owned identity lists, bounded by the current catalog and its
/// exposed filters. Resolve against the latest admitted records on every use;
/// retaining whole threads here would freeze streaming content on a cache hit.
struct NativeOverviewMembership {
    let threads: [JSONText]
    let applications: [ApplicationThreadRef]

    init(_ collection: NativeOverviewCollection = .init(threads: [], applications: [])) {
        threads = collection.threads.map(\.id)
        applications = collection.applications.map(\.entry.ref)
    }
}
