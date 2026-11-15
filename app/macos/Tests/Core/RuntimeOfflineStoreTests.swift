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
            (.reading(key: "shared", target: .object(["messageId": .text("message")])), .text("reading turn")),
            (.execution(key: "shared"), .text("first execution")),
            (.turn(key: "other"), .text("second turn")),
            (.execution(key: "other"), .text("second execution")),
            (.directory(offset: 0, limit: 2), .text("first page"))
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

    @Test func oldContentNamespaceIsNotReused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = RuntimeContentScope.thread
        let oldKeys = [
            runtimeObject(["thread": .string("thread"), "scope": scope.json]),
            runtimeObject(["version": .integer(12), "thread": .string("thread"), "scope": scope.json])
        ]
        let document = runtimeObject(["version": .integer(1), "hostID": .text("local"), "value": .text("old read model")])
        for oldKey in oldKeys {
            let oldFile = directory.appendingPathComponent("client-reading-cache/content-" + RuntimePrivateFile.key(try oldKey.encodedData()) + ".json")
            try RuntimePrivateFile.write(try document.encodedData(), to: oldFile)
        }
        let cache = RuntimeOfflineStore(storageDirectory: directory, hostID: nil)
        #expect(cache.content(thread: "thread", scope: scope) == nil)
    }
}
