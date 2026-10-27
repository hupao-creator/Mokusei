import AppKit
import Network
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
@testable import MokuseiSidecardBrowser

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeBrowserViewportTests {
    @Observable @MainActor final class State {
        var scale: CGFloat = 1
        var suppressed = false
        var coveredBottom: CGFloat = 0
        var revision = 0
    }

    private struct Surface: View {
        let session: BrowserWebSession
        let state: State
        var body: some View {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Text("Revision \(state.revision)").frame(height: 40)
                    BrowserViewport(session: session, suppressed: state.suppressed, coveredBottom: state.coveredBottom)
                        .padding(8)
                }
                .frame(width: geometry.size.width / state.scale, height: geometry.size.height / state.scale)
                .background(.regularMaterial)
                .mask(Rectangle())
                .scaleEffect(state.scale, anchor: .topLeading)
            }
        }
    }

    private func descendant(_ view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let found = descendant(child, matching: predicate) { return found }
        }
        return nil
    }

    private func attached(_ layer: CALayer?, to root: CALayer?) -> Bool {
        guard let root else { return false }
        var current = layer
        while let layer = current {
            if layer === root { return true }
            current = layer.superlayer
        }
        return false
    }

    private func wait(_ description: String, until predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await predicate() == false {
            guard ContinuousClock.now < deadline else { throw BrowserHTTPFixture.Failure(description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settledFrame(of portal: NSView, in host: NSView, window: NSWindow) async throws -> CGRect {
        var previous: CGRect?
        var stablePasses = 0
        try await wait("annotation portal layer attaches and layout settles") {
            host.layoutSubtreeIfNeeded(); portal.superview?.layoutSubtreeIfNeeded()
            let frame = portal.convert(portal.bounds, to: host)
            guard portal.window === window, attached(portal.layer, to: host.layer), !frame.isEmpty else {
                previous = nil; stablePasses = 0; return false
            }
            stablePasses = previous == frame ? stablePasses + 1 : 0
            previous = frame
            return stablePasses >= 2
        }
        return portal.convert(portal.bounds, to: host)
    }

    @Test func rejectedIframeDownloadsLeaveTheMainDocumentReadyAndVisible() async throws {
        _ = NSApplication.shared
        let fixture = try BrowserHTTPFixture()
        defer { fixture.close() }
        try await wait("browser HTTP fixture starts") { fixture.port != nil }
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let session = BrowserWebSession(store: .nonPersistent())
        let host = NSHostingView(rootView: Surface(session: session, state: State()))
        window.contentView = host; window.orderBack(nil)
        defer { session.release(); window.contentView = nil; window.close() }

        for route in ["attachment", "binary"] {
            session.navigate(try fixture.url("/page/" + route))
            try await wait("iframe response and main navigation complete") {
                fixture.responses.contains("/" + route) && !session.loading && !session.webView.isLoading
            }
            try #require(session.ready && session.error == nil)
            #expect((try await session.webView.evaluateJavaScript("document.getElementById('marker').textContent")) as? String == "Main document remains visible")
            host.layoutSubtreeIfNeeded()
            #expect(session.webView.window === window)
            #expect(attached(session.webView.layer, to: host.layer))
            session.beginAnnotation()
            #expect(session.annotating)
            try await wait("annotation selection bridge installs") {
                try await session.evaluateJSON("return typeof globalThis.__mokuseiAnnotationCancel === 'function';") == .bool(true)
            }
            session.cancelAnnotation()
        }

        session.navigate(try fixture.url("/attachment"))
        try await wait("main-frame download is rejected") { !session.loading && session.error != nil }
        #expect(!session.ready && session.error == "网页下载已取消")
        // This fixture mounts the viewport directly; the production Sidecard
        // owns the error overlay and its visibility/suppression binding.
        session.beginAnnotation()
        #expect(!session.annotating && session.selection == nil)
    }

    @Test func annotationPortalStaysAlignedWhenDocumentZoomPassesBothWebKitLimits() async throws {
        _ = NSApplication.shared
        let fixture = try BrowserHTTPFixture()
        defer { fixture.close() }
        try await wait("browser HTTP fixture starts") { fixture.port != nil }
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let session = BrowserWebSession(store: .nonPersistent())
        let host = NSHostingView(rootView: Surface(session: session, state: State()))
        window.contentView = host; window.orderBack(nil)
        defer { session.release(); window.contentView = nil; window.close() }
        session.navigate(try fixture.url("/zoom"))
        try await wait("zoom fixture is ready") { session.ready && !session.loading }
        host.layoutSubtreeIfNeeded()
        let viewport = try #require(session.viewport)

        for upper in [true, false] {
            session.cancelAnnotation()
            session.webView.mokuseiResetFocusedWebContentZoom(nil)
            for _ in 0..<(upper ? 18 : 16) {
                if upper { session.webView.mokuseiZoomInFocusedWebContent(nil) }
                else { session.webView.mokuseiZoomOutFocusedWebContent(nil) }
            }
            let zoom = session.webView.pageZoom
            #expect(zoom == (upper ? 5 : 0.25))
            let marker = upper ? "upper" : "lower"
            // The fixture supplies only DOM geometry. Production selection
            // refresh and native portal placement still run on every zoom action.
            let raw = try await session.evaluateJSON("""
                globalThis.__mokuseiAnnotationRead = () => {
                    const r = document.getElementById('\(marker)').getBoundingClientRect();
                    return {kind:'element', rect:{x:r.x,y:r.y,width:r.width,height:r.height},
                        viewport:{width:innerWidth,height:innerHeight,scrollX,scrollY}};
                };
                return globalThis.__mokuseiAnnotationRead();
                """)
            session.selection = try BrowserSelection(raw)
            session.annotating = true
            viewport.refreshEditor(); viewport.layoutSubtreeIfNeeded()
            let portal = try #require(descendant(viewport) { $0.identifier?.rawValue == "mokusei-browser-annotation-portal" })
            let before = try await settledFrame(of: portal, in: host, window: window)
            let level = session.webView.documentZoomLevel
            for _ in 0..<8 {
                if upper { session.webView.mokuseiZoomInFocusedWebContent(nil) }
                else { session.webView.mokuseiZoomOutFocusedWebContent(nil) }
            }
            // Await WebKit's queued geometry reads before comparing the portal.
            let afterRaw = try await session.evaluateJSON("return globalThis.__mokuseiAnnotationRead();")
            session.selection = try BrowserSelection(afterRaw)
            viewport.refreshEditor(); host.layoutSubtreeIfNeeded(); viewport.layoutSubtreeIfNeeded()
            let after = try await settledFrame(of: portal, in: host, window: window)
            #expect(afterRaw == raw)
            #expect(session.webView.pageZoom == zoom)
            #expect(session.webView.documentZoomLevel == level + (upper ? 4 : -4))
            #expect(abs(before.minX - after.minX) <= 1 && abs(before.maxX - after.maxX) <= 1)
            #expect(abs(before.minY - after.minY) <= 1 && abs(before.maxY - after.maxY) <= 1)
            #expect(portal.window === window && attached(portal.layer, to: host.layer))
        }
    }

    @Test func documentAndEditorKeepTheirRenderLayersThroughHostingUpdatesAndZoom() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let session = BrowserWebSession(store: .nonPersistent())
        let state = State()
        let host = NSHostingView(rootView: Surface(session: session, state: state))
        window.contentView = host
        window.orderBack(nil)
        defer { session.release(); window.contentView = nil; window.close() }
        session.webView.loadHTMLString("<html><body style='background:#20a040'>Visible browser fixture</body></html>",
                                      baseURL: URL(string: "https://fixture.invalid/"))
        for _ in 0..<100 {
            if (try? await session.webView.evaluateJavaScript("document.body.innerText")) as? String == "Visible browser fixture" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try await session.webView.evaluateJavaScript("document.body.innerText")) as? String == "Visible browser fixture")

        for scale: CGFloat in [1, 0.75, 1.5, 1] {
            state.scale = scale; state.revision += 1
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let viewport = try #require(session.viewport)
            viewport.layoutSubtreeIfNeeded()
            let clip = try #require(session.webView.superview)
            #expect(clip.superview === viewport)
            #expect(attached(session.webView.layer, to: host.layer))
            let visual = viewport.convert(viewport.bounds, to: host)
            #expect(abs(session.webView.bounds.width - visual.width) <= 2)
            // Compensating the host zoom keeps WebKit at native DIP size.
            let painted = session.webView.convert(session.webView.bounds, to: host)
            #expect(abs(painted.width - session.webView.bounds.width) <= 2)
            let point = session.webView.convert(CGPoint(x: 30, y: 30), to: viewport.superview)
            let hit = viewport.hitTest(point)
            #expect(hit === session.webView || hit?.isDescendant(of: session.webView) == true)
        }

        let viewport = try #require(session.viewport)
        let height = session.webView.bounds.height
        state.coveredBottom = 100; state.revision += 1
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.webView.bounds.height == height)
        #expect(session.webView.superview?.bounds.height == height - 100)

        session.selection = try BrowserSelection(.object(["kind": .text("region"),
            "rect": .object(["x": .number(10), "y": .number(10), "width": .number(100), "height": .number(60)]),
            "viewport": .object(["width": .number(900), "height": .number(600), "scrollX": .number(0), "scrollY": .number(0)])]))
        session.annotating = true
        viewport.refreshEditor()
        state.revision += 1
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(descendant(viewport) { $0.identifier?.rawValue == "mokusei-browser-annotation-portal" })
        #expect(editor.superview === viewport)
        #expect(attached(editor.layer, to: host.layer))

        state.suppressed = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.webView.window == nil && editor.window == nil)
        #expect(viewport.hitTest(.zero) == nil)
        state.suppressed = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.webView.window === window)
        #expect(attached(session.webView.layer, to: host.layer))
        #expect(attached(editor.layer, to: host.layer))
    }

    @Test func nativeWebsiteCookiesStayWithTheirThread() async throws {
        let thread = JSONText("browser-isolation-\(UUID().uuidString)")
        let first = BrowserRunSessions.store(for: thread)
        let otherThread = BrowserRunSessions.store(for: JSONText("other-\(UUID().uuidString)"))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "fixture.invalid", .path: "/", .name: "thread-identity", .value: "first-thread"
        ]))
        await first.httpCookieStore.setCookie(cookie)
        #expect(BrowserRunSessions.store(for: thread) === first)
        #expect(await first.httpCookieStore.allCookies().contains { $0.name == "thread-identity" && $0.value == "first-thread" })
        #expect(await otherThread.httpCookieStore.allCookies().allSatisfy { $0.name != "thread-identity" })
        await first.httpCookieStore.deleteCookie(cookie)
    }
}

