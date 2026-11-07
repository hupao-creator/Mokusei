import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiHarnessClaude

@Suite @MainActor struct ClaudeThreadDetailMetaTests {
    private let tasks: [JSONValue] = [.object([
        "id": .text("task-1"), "description": .text("Run tests"), "status": .text("running")
    ])]

    @Test func agentDetailOmitsBackgroundTasks() {
        #expect(claudeSupplementalRows(tasks: tasks, agentDetail: true, updatedAt: 2).isEmpty)
    }

    @Test func fullReaderRetainsBackgroundTasks() {
        let rows = claudeSupplementalRows(tasks: tasks, agentDetail: false, updatedAt: 2)
        #expect(rows.map(\.id) == [JSONText("native-background-tasks")])
    }

    @Test func emptyTasksAddNoRow() {
        #expect(claudeSupplementalRows(tasks: [], agentDetail: false, updatedAt: 2).isEmpty)
    }
}
