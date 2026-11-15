import AppKit
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
import SwiftUI
import Testing

@MainActor
@Suite(.serializedNative, .serialized)
struct NativeHarnessDetailResourceTests {
    @Test func deferredCodexPathPreservesTurnIdentityAndReadsBody() async throws {
        let directory = Self.directory(execution: "turn:codex-exec", item: "row", text: "hello detail")
        var detailScopes: [HarnessDetailSelection] = []
        var bodyScopes: [HarnessDetailBodyReference] = []
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                switch scope {
                case .detail(let selection):
                    detailScopes.append(selection)
                    return HarnessContentResource(state: .ready(directory), retry: {}, release: {})
                case .body(let reference):
                    bodyScopes.append(reference)
                    return HarnessContentResource(state: .ready(Self.chunk(reference: reference)), retry: {}, release: {})
                default:
                    return HarnessContentResource(state: .ready(.null), retry: {}, release: {})
                }
            },
            onIndexChange: { _ in })
        let row = ThreadDetailRow(id: "row", kind: .work, node: AnyView(Text("row")), execution: .member)
        let deferred = JSONValue.object([
            "kind": .text("deferred-execution"),
            "state": .object([:]),
            "nonempty": .array([])
        ])
        let root = ThreadDeferredExecutionContent(raw: deferred, rowKey: "turn:codex-exec", context: context) { _ in
            ThreadExecutionProcess(groupID: "group", rows: [row])
        }
        .environment(\.threadAgentDetail, false)

        let host = NSHostingView(rootView: root.frame(width: 420, height: 240))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if !bodyScopes.isEmpty, SwiftUIReplay.text(in: host).contains("hello detail") { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(detailScopes.first?.execution.string == "turn:codex-exec")
        #expect(detailScopes.first?.items.map(\.string) == ["row"])
        #expect(bodyScopes.first?.execution.string == "turn:codex-exec")
        #expect(bodyScopes.first?.item.string == "row")
        #expect(bodyScopes.first?.slot.string == "detail")
        #expect(SwiftUIReplay.text(in: host).contains("hello detail"))
    }

    @Test func bodyLeasesStayBoundedBeyondClientCapacity() async throws {
        let gate = HarnessDetailBodyGate()
        var resources: [HarnessContentResource] = []
        var payloads: [ObjectIdentifier: JSONValue] = [:]
        var published = Set<ObjectIdentifier>()
        var live = 0
        var maximumLive = 0
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                guard case .body(let reference) = scope else {
                    return HarnessContentResource(state: .ready(.null), retry: {}, release: {})
                }
                live += 1
                maximumLive = max(maximumLive, live)
                let resource = HarnessContentResource(state: .loading, retry: {}, release: { live -= 1 })
                resources.append(resource)
                payloads[ObjectIdentifier(resource)] = Self.chunk(reference: reference, text: "x")
                return resource
            },
            onIndexChange: { _ in })
        let body = JSONValue.object(["slot": .text("detail"), "format": .text("text"), "length": .integer(1)])
        let root = VStack {
            ForEach(0..<40, id: \.self) { index in
                HarnessDetailBodyView(execution: "execution", contentID: "content",
                                      item: JSONText("row-\(index)"), bodyData: body,
                                      slot: "detail", context: context, gate: gate)
            }
        }
        let host = NSHostingView(rootView: root.frame(width: 420, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resources.count <= 4, "body leases exceeded the gate before pages completed")

        let deadline = Date().addingTimeInterval(8)
        while resources.count < 40, Date() < deadline {
            for resource in resources where !published.contains(ObjectIdentifier(resource)) {
                published.insert(ObjectIdentifier(resource))
                if let payload = payloads[ObjectIdentifier(resource)] { resource.publish(.ready(payload)) }
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resources.count == 40)
        #expect(maximumLive <= 4, "client body leases exceeded the bounded gate")
    }


    @Test func bodyLeasesRespectRemainingClientCapacity() async throws {
        let gate = HarnessDetailBodyGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        for index in 0..<30 {
            _ = try await client.subscribeThreadContent(threadId: "thread", scope: .turn(key: JSONText("row-\(index)")))
        }
        let remaining = await client.availableContentSlotCount()
        #expect(remaining == 2)
        defer { Task { await client.close() } }
        var resources: [HarnessContentResource] = []
        var payloads: [ObjectIdentifier: JSONValue] = [:]
        var published = Set<ObjectIdentifier>()
        var live = 0
        var maximumLive = 0
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                guard case .body(let reference) = scope else {
                    return HarnessContentResource(state: .ready(.null), retry: {}, release: {})
                }
                live += 1
                maximumLive = max(maximumLive, live)
                let resource = HarnessContentResource(state: .loading, retry: {}, release: { live -= 1 })
                resources.append(resource)
                payloads[ObjectIdentifier(resource)] = Self.chunk(reference: reference, text: "x")
                return resource
            },
            onIndexChange: { _ in },
            detailBodyCapacity: { await client.availableContentSlotCount() })
        let body = JSONValue.object(["slot": .text("detail"), "format": .text("text"), "length": .integer(1)])
        let root = VStack {
            ForEach(0..<4, id: \.self) { index in
                HarnessDetailBodyView(execution: "execution", contentID: "content",
                                      item: JSONText("capacity-\(index)"), bodyData: body,
                                      slot: "detail", context: context, gate: gate)
            }
        }
        let host = NSHostingView(rootView: root.frame(width: 420, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resources.count <= 2)

        let deadline = Date().addingTimeInterval(8)
        while resources.count < 4, Date() < deadline {
            for resource in resources where !published.contains(ObjectIdentifier(resource)) {
                published.insert(ObjectIdentifier(resource))
                if let payload = payloads[ObjectIdentifier(resource)] { resource.publish(.ready(payload)) }
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resources.count == 4)
        #expect(maximumLive <= 2)
    }

    @Test func bodyLeasesReportExhaustedClientCapacityWithoutCreatingResources() async throws {
        let gate = HarnessDetailBodyGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        for index in 0..<32 {
            _ = try await client.subscribeThreadContent(threadId: "thread", scope: .turn(key: JSONText("row-\(index)")))
        }
        let remaining = await client.availableContentSlotCount()
        #expect(remaining == 0)
        defer { Task { await client.close() } }
        var resources = 0
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                if case .body = scope { resources += 1 }
                return HarnessContentResource(state: .loading, retry: {}, release: {})
            },
            onIndexChange: { _ in },
            detailBodyCapacity: { await client.availableContentSlotCount() })
        let body = JSONValue.object(["slot": .text("detail"), "format": .text("text"), "length": .integer(1)])
        let root = VStack {
            ForEach(0..<4, id: \.self) { index in
                HarnessDetailBodyView(execution: "execution", contentID: "content",
                                      item: JSONText("full-\(index)"), bodyData: body,
                                      slot: "detail", context: context, gate: gate)
            }
        }
        let window = SwiftUIReplay.window(root.frame(width: 420, height: 300), width: 420, height: 300)
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)

        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        #expect(SwiftUIReplay.text(in: host).contains { $0.contains("内容容量已满") })
        #expect(resources == 0)
    }


    @Test func bodyViewShowsCapacityRetryAfterPageReservationTimeout() async throws {
        let gate = HarnessDetailBodyGate(pageCapacityTimeout: .milliseconds(100))
        var capacityReads = 0
        var resources = 0
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { _ in
                resources += 1
                return HarnessContentResource(state: .loading, retry: {}, release: {})
            },
            onIndexChange: { _ in },
            detailBodyCapacity: {
                capacityReads += 1
                // Admit the view, then every page attempt sees no slot.
                return capacityReads == 1 ? 4 : 0
            })
        let body = JSONValue.object(["slot": .text("detail"), "format": .text("text"), "length": .integer(1)])
        let root = HarnessDetailBodyView(execution: "execution", contentID: "content", item: "timeout-row",
                                         bodyData: body, slot: "detail", context: context, gate: gate)
        let window = SwiftUIReplay.window(root.frame(width: 420, height: 200), width: 420, height: 200)
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)

        var shown = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            shown = SwiftUIReplay.text(in: host).contains { $0.contains("内容容量已满") }
            if shown { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(shown)
        #expect(resources == 0)
        #expect(gate.pageReservationCount == 0)
    }

    @Test func zeroLengthDescriptorUsesFirstBodyPageLength() async throws {
        let gate = HarnessDetailBodyGate()
        var requested = false
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                guard case .body(let reference) = scope else {
                    return HarnessContentResource(state: .ready(.null), retry: {}, release: {})
                }
                requested = true
                return HarnessContentResource(state: .ready(.object([
                    "kind": .text("body"), "executionId": .string(reference.execution),
                    "itemId": .string(reference.item), "slot": .string(reference.slot),
                    "version": .text("v1"), "offset": .integer(0), "length": .integer(5),
                    "text": .text("hello")])), retry: {}, release: {})
            },
            onIndexChange: { _ in })
        // Directory descriptors may defer formatting and report zero; the first
        // body page establishes the authoritative total length.
        let body = JSONValue.object(["slot": .text("detail"), "format": .text("text"), "length": .integer(0)])
        let root = HarnessDetailBodyView(execution: "execution", contentID: "content", item: "deferred-length",
                                         bodyData: body, slot: "detail", context: context, gate: gate)
        let window = SwiftUIReplay.window(root.frame(width: 420, height: 200), width: 420, height: 200)
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)

        try await SwiftUIReplay.wait { requested && SwiftUIReplay.text(in: host).contains("hello") }
        #expect(SwiftUIReplay.text(in: host).contains("hello"))
    }

    @Test func detailRowsKeepNULNamespacedIdentitiesDistinct() async throws {
        let thinking = "\u{0}pi:thinking:row"
        let plain = "row"
        var bodyItems: [String] = []
        let directory = JSONValue.object([
            "kind": .text("detail"), "executionId": .text("execution"), "contentId": .text("content"),
            "items": .array([thinking, plain].map { item in
                .object(["id": .text(item), "kind": .text("error"), "bodies": .array([.object([
                    "slot": .text("detail"), "format": .text("text"), "length": .integer(item.count)])])])
            })
        ])
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                guard case .body(let reference) = scope else {
                    return HarnessContentResource(state: .ready(directory), retry: {}, release: {})
                }
                bodyItems.append(reference.item.string)
                return HarnessContentResource(state: .ready(.object([
                    "kind": .text("body"), "executionId": .string(reference.execution),
                    "itemId": .string(reference.item), "slot": .string(reference.slot),
                    "version": .text("v"), "offset": .integer(0),
                    "length": .integer(reference.item.string.count), "text": .text(reference.item.string)])),
                    retry: {}, release: {})
            },
            onIndexChange: { _ in })
        let root = HarnessDetailList(directory: directory, context: context)
        let host = NSHostingView(rootView: root.frame(width: 420, height: 240))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        try await SwiftUIReplay.wait {
            host.layoutSubtreeIfNeeded()
            return Set(bodyItems) == Set([thinking, plain])
        }
        #expect(bodyItems.contains(thinking) && bodyItems.contains(plain))
        #expect(Set(bodyItems).count == 2)
        #expect(nativeReadingInteractionKey(JSONText(thinking)) != nativeReadingInteractionKey(JSONText(plain)))
    }

    @Test func versionChangeAcceptsNewLengthFromOffsetZero() async throws {
        let gate = HarnessDetailBodyGate()
        var firstPageServed = false
        var restartedPageServed = false
        var bodies: [String] = []
        let contentID = "content-v1"
        let directory = Self.directory(execution: "execution", item: "row", text: "aaaa", contentID: contentID)
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                guard case .body(let reference) = scope else {
                    return HarnessContentResource(state: .ready(directory), retry: {}, release: {})
                }
                bodies.append(reference.cursor)
                let value: JSONValue
                switch reference.cursor {
                case "" where !firstPageServed:
                    firstPageServed = true
                    value = Self.chunkPayload(reference: reference, text: "aaaa", version: "v1", offset: 0, length: 4, next: "old-next")
                case "old-next":
                    let resource = HarnessContentResource(state: .loading, retry: {}, release: {})
                    resource.publish(.error("changed"), code: "DETAIL_VERSION_CHANGED")
                    return resource
                case "":
                    restartedPageServed = true
                    value = Self.chunkPayload(reference: reference, text: "bbbb", version: "v2", offset: 0, length: 8, next: "new-next")
                case "new-next":
                    value = Self.chunkPayload(reference: reference, text: "bbbb", version: "v2", offset: 4, length: 8, next: nil)
                default:
                    let resource = HarnessContentResource(state: .loading, retry: {}, release: {})
                    resource.publish(.error("unexpected cursor"), code: "INVALID_CURSOR")
                    return resource
                }
                return HarnessContentResource(state: .ready(value), retry: {}, release: {})
            },
            onIndexChange: { _ in })
        let body = JSONValue.object(["slot": .text("detail"), "format": .text("text"), "length": .integer(4)])
        let root = HarnessDetailBodyView(execution: "execution", contentID: contentID, item: "row",
                                         bodyData: body, slot: "detail", context: context, gate: gate)
        let host = NSHostingView(rootView: root.frame(width: 420, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if restartedPageServed, SwiftUIReplay.text(in: host).contains("bbbbbbbb") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(firstPageServed && restartedPageServed)
        #expect(bodies.prefix(3).elementsEqual(["", "old-next", ""]))
        #expect(SwiftUIReplay.text(in: host).contains("bbbbbbbb"))
    }

    @Test func contentFailurePreservesCodeAndRetryResumesWaiters() async throws {
        let resource = HarnessContentResource(state: .loading, retry: {}, release: {})
        let waiting = Task { try await resource.waitForResult() }
        resource.publish(.error("changed"), code: "DETAIL_VERSION_CHANGED")
        do {
            _ = try await waiting.value
            Issue.record("Expected a coded content failure")
        } catch let failure as HarnessContentFailure {
            #expect(failure.code == "DETAIL_VERSION_CHANGED")
        }

        let retry = HarnessContentResource(state: .loading, retry: {
            throw HarnessContentFailure(code: "DETAIL_VERSION_CHANGED", message: "changed")
        }, release: {})
        let retried = Task { try await retry.waitForResult() }
        do {
            try await retry.retry()
            Issue.record("Expected retry to throw")
        } catch let failure as HarnessContentFailure {
            #expect(failure.code == "DETAIL_VERSION_CHANGED")
        }
        do {
            _ = try await retried.value
            Issue.record("Expected the waiter to observe the retry failure")
        } catch let failure as HarnessContentFailure {
            #expect(failure.code == "DETAIL_VERSION_CHANGED")
        }
    }

    private static func directory(execution: String, item: String, text: String, contentID: String = "content-v1") -> JSONValue {
        .object(["kind": .text("detail"), "executionId": .text(execution), "contentId": .text(contentID),
                 "items": .array([.object(["id": .text(item), "kind": .text("error"),
                    "bodies": .array([.object(["slot": .text("detail"), "format": .text("text"),
                        "length": .integer(text.utf8.count)])])])])])
    }

    private static func chunkPayload(reference: HarnessDetailBodyReference, text: String, version: String,
                                     offset: Int, length: Int, next: String?) -> JSONValue {
        var value: [JSONText: JSONValue] = ["kind": .text("body"), "executionId": .string(reference.execution),
            "itemId": .string(reference.item), "slot": .string(reference.slot), "version": .text(version),
            "offset": .integer(offset), "length": .integer(length), "text": .text(text)]
        if let next { value["next"] = .text(next) }
        return .object(value)
    }

    private static func chunk(reference: HarnessDetailBodyReference, text: String = "hello detail") -> JSONValue {
        .object(["kind": .text("body"), "executionId": .string(reference.execution),
                 "itemId": .string(reference.item), "slot": .string(reference.slot), "version": .text("v"),
                 "offset": .integer(0), "length": .integer(text.utf8.count), "text": .text(text)])
    }
}
