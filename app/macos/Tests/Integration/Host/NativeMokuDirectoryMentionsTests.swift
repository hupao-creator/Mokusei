import Foundation
import MokuseiCore
import MokuseiPluginUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeMokuDirectoryMentionsTests {
    private func update(_ mentions: NativeMokuDirectoryMentions, _ text: String, composing: Bool = false) {
        mentions.update(.init(text: text, selection: NSRange(location: text.utf16.count, length: 0), focused: true, composing: composing))
    }

    @Test func rankingStaysCorrectAcrossQueryChangesReloadAndKeyboardSelection() async throws {
        let mentions = NativeMokuDirectoryMentions()
        let names = ["xxalpha", "AlphaBeta", "alpha", "a-l-p-h-a", "alpha"]
        let catalog = names.enumerated().map { NativeComposerDirectory(name: JSONText($0.element), path: JSONText("/work/\($0.offset)")) }
        await mentions.load(enabled: true, using: { catalog + [catalog[0]] })
        update(mentions, "😀 @AlPhA")
        #expect(mentions.matches.map(\.path) == [catalog[2], catalog[4], catalog[1], catalog[0], catalog[3]].map(\.path))
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        #expect(mentions.handle(.init(key: .down), draft: draft))
        #expect(mentions.index == 1)
        update(mentions, "😀 @alpha") // Same normalized search, new replacement range/key.
        #expect(mentions.index == 0)
        update(mentions, "@/work/1")
        #expect(mentions.matches == [catalog[1]])
        update(mentions, "@missing")
        #expect(mentions.matches.isEmpty)
        update(mentions, "@alpha")
        let replacement = NativeComposerDirectory(name: "alpha", path: "/new/alpha")
        await mentions.load(enabled: true, using: { [replacement] })
        #expect(mentions.matches == [replacement])
        update(mentions, "@")
        #expect(mentions.matches == [replacement])
        let composed = NativeComposerDirectory(name: "éclair", path: "/composed")
        let decomposed = NativeComposerDirectory(name: "e\u{301}clair", path: "/decomposed")
        await mentions.load(enabled: true, using: { [composed, decomposed] })
        update(mentions, "@é")
        #expect(mentions.matches == [composed])
        update(mentions, "@e\u{301}")
        #expect(mentions.matches == [decomposed])
    }

    @Test func composingNeverSelectsAndCompletionPreservesAttachments() async throws {
        let mentions = NativeMokuDirectoryMentions()
        let directory = NativeComposerDirectory(name: "中文😀", path: "/work/中文😀")
        await mentions.load(enabled: true, using: { [directory] })
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            [.init(id: "file", path: "/tmp/file", name: "file", mimeType: "text/plain", size: 1, kind: .file)]
        }, discardAttachments: { _ in }))
        await draft.importFiles([.init(data: Data([1]), name: "file", mimeType: "text/plain")])
        draft.text = "你好 @中😀"
        update(mentions, draft.text, composing: true)
        #expect(!mentions.isOpen)
        #expect(!mentions.handle(.init(key: .enter), draft: draft))
        #expect(draft.directories.isEmpty)
        update(mentions, draft.text)
        #expect(mentions.matches == [directory])
        #expect(mentions.handle(.init(key: .enter), draft: draft))
        #expect(draft.text == "你好 ")
        #expect(draft.directories == [directory])
        #expect(draft.attachments.first?.attachment?.id == "file")
        #expect(mentions.selectionRequest?.range == NSRange(location: 3, length: 0))
    }

    @Test func repeatedRenderAndNavigationPreserveResults() async throws {
        let mentions = NativeMokuDirectoryMentions()
        let catalog = (0..<2_000).map { NativeComposerDirectory(name: JSONText("Workspace-\($0)"), path: JSONText("/work/Workspace-\($0)")) }
        await mentions.load(enabled: true, using: { catalog })
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        var checksum = 0
        for query in ["@w", "@wo", "@wor", "@work", "@workspace", "@workspace-1"] {
            update(mentions, query)
            // Model the actual menu: options, each row's active index, footer,
            // scroll target, followed by keyboard navigation and another render.
            for _ in 0..<3 {
                checksum += mentions.matches.count
                for _ in 0..<50 { checksum += mentions.index }
                #expect(mentions.hasMore)
                #expect(mentions.handle(.init(key: .down), draft: draft))
            }
        }
        #expect(checksum == 1_800)
    }
}
