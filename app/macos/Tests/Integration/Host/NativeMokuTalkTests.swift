import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor @Suite(.serializedNative)
struct NativeMokuTalkTests {
    private func operation(_ id: JSONText, _ text: JSONText, execution: JSONText = "first",
                           completed: Bool = true, error: Bool = false) -> JSONValue {
        var values: [JSONText: JSONValue] = ["type": .text("tool-operation"), "id": .string(id),
            "executionId": .string(execution), "name": .text("talk"),
            "arguments": .object(["text": .string(text)]), "result": .object(["ok": .bool(!error)])]
        if completed { values["completedAt"] = .number(2) }
        if error { values["isError"] = .bool(true) }
        return .object(values)
    }
    private func thread(_ transcript: [JSONValue], execution: JSONText = "first") throws -> HarnessThread {
        try HarnessThread(id: "moku", harnessID: "fixture", revision: 0, sessionState: .object([:]),
            observation: .init(latestExecution: try .init(executionID: execution, status: .running, startedAt: 1)),
            cwd: "/tmp", settings: .object([:]), createdAt: 1, updatedAt: 2, title: "Moku", tags: [],
            moku: true, transcript: .array(transcript))
    }

    @Test func onlyCurrentSuccessfulCompletedTalkIsProjectedWithoutTrimming() throws {
        let exact: JSONText = "  第二条\n完整内容  "
        let record = try thread([
            operation("first", "旧消息"), operation("latest", exact),
            operation("pending", "未完成", completed: false), operation("failed", "失败", error: true),
            operation("blank", "\u{FEFF}\u{3000}\n"),
            operation("oversized", JSONText(String(repeating: "😀", count: NativeMokuTalkMessage.maximumCodePoints + 1))),
            operation("wrong-execution", "其他执行", execution: "other")
        ])
        let message = try #require(NativeMokuTalkMessage.latest(in: record))
        #expect(message.text == exact.string)
        #expect(NativeMokuTalkMessage.latest(in: try thread(record.transcript!.arrayValue!, execution: "new")) == nil)
        let sameTextNewExecution = try thread([operation("latest", exact, execution: "new")], execution: "new")
        #expect(NativeMokuTalkMessage.latest(in: sameTextNewExecution)?.id != message.id)
    }

    @Test func codePointBudgetMatchesSchemaIncludingEmojiAndCombiningMarks() throws {
        for text in [String(repeating: "界", count: 160), String(repeating: "😀", count: 160),
                     String(repeating: "e\u{0301}", count: 80), "  exact\r\ntext\t "] {
            let record = try thread([operation("boundary", JSONText(text))])
            #expect(NativeMokuTalkMessage.latest(in: record)?.text == text)
        }
        for text in [String(repeating: "界", count: 161), String(repeating: "😀", count: 161),
                     String(repeating: "e\u{0301}", count: 81)] {
            let record = try thread([operation("ok", "keep"), operation("over", JSONText(text))])
            #expect(NativeMokuTalkMessage.latest(in: record)?.text == "keep")
        }
    }

    @Test func unicodeNextLineWhitespaceCannotReplaceSuccessfulTalk() throws {
        for blank in ["\u{0085}", "\u{0085} \r\n\u{FEFF}"] {
            let record = try thread([operation("ok", "keep previous"), operation("blank", JSONText(blank))])
            #expect(NativeMokuTalkMessage.latest(in: record)?.text == "keep previous")
        }
        let exact = "\u{0085}visible\u{0085}"
        #expect(NativeMokuTalkMessage.latest(in: try thread([operation("visible", JSONText(exact))]))?.text == exact)
    }