/// Small loopback fixture: real HTTP headers make WebKit distinguish iframe
/// downloads from successful main-frame documents. Every accepted socket closes.
@MainActor
private final class BrowserHTTPFixture {
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var closed = false
    private(set) var port: UInt16?
    private(set) var responses = Set<String>()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.closed else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, buffered: Data())
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String) throws -> URL {
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw Failure("Missing browser fixture address") }
        return url
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, error == nil, let data else { connection.cancel(); return }
                let request = buffered + data
                guard request.count <= 8192 else { connection.cancel(); return }
                guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { connection.cancel() } else { self.receive(connection, buffered: request) }
                    return
                }
                let path = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
                self.respond(connection, path: path)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        let mime: String, extra: String, body: String
        switch path {
        case "/attachment":
            mime = "text/plain"; extra = "Content-Disposition: attachment; filename=fixture.txt\r\n"; body = "iframe attachment"
        case "/binary":
            mime = "application/octet-stream"; extra = ""; body = "iframe binary"
        case "/page/attachment", "/page/binary":
            mime = "text/html"; extra = ""
            body = "<html><body><p id='marker'>Main document remains visible</p><iframe src='/\(path.split(separator: "/").last!)'></iframe></body></html>"
        case "/zoom":
            mime = "text/html"; extra = ""
            body = """
                <html><body style='margin:0;width:2000px;height:2000px'>
                <div id='upper' style='position:absolute;left:40px;top:40px;width:10px;height:10px;background:green'></div>
                <div id='lower' style='position:absolute;left:400px;top:400px;width:40px;height:40px;background:blue'></div>
                </body></html>
                """
        default:
            connection.cancel(); return
        }
        let bytes = Data(body.utf8)
        let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(bytes.count)\r\n\(extra)Connection: close\r\n\r\n".utf8)
        connection.send(content: headers + bytes, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if error == nil { self?.responses.insert(path) }
                connection.cancel()
            }
        })
    }

    func close() {
        closed = true
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }
}
