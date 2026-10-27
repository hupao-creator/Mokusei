import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Only facts read by selection/ordering belong in this key. Content, progress
/// and revision changes still project fresh cards, without rebuilding every
/// directory and semantic filter. Array order matters for equal creation dates.
struct NativeOverviewMembershipFacts: Equatable {
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
    private let threads: [Thread]
    private let applications: [Application]
    private let locale: String

    init(threads: [HarnessThread], applications: [NativeOverviewApplicationEntry]) {
        self.threads = threads.map(Thread.init)
        self.applications = applications.map(Application.init)
        locale = Locale.current.identifier
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
