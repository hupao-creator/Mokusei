import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative)
struct NativeOverviewTagEmojiTests {
    private func thread(emoji: String = "🔧", name: String = "Backend") throws -> HarnessThread {
        try HarnessThread(id: "emoji-thread", harnessID: "fixture", revision: 1, sessionState: .object([:]),
            observation: .init(), cwd: "/workspace/Repo", settings: .object([:]),
            createdAt: 1, updatedAt: 2, title: "Thread title 🔥", tags: [JSONText(name)],
            tagEmojis: [JSONText(name): JSONText(emoji)])
    }

    @Test func wireRequiresCompleteDecoration() throws {
        for emoji in ["👩🏽‍💻", "👨‍👩‍👧‍👦", "🇨🇳", "1️⃣", "❤", "❤️", "🏳️‍🌈", "🏷️"] {
            let decoded = try thread(emoji: emoji)
            #expect(SemanticTagLabel.display(name: decoded.tags[0].string, emoji: emoji) == "\(emoji) Backend")
        }
        let current = try thread()
        for metadata in [nil, .null, .object([:]), .object(["Other": .text("🔧")]), .array([]),
                         .object(["Backend": .integer(1)]), .object(["Backend": .text("invalid")]),
                         .object(["Backend": .text("👩‍")]), .object(["Backend": .text("😀‍😀")])] as [JSONValue?] {
            var json = try #require(current.json.objectValue)
            json["tagEmojis"] = metadata
            #expect(throws: (any Error).self) { try HarnessThread(json: .object(json)) }
        }
        for name in ["🔥 Backend", "👩‍ Backend", "😀‍😀 Backend", "🇨🇳 Backend", "1️⃣ Backend"] {
            var prefixed = try #require(current.json.objectValue)
            prefixed["tags"] = .array([.text(name)])
            prefixed["tagEmojis"] = .object([JSONText(name): .text("🔥")])
            #expect(throws: (any Error).self) { try HarnessThread(json: .object(prefixed)) }
        }
        let empty = try HarnessThread(id: "empty", harnessID: "fixture", revision: 0, sessionState: .null,
            observation: .init(), cwd: "/workspace", settings: .object([:]), createdAt: 0, updatedAt: 0,
            title: "Untagged", tags: [])
        #expect(empty.json["tagEmojis"] == .object([:]))
    }

    @Test func applicationProjectionRequiresSemanticEmojiMap() throws {
        var tags: [JSONText: JSONValue] = ["tags": .array([.text("Backend"), .text("Repo")]),
            "semanticTags": .array([.text("Backend")]), "directoryTags": .array([.text("Repo")]),
            "tagEmojis": .object(["Backend": .text("👩🏽‍💻")])]
        func decode() throws -> ApplicationThreadCatalogEntry<JSONValue> {
            try .init(json: .object(["ref": ApplicationThreadRef(threadID: "report", typeID: "report").json,
                "revision": .integer(0), "createdAt": .integer(0), "updatedAt": .integer(0),
                "title": .text("Report"), "archived": .bool(false), "tags": .object(tags),
                "presentations": .array([]), "view": .object([:])]))
        }
        #expect(try decode().tags.tagEmojis == ["Backend": "👩🏽‍💻"])
        for metadata in [nil, .null, .object([:]), .object(["Backend": .text("👩‍")])] as [JSONValue?] {
            tags["tagEmojis"] = metadata
            #expect(throws: (any Error).self) { try decode() }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_CONVERSATION_CONTRACT_EXPORT"] != nil, "Requires the Go conversation contract export in MOKUSEI_CONVERSATION_CONTRACT_EXPORT"))
    func applicationConversationProducerMatchesStrictDecoder() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOKUSEI_CONVERSATION_CONTRACT_EXPORT"])
        let json = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let entries = try #require(json.arrayValue)
        #expect(entries.count == 2)
        for raw in entries {
            let entry = try ApplicationThreadCatalogEntry<JSONValue>(json: raw)
            let presentation = try #require(entry.presentations.first { $0.id == "mokusei.conversation" })
            let thread = try HarnessThread(json: #require(presentation.value["thread"]))
            #expect(thread.tags == entry.tags.semanticTags)
            #expect(thread.tagEmojis == entry.tags.tagEmojis)
        }
    }

    @Test func wireDecorationDoesNotChangeIdentitySearchOrMembership() throws {
        let first = try thread(emoji: "👩🏽‍💻")
        let decoded = try HarnessThread(json: first.json)
        #expect(decoded.tagEmojis["Backend"] == "👩🏽‍💻")
        #expect(decoded.title == "Thread title 🔥")
        let original = NativeOverviewCollection(threads: [decoded], applications: [])
        let directory = try #require(NativeOverviewSelection.filters(original).first)
        let filter = try #require(directory.children.first)
        #expect(directory.displayTag == "Repo")
        #expect(filter.tag == "Backend")
        #expect(filter.displayTag == "👩🏽‍💻 Backend")
        #expect(filter.matches("backend", kind: .semantic, scope: directory.scope))
        #expect(NativeOverviewSearch("backend").filter(original).threads.count == 1)
        #expect(NativeOverviewSelection.select(threads: original.threads, applications: [], tags: [filter.tag],
            kind: .semantic, scope: directory.scope).threads.count == 1)

        let changed = NativeOverviewCollection(threads: [try thread(emoji: "🇨🇳")], applications: [])
        let changedFilter = try #require(NativeOverviewSelection.filters(changed).first?.children.first)
        #expect(changedFilter.id == filter.id)
        #expect(changedFilter.selectionKey == filter.selectionKey)
        #expect(changedFilter.displayTag == "🇨🇳 Backend")
    }
}