    @Test func budgetIsNotALineGuaranteeAndOverflowRemainsScrollable() {
        // All inputs meet the tool budget. Explicit newlines and narrow widths
        // can still exceed four lines; the full native document must survive.
        for text in [String(repeating: "界", count: 160), String(repeating: "W", count: 160),
                     "one\ntwo\nthree\nfour\nfive\nsix"] {
            let width: CGFloat = 180
            #expect(NativeMokuTalkTypography.height(text, width: width) > NativeMokuTalkTypography.maximumHeight)
            #expect(NativeMokuTalkTypography.capsuleHeight(text, width: width + 84)
                == NativeMokuTalkTypography.maximumHeight + 38)
            let host = NSHostingView(rootView: NativeMokuTalkContent(message: .init(id: "overflow", text: text))
                .frame(width: width, height: NativeMokuTalkTypography.maximumHeight))
            host.layoutSubtreeIfNeeded()
            #expect(SwiftUIReplay.text(in: host).contains(text))
        }
    }

    @Test func dismissalDeferredDeliveryAndRefreshDoNotReplayOldMessages() {
        let a = NativeMokuTalkMessage(id: "a", text: "same text")
        let b = NativeMokuTalkMessage(id: "b", text: "same text")
        var state = NativeMokuTalkState()
        state.receive(a); state.setPresented(true); state.setPresented(false)
        state.receive(a)
        #expect(state.message == nil)
        state.receive(b)
        #expect(state.message == b && !state.presented)
        state.setPresented(false) // hidden/input owns the Dock: keep unseen delivery
        #expect(state.message == b)
        state.setPresented(true); state.dismiss(); state.receive(nil); state.receive(a)
        #expect(state.message == nil)
        state.receive(b)
        #expect(state.message == nil)
    }

    @Test func incomingWhileEditingDoesNotChangeInputOwnership() {
        let state = NativeMokuSceneState()
        state.receiveTalk(.init(id: "a", text: "before input")); state.setTalkPresented(true)
        state.setInputOpen(true)
        #expect(state.talkPresentation.message == nil)
        state.receiveTalk(.init(id: "b", text: "during input"))
        #expect(state.inputOpen && state.talkPresentation.message?.id == "b")
        state.setInputOpen(false)
        #expect(state.talkPresentation.message?.id == "b")
    }

    @Test func timeoutStartsAtPresentationAndUpdatesCannotExtendIt() throws {
        let start = ContinuousClock.now
        let a = NativeMokuTalkMessage(id: "a", text: "pending")
        var state = NativeMokuTalkState()
        state.receive(a)
        state.setPresented(false)
        #expect(state.deadline == nil)
        state.setPresented(true, now: start)
        let deadline = try #require(state.deadline)
        #expect(deadline == start.advanced(by: .seconds(60)))
        state.receive(a)
        let updated = NativeMokuTalkMessage(id: "a", text: "settled")
        state.receive(updated)
        state.setPresented(true, now: start.advanced(by: .seconds(59)))
        #expect(state.deadline == deadline && state.message == updated)
        state.expire(id: a.id, deadline: deadline, now: deadline.advanced(by: .milliseconds(-1)))
        #expect(state.message == updated)
        state.expire(id: a.id, deadline: deadline, now: deadline)
        #expect(state.message == nil && !state.presented && state.deadline == nil)
        state.receive(nil); state.receive(updated); state.setPresented(true)
        #expect(state.message == nil && state.deadline == nil)
    }

    @Test func replacedAndClearedTimersCannotConsumeANewerDelivery() throws {
        let start = ContinuousClock.now
        var state = NativeMokuTalkState()
        state.receive(.init(id: "a", text: "same text"))
        state.setPresented(true, now: start)
        let oldDeadline = try #require(state.deadline)
        state.receive(.init(id: "b", text: "same text"))
        #expect(state.deadline == nil && !state.presented)
        state.setPresented(true, now: start.advanced(by: .seconds(59)))
        let newDeadline = try #require(state.deadline)
        #expect(newDeadline == start.advanced(by: .seconds(119)))
        state.expire(id: "a", deadline: oldDeadline, now: oldDeadline)
        #expect(state.message?.id == "b" && state.deadline == newDeadline)
        state.receive(nil)
        #expect(state.deadline == nil)
        state.receive(.init(id: "c", text: "after clear"))
        state.expire(id: "b", deadline: newDeadline, now: newDeadline)
        #expect(state.message?.id == "c" && state.deadline == nil)
    }

    @Test func leavingOverviewConsumesLeaseAndReturnCannotResurrectIt() {
        let scene = NativeMokuSceneState()
        let message = NativeMokuTalkMessage(id: "shown", text: "shown")
        scene.receiveTalk(message); scene.setTalkPresented(true)
        #expect(scene.talkPresentation.deadline != nil)
        scene.overviewVisible = false
        #expect(scene.talkPresentation.message == nil && scene.talkPresentation.deadline == nil)
        scene.overviewVisible = true
        scene.receiveTalk(message); scene.setTalkPresented(true)
        #expect(scene.talkPresentation.message == nil)
        scene.receiveTalk(.init(id: "new", text: "new")); scene.setTalkPresented(true)
        #expect(scene.talkPresentation.deadline != nil)
    }

    @Test func voiceComposerRestoresOnlyAnInputThatWasAlreadyOpen() {
        var restoration = NativeMokuVoiceComposerRestoration()
        #expect(restoration.update(active: false, inputOpen: false) == nil)
        #expect(restoration.update(active: true, inputOpen: false) == nil)
        #expect(restoration.update(active: true, inputOpen: false) == nil)
        #expect(restoration.update(active: false, inputOpen: false) == nil)

        #expect(restoration.update(active: true, inputOpen: true) == false)
        #expect(restoration.shouldRestore)
        #expect(restoration.update(active: true, inputOpen: false) == nil)
        #expect(restoration.update(active: false, inputOpen: false) == true)
        #expect(!restoration.shouldRestore)
    }

    @Test func hiddenSceneConsumesPresentedButKeepsUnseenLatest() {
        let state = NativeMokuSceneState()
        state.receiveTalk(.init(id: "shown", text: "shown")); state.setTalkPresented(true)
        state.setSearchActive(true)
        #expect(state.talkPresentation.message == nil)
        state.receiveTalk(.init(id: "pending", text: "new while hidden"))
        state.setWindowVisible(false)
        #expect(state.talkPresentation.message?.id == "pending")
        state.setSearchActive(false); state.setWindowVisible(true)
        #expect(state.talkPresentation.message?.id == "pending")
    }

    @Test func fourLineViewportUsesActualTextKitMetrics() {
        let line = NativeMokuTalkTypography.lineHeight
        #expect(NativeMokuTalkTypography.height("一行", width: 476) == line)
        #expect(NativeMokuTalkTypography.height("一行\n二行", width: 476) == line * 2 + 3)
        #expect(NativeMokuTalkTypography.height("一\n二\n三\n四", width: 476) == NativeMokuTalkTypography.maximumHeight)
        #expect(NativeMokuTalkTypography.capsuleHeight(String(repeating: "完整内容\n", count: 50), width: 560)
            == NativeMokuTalkTypography.maximumHeight + 38)
    }
}
