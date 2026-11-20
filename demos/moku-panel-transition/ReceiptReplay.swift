import Foundation
@testable import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ ok: Bool, _ message: String) throws {
    guard ok else { throw Failure(description: message) }
}

private struct NoLaunch: RuntimeConnectionSource {
    func start() async throws -> RuntimeConnection { throw Failure(description: "Unexpected Runtime launch") }
    func status() async throws -> RuntimeConnection? { nil }
    func stop(expectedEpoch: String?) async throws { throw Failure(description: "Unexpected stop") }
    func setOutputLocale(_ locale: String) throws {}
}

private extension RuntimeClient {
    // Only bootstrap is replaced. All command HTTP, journal transactions and
    // explicit receipt lookups use the production client and a private peer.
    func attach(to peer: RuntimeConnection) {
        connection = peer
        setStatus(.connected)
    }
}

@main private enum ReceiptReplay {
    @MainActor static func main() async throws {
        try prepareIsolatedNativeReplay()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if CommandLine.arguments.contains("--compete") {
            let store = RuntimeDraftStore(storageDirectory: root.appendingPathComponent("profile"), scope: "owners")
            do {
                _ = try store.acquireSubmissionLease()
                throw Failure(description: "Second process acquired the live send lease")
            } catch let error as RuntimeError where error.code == "DRAFT_SENDING" {}
            let held = try store.loadRetainingAttachments()
            try require(held.attachmentIDs.count == 2, "Collector-visible draft lost a staged file")
            func collect(_ mode: String) throws {
                let child = Process()
                child.executableURL = root.appendingPathComponent("attachment-replay")
                child.arguments = [mode]
                try child.run()
                child.waitUntilExit()
                try require(child.terminationStatus == 0, "Unexpected collector result for " + mode)
            }
            try RuntimeAttachmentLease.withExclusiveOwnership(in: root.appendingPathComponent("profile")) { try collect("busy") }
            try collect("collect")
            let files = try JSONValue(data: Data(contentsOf: root.appendingPathComponent("files.json"))).arrayValue!
            for (file, expected) in zip(files, ["first", "second"]) {
                try require(try Data(contentsOf: URL(fileURLWithPath: file["path"]!.stringValue!)) == Data(expected.utf8),
                    "Collector removed live attachment bytes")
            }
            try held.owner.release()
            print("Second process rejected by scope lock; both staged IDs retained")
            return
        }
        let peer = try JSONValue(data: Data(contentsOf: root.appendingPathComponent("peer.json")))
        let rootProfile = root.appendingPathComponent("profile")
        let client = RuntimeClient(storageDirectory: rootProfile, connectionSource: NoLaunch())
        let connection = RuntimeConnection(port: peer["port"]!.intValue!, token: peer["token"]!.stringValue!,
            epoch: peer["epoch"]!.stringValue!, protocolVersion: RuntimeProtocol.version, pid: 0, dataDir: rootProfile.path)
        await client.attach(to: connection)
        let workspace = NativeWorkspaceModel(client: client, preferences: DesktopPreferences(directory: rootProfile),
            plugins: try .init(harnesses: [], sidecards: [], applications: []))
        let thread = try HarnessThread(id: "T", harnessID: "codex", revision: 1, sessionState: .object([:]),
            observation: .init(latestExecution: try .init(executionID: "current", status: .running, startedAt: 1)), cwd: "/fixture", settings: .object([:]), createdAt: 1, updatedAt: 1, title: "fixture", tags: [])
        try workspace.catalog.install(.object(["revision": .integer(1), "settingsRevision": .integer(0),
            "defaultCwd": .text("/fixture"), "executions": .array([]), "settings": .object([:]), "threads": .array([thread.json]), "applicationThreads": .array([])]))
        let moku = NativeMokuSubmission(workspace: workspace)
        let continuation = NativeExecutionContinuation(workspace: workspace)
        func mode(_ value: String) throws { try Data(value.utf8).write(to: root.appendingPathComponent("mode"), options: .atomic) }
        if CommandLine.arguments.contains("--cleanup") {
            let route = CommandLine.arguments.last!
            let actions = route == "thread" ? continuation.receipts : moku.receipts
            let reopened = NativeComposerDraft(services: workspace.services.composer(receipts: actions),
                persistence: .init(storageDirectory: rootProfile, scope: .init(route + "-boundary")))
            try require(reopened.cleanupReceipt != nil && reopened.text == "successor", "Missing durable cleanup marker")
            await reopened.checkPendingReceipt()
            try require(reopened.cleanupReceipt == nil && reopened.text == "successor" && reopened.canSubmit,
                "Fresh client could not complete cleanup: " + (reopened.error ?? ""))
            print("Fresh process finished", route, "cleanup and retained successor")
            return
        }
        workspace.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !workspace.runtimeAvailable {
            try require(ContinuousClock.now < deadline, "Fixture workspace unavailable")
            try await Task.sleep(for: .milliseconds(5))
        }
        // The proxy forwards every lookup immediately. Recheck the real receipt
        // until the deliberately released Go handler has durably completed.
        func checkSettled(_ draft: NativeComposerDraft) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            repeat {
                await draft.checkPendingReceipt()
                if !draft.hasTrackedReceipt { return }
                try require(ContinuousClock.now < deadline, draft.error ?? "Receipt stayed pending")
                try await Task.sleep(for: .milliseconds(10))
            } while true
        }
        func composerRecords() async -> [RuntimeCommandOutcome] {
            await client.commandOutcomes().filter { ["thread:fork", "thread:follow-up", "moku:submit"].contains($0.channel) }
        }
        for route in ["thread", "moku"] {
            let actions = route == "thread" ? continuation.receipts : moku.receipts
            let persistence = NativeComposerDraftPersistence(storageDirectory: rootProfile, scope: .init(route))
            let services = workspace.services.composer(receipts: actions)
            let draft = NativeComposerDraft(services: services, persistence: persistence)
            func send(_ submission: NativeComposerSubmission) async throws {
                if route == "thread" {
                    _ = try await continuation.send(threadID: "T", executionID: nil, input: submission.input, commandID: submission.commandID)
                } else {
                    try await moku.send(input: submission.input, source: .object([:]), commandID: submission.commandID) { .object(["input": submission.input]) }
                }
            }
            var acknowledgements = 0
            func consume(_: NativeComposerSubmission) async { acknowledgements += 1 }
            try mode("lose")
            draft.inputText = "A"
            // Model a retained Chief send whose original wire payload used a
            // catalog mention. Receipt recovery must use its captured ID.
            let originalDirectory = NativeComposerDirectory(name: "Previous project", path: "/fixture/Previous project")
            if route == "moku" { try require(draft.insertDirectory(originalDirectory), "Could not seed old Chief directory") }
            await draft.submit({ submission in
                let stored = try RuntimeDraftStore(storageDirectory: rootProfile, scope: .init(route)).load()?["pendingSend"]
                try require(stored?["id"]?.stringValue == submission.commandID &&
                    stored?["receiptID"]?.stringValue == submission.commandID,
                    "Initial durable handoff did not carry the command that is about to be sent")
                draft.inputText = "B"
                try await send(submission)
            }, optimisticallyClear: true, didConsume: consume)
            let records = await composerRecords()
            try require(records.count == 1 && draft.hasTrackedReceipt && draft.interruptedInput?.text == "A" &&
                draft.text == "B" && acknowledgements == 0, "Lost " + route + " response lost the receipt association: " + String(describing: records) + " " + (draft.error ?? "no error"))
            let id = records[0].commandID
            let other = NativeComposerDraft(services: services, persistence: .init(storageDirectory: rootProfile, scope: .init(route + "-other")))
            other.inputText = "A"
            await other.submit(send, optimisticallyClear: true)
            try require(other.text == "A" && !other.hasInterruptedSend, "Foreign barrier claimed a different draft")
            // A fresh Host has no Operation in memory, but can still query the
            // same durable ID. Exercise both live and replacement routes.
            let coldActions = route == "thread" ? NativeExecutionContinuation(workspace: workspace).receipts
                : NativeMokuSubmission(workspace: workspace).receipts
            let reopened = NativeComposerDraft(services: workspace.services.composer(receipts: coldActions), persistence: persistence)
            await reopened.reviewInterruptedSend(restore: true)
            try require(reopened.hasTrackedReceipt && reopened.interruptedInput?.text == "A", "Local review erased tracked receipt")
            if route == "moku" {
                try require(reopened.interruptedInput?.directories == [originalDirectory], "Reopen changed the original Chief directory")
            }
            await reopened.checkPendingReceipt()
            try require(await composerRecords().map(\.commandID) == [id] && reopened.text == "B" && reopened.hasTrackedReceipt,
                "A pending lookup changed the send")
            await draft.checkPendingReceipt()
            try require(draft.hasTrackedReceipt && draft.text == "B", "Live Host lost the tracked receipt")
            try mode("accepted")
            try await checkSettled(reopened)
            try require(await composerRecords().isEmpty && !reopened.hasInterruptedSend && reopened.text == "B",
                "Accepted lookup did not consume the exact receipt")
            draft.inputText = "D"
            await draft.submit({ submission in
                let dir = rootProfile.appendingPathComponent("client-drafts")
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
                draft.inputText = "B"
                let failed = draft.error != nil
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                draft.inputText = "BC"
                try require(failed && draft.error == nil && (try persistence.loadText()?.textValue.string) == "BC",
                    "Transient write failure or recovery was not observed")
                try await send(submission)
            }, optimisticallyClear: true, didConsume: consume)
            try require(await composerRecords().isEmpty && acknowledgements == 1 && draft.text == "BC",
                "Successful consumption after write recovery left the receipt protected")
            await draft.submit(send, optimisticallyClear: true, didConsume: consume)
            try require(acknowledgements == 2 && draft.text.isEmpty, "Next explicit send stayed blocked")
            try mode("lose")
            draft.inputText = "rejected"
            await draft.submit({ submission in
                draft.inputText = "next"
                try await send(submission)
            }, optimisticallyClear: true, didConsume: consume)
            try require(draft.hasTrackedReceipt, "Missing receipt before definitive rejection")
            try mode("reject")
            try await checkSettled(draft)
            try require(await composerRecords().isEmpty && !draft.hasInterruptedSend &&
                draft.text == "rejected\n\nnext" && acknowledgements == 2, "Rejected receipt consumed or lost input")
            // Interrupt each side of the two-file boundary. chmod the actual
            // journal or draft directory only after the successor is durable.
            let dir = route == "thread" ? rootProfile : rootProfile.appendingPathComponent("client-drafts")
            let failing = NativeComposerReceiptActions(check: actions.check, consume: { id in
                if route == "moku" { try await actions.consume(id) }
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
                if route == "thread" { try await actions.consume(id) }
            })
            let boundary = NativeComposerDraft(services: workspace.services.composer(receipts: failing),
                persistence: .init(storageDirectory: rootProfile, scope: .init(route + "-boundary")))
            try mode("accepted")
            boundary.inputText = "boundary"
            await boundary.submit({ submission in
                boundary.inputText = "successor"
                try await send(submission)
            }, optimisticallyClear: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try require(boundary.cleanupReceipt != nil && boundary.error != nil, "Disk failure did not interrupt cleanup")
            let child = Process()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["--cleanup", route]
            try child.run()
            child.waitUntilExit()
            try require(child.terminationStatus == 0, "Reopened journal cleanup failed")
            await boundary.checkPendingReceipt()
            try require(boundary.cleanupReceipt == nil && boundary.text == "successor", "Stale owner did not refresh")
            // A direct server rejection also settles the draft before journal
            // cleanup. Make the first acknowledgement fail on this live client.
            var failOnce = true
            let rejectActions = NativeComposerReceiptActions(check: actions.check, consume: { id in
                if failOnce {
                    failOnce = false
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rootProfile.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootProfile.path) }
                    try await actions.consume(id)
                } else { try await actions.consume(id) }
            })
            let rejected = NativeComposerDraft(services: workspace.services.composer(receipts: rejectActions),
                persistence: .init(storageDirectory: rootProfile, scope: .init(route + "-rejection")))
            try mode("direct-reject")
            rejected.inputText = "direct"
            await rejected.submit({ submission in
                rejected.inputText = "next"
                try await send(submission)
            }, optimisticallyClear: true)
            try require(rejected.cleanupReceipt != nil && rejected.text == "direct\n\nnext",
                "Direct rejection lost recovery before acknowledgement")
            await rejected.checkPendingReceipt()
            try require(await composerRecords().isEmpty && rejected.cleanupReceipt == nil && rejected.canSubmit,
                "Same client could not release direct rejection after disk recovered")
            print(route, "queried original", id, "kept B; recovered disk write, consumed D, explicitly sent BC")
        }
        for lose in ["fork", "followup", "accepted-followup"] {
            let live = NativeExecutionContinuation(workspace: workspace)
            let storage = NativeComposerDraftPersistence(storageDirectory: rootProfile, scope: .init("history-" + lose))
            let original = NativeComposerDraft(services: workspace.services.composer(receipts: live.receipts), persistence: storage)
            try mode(lose == "fork" ? "lose-fork" : "lose-followup")
            original.inputText = "historical"
            await original.submit({ submission in
                original.inputText = "B"
                _ = try await live.send(threadID: "T", executionID: "historical", input: submission.input, commandID: submission.commandID)
            }, optimisticallyClear: true)
            try require(original.hasTrackedReceipt && original.text == "B", "Historical receipt detached from original")
            try mode(lose == "followup" ? "reject" : "accepted")
            let reopened = NativeComposerDraft(services: workspace.services.composer(
                receipts: NativeExecutionContinuation(workspace: workspace).receipts), persistence: storage)
            let inspecting = lose == "fork" ? original : reopened
            try await checkSettled(inspecting)
            if lose == "accepted-followup" {
                try require(inspecting.text == "B" && inspecting.canSubmit, "Accepted historical follow-up kept its barrier")
                original.inputText = "same-checkpoint"
                await original.submit({ submission in
                    _ = try await live.send(threadID: "T", executionID: "historical", input: submission.input, commandID: submission.commandID)
                }, optimisticallyClear: true)
                try require(original.text.isEmpty && original.cleanupReceipt == nil, "New checkpoint send did not settle")
                print("A new send from the same checkpoint created its own fork after late acceptance")
                continue
            }
            try require(inspecting.requiresForkReview && inspecting.interruptedInput?.text == "historical",
                "Missing explicit branch review: " + (inspecting.error ?? ""))
            let decision = NativeComposerDraft(services: workspace.services.composer(
                receipts: NativeExecutionContinuation(workspace: workspace).receipts), persistence: storage)
            await decision.reviewInterruptedSend(restore: lose == "fork")
            try require(decision.canSubmit && decision.text == (lose == "fork" ? "historical\n\nB" : "B"),
                "Fork review lost successor or retained barrier")
            try mode("accepted")
            decision.inputText = "after-" + lose
            await decision.submit({ submission in
                _ = try await live.send(threadID: "T", executionID: nil, input: submission.input, commandID: submission.commandID)
            }, optimisticallyClear: true)
            try require(decision.text.isEmpty && !decision.hasInterruptedSend && decision.cleanupReceipt == nil,
                "Fresh input stayed blocked after explicit fork review")
            print("Reviewed", lose, "without dispatch; released branch barrier on explicit local decision")
        }
        try mode("execution-changed")
        let changed = NativeComposerDraft(services: workspace.services.composer(receipts: continuation.receipts),
            persistence: .init(storageDirectory: rootProfile, scope: "changed"))
        changed.inputText = "changed"
        await changed.submit({ submission in
            _ = try await continuation.send(threadID: "T", executionID: "current", input: submission.input,
                commandID: submission.commandID)
        }, optimisticallyClear: true)
        try require(changed.text.isEmpty && changed.error == nil && changed.cleanupReceipt == nil,
            "EXECUTION_CHANGED fork handoff failed: " + (changed.error ?? ""))
        try await checkOwners(root: rootProfile)
    }

    @MainActor private static func checkOwners(root: URL) async throws {
        let fixture = root.deletingLastPathComponent().appendingPathComponent("files.json")
        let files = try JSONValue(data: Data(contentsOf: fixture)).arrayValue!.map { file in
            NativeComposerStoredAttachment(id: .init(file["id"]!.stringValue!), path: .init(file["path"]!.stringValue!),
                name: .init(file["name"]!.stringValue!), mimeType: .init(file["mimeType"]!.stringValue!),
                size: file["size"]!.intValue!, kind: .init(rawValue: file["kind"]!.stringValue!)!)
        }
        var selection = 0
        let services = NativeComposerServices(chooseFiles: { _, _, _ in
            [.init(url: URL(fileURLWithPath: files[selection].path.string))]
        }, stageFiles: { _, _ in
            defer { selection += 1 }
            return [files[selection]]
        }, discardAttachments: { _ in })
        let storage = NativeComposerDraftPersistence(storageDirectory: root, scope: "owners")
        let original = NativeComposerDraft(services: services, persistence: storage)
        original.inputText = "A"
        await original.chooseFiles(cwd: "/fixture")
        var winner: NativeComposerDraft?
        var callbacks = 0
        await original.submit({ _ in
            original.inputText = "B"
            let next = NativeComposerDraft(services: services, persistence: storage)
            winner = next
            next.inputText = "winner"
            await next.chooseFiles(cwd: "/fixture")
            original.inputText = "unsaved local edit"
            try require(original.error != nil, "Expected losing CAS")
            let child = Process()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["--compete"]
            try child.run()
            child.waitUntilExit()
            try require(child.terminationStatus == 0, "Cross-process lock/attachment check failed")
        }, optimisticallyClear: true, didConsume: { _ in callbacks += 1 })
        let stored = try RuntimeDraftStore(storageDirectory: root, scope: "owners").loadRetainingAttachments()
        try require(callbacks == 1 && stored.attachmentIDs == [files[1].id] && winner?.text == "winner"
            && winner?.hasInterruptedSend == false && original.text == "unsaved local edit" && original.error != nil,
            "Stale writer blocked consumption or overwrote the durable successor")
        try stored.owner.release()
        print("Stale editor kept its local edit; accepted send consumed once; successor owns only its own file")
    }
}
