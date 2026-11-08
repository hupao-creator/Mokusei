import Foundation
import Testing
@testable import MokuseiCore

struct RuntimeOfflineStoreTests {
    @Test func contentScopesRemainIsolatedAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Equal keys in different scope kinds must not share a persisted entry.
        let entries: [(scope: RuntimeContentScope, value: JSONValue)] = [
            (.thread, .text("whole history")),
            (.turn(key: "shared"), .text("first turn")),
            (.execution(key: "shared"), .text("first execution")),
            (.turn(key: "other"), .text("second turn")),
            (.execution(key: "other"), .text("second execution"))
        ]
        do {
            let cache = RuntimeOfflineStore(storageDirectory: directory, hostID: nil)
            for entry in entries {
                try cache.saveContent(entry.value, thread: "thread", scope: entry.scope)
            }
        }

        let reopened = RuntimeOfflineStore(storageDirectory: directory, hostID: nil)
        for entry in entries {
            #expect(reopened.content(thread: "thread", scope: entry.scope) == entry.value)
        }
        #expect(reopened.content(thread: "thread", scope: .execution(key: "missing")) == nil)
    }
}
