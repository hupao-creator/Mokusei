import AppKit
import WebKit

@MainActor enum WebScrollbarReplay {
    static func run() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(NativeWebScrollbarStyle.script)
        let stylesheet = ScrollbarStylesheetFixture()
        configuration.setURLSchemeHandler(stylesheet, forURLScheme: "mokusei-scrollbar-fixture")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 280), configuration: configuration)
        precondition(web.window == nil)
        web.loadHTMLString(#"""
        <!doctype html><html><head><style>
        html { overflow: scroll; }
        .pane { width: 180px; height: 90px; overflow: scroll; }
        .content { width: 600px; height: 700px; }
        ::-webkit-scrollbar-track { background: red; box-shadow: inset 0 0 3px black; border: 2px solid blue; }
        </style></head><body>
        <div id="pane" class="pane"><div class="content">Selectable content</div></div>
        <textarea id="editor">Keep this selection</textarea>
        <iframe id="child" srcdoc="<html><body style='height:1500px'>Frame content</body></html>"></iframe>
        <div class="content"></div>
        <script>
        window.baseline = [document.documentElement.clientWidth, pane.clientWidth, pane.clientHeight];
        editor.setSelectionRange(5, 9);
        </script></body></html>
        """#, baseURL: nil)
        // Poll document/child readiness without creating a window, activating an
        // app, changing system preferences or sending events to another process.
        try await wait(in: web, for: "document.readyState === 'complete' && document.adoptedStyleSheets.length === 1 && document.getElementById('child')?.contentDocument?.adoptedStyleSheets.length === 1")
        let checks = #"""
        (() => {
          const assert = (value, message) => { if (!value) throw new Error(message); };
          assert(CSS.supports('scrollbar-color', 'red transparent'), 'scrollbar-color unsupported on this WebKit');
          const transparentTrack = el => getComputedStyle(el).scrollbarColor.endsWith('rgba(0, 0, 0, 0)');
          assert([document.documentElement, pane, editor].every(transparentTrack), 'nontransparent native track');
          assert(child.contentWindow.getComputedStyle(child.contentDocument.documentElement).scrollbarColor.endsWith('rgba(0, 0, 0, 0)'), 'frame policy missing');
          assert(JSON.stringify(baseline) === JSON.stringify([document.documentElement.clientWidth, pane.clientWidth, pane.clientHeight]), 'scrollbar styling changed geometry');
          const track = getComputedStyle(pane, '::-webkit-scrollbar-track');
          assert(track.backgroundColor === 'rgba(0, 0, 0, 0)' && track.boxShadow === 'none' && track.borderWidth === '0px', 'page track override survived');
          pane.scrollTo(200, 240); window.scrollTo(0, 300);
          assert(pane.scrollLeft === 200 && pane.scrollTop === 240 && scrollY === 300, 'scrolling disabled');
          assert(editor.selectionStart === 5 && editor.selectionEnd === 9, 'textarea selection changed');
          const dynamic = document.createElement('div'); dynamic.className = 'pane'; document.body.append(dynamic);
          assert(transparentTrack(dynamic), 'dynamic overflow policy missing');
          return true;
        })()
        """#
        let checked = try await web.evaluateJavaScript(checks)
        precondition(checked as? Bool == true)
        _ = try await web.evaluateJavaScript(NativeWebScrollbarStyle.source, in: nil,
                                             contentWorld: .world(name: "Mokusei.Scrollbars"))
        let retained = try await web.evaluateJavaScript("pane.scrollLeft === 200 && pane.scrollTop === 240 && scrollY === 300 && editor.selectionStart === 5 && editor.selectionEnd === 9")
        precondition(retained as? Bool == true)
        let sheetCount = try await web.evaluateJavaScript("document.adoptedStyleSheets.length")
        precondition(sheetCount as? Int == 1)
        web.loadHTMLString(#"""
        <!doctype html><html><head><title>Dark foreground fixture</title><style>
        html { scrollbar-color: white transparent; overflow: scroll; }
        body { color: white; background: black; }
        .pane { width: 180px; height: 90px; overflow: scroll; }
        #light { color: black; background: white; }
        </style></head><body>
        <div id="dark" class="pane"><div style="height:900px">Dark pane</div></div>
        <div id="light" class="pane"><div style="height:900px">Light pane</div></div>
        <div style="height:1800px">Page text</div>
        </body></html>
        """#, baseURL: nil)
        try await wait(in: web, for: "document.title === 'Dark foreground fixture' && document.adoptedStyleSheets.length === 1 && getComputedStyle(document.documentElement).scrollbarColor.startsWith('rgb(255, 255, 255)')")
        let dark = try await web.evaluateJavaScript(#"""
        (() => {
          const root = getComputedStyle(document.documentElement);
          if (root.colorScheme !== 'normal' || !root.scrollbarColor.startsWith('rgb(255, 255, 255)')) throw new Error('dark viewport thumb lost contrast');
          if (!getComputedStyle(dark).scrollbarColor.startsWith('rgb(255, 255, 255)')) throw new Error('dark overflow thumb lost contrast');
          if (!getComputedStyle(light).scrollbarColor.startsWith('rgb(0, 0, 0)')) throw new Error('light overflow thumb lost contrast');
          if (![document.documentElement, dark, light].every(el => getComputedStyle(el).scrollbarColor.endsWith('rgba(0, 0, 0, 0)'))) throw new Error('contrast fix restored a track');
          document.body.style.color = 'black'; document.body.style.backgroundColor = 'white';
          return true;
        })()
        """#)
        precondition(dark as? Bool == true)
        try await wait(in: web, for: "getComputedStyle(document.documentElement).scrollbarColor.startsWith('rgb(0, 0, 0)')")
        _ = try await web.evaluateJavaScript("document.body.className = 'dark'; document.body.style.color = 'white'; document.body.style.backgroundColor = 'black'")
        try await wait(in: web, for: "getComputedStyle(document.documentElement).scrollbarColor.startsWith('rgb(255, 255, 255)')")
        try await verifyStyleRefresh(in: web, stylesheet: stylesheet)
        web.loadHTMLString(#"""
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'none'">
        <title>CSP scrollbar fixture</title></head><body>
        <textarea>Native text scrolling and selection</textarea>
        </body></html>
        """#, baseURL: nil)
        try await wait(in: web, for: "document.title === 'CSP scrollbar fixture' && document.adoptedStyleSheets.length === 1")
        let csp = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('textarea')).scrollbarColor.endsWith('rgba(0, 0, 0, 0)')")
        precondition(csp as? Bool == true)
        precondition(web.window == nil)
        web.stopLoading()
        print("PASS: windowless WebKit transparent tracks, foreground contrast, body themes, real resize media queries, inserted/edited/loaded stylesheets, coalesced reads, page overrides, subframes, dynamic overflow, CSP, idempotence, geometry, scrolling and selection")
    }

    private static func verifyStyleRefresh(in web: WKWebView, stylesheet: ScrollbarStylesheetFixture) async throws {
        web.loadHTMLString(#"""
        <!doctype html><html><head><title>Stylesheet refresh fixture</title>
        <style id="responsive">
        html { overflow: scroll; }
        body { color: black; background: white; min-height: 2000px; }
        @media (max-width: 350px) { body { color: white; background: black; } }
        </style></head><body><div id="content">Content</div></body></html>
        """#, baseURL: nil)
        let black = "getComputedStyle(document.body).color === 'rgb(0, 0, 0)' && getComputedStyle(document.documentElement).scrollbarColor === 'rgb(0, 0, 0) rgba(0, 0, 0, 0)'"
        let white = "getComputedStyle(document.body).color === 'rgb(255, 255, 255)' && getComputedStyle(document.documentElement).scrollbarColor === 'rgb(255, 255, 255) rgba(0, 0, 0, 0)'"
        try await wait(in: web, for: "document.title === 'Stylesheet refresh fixture' && document.adoptedStyleSheets.length === 1 && (\(black))")
        web.frame.size.width = 300
        try await wait(in: web, for: "innerWidth === 300 && (\(white))")
        web.frame.size.width = 420
        try await wait(in: web, for: "innerWidth === 420 && (\(black))")
        _ = try await web.evaluateJavaScript("window.theme = document.createElement('style'); theme.textContent = 'body { color: white; background: black; }'; document.head.append(theme)")
        try await wait(in: web, for: white)
        _ = try await web.evaluateJavaScript("theme.firstChild.data = 'body { color: black; background: white; }'")
        try await wait(in: web, for: black)
        _ = try await web.evaluateJavaScript("theme.textContent = 'body { color: white; background: black; }'")
        try await wait(in: web, for: white)
        _ = try await web.evaluateJavaScript("theme.remove()")
        try await wait(in: web, for: black)

        // Count the production script's real computed-style calls in its own
        // isolated world. Page-world assertions do not contribute to this count.
        let world = WKContentWorld.world(name: "Mokusei.Scrollbars")
        _ = try await web.evaluateJavaScript(#"""
        globalThis.__scrollbarReads = 0;
        const originalStyle = globalThis.getComputedStyle;
        globalThis.getComputedStyle = function(...args) {
          if (args[0] === document.body) globalThis.__scrollbarReads++;
          return originalStyle.apply(this, args);
        };
        void 0;
        """#, in: nil, contentWorld: world)
        _ = try await web.evaluateJavaScript("window.themeLink = document.createElement('link'); themeLink.rel = 'stylesheet'; themeLink.href = 'mokusei-scrollbar-fixture://theme.css'; document.head.append(themeLink)")
        // Await the insertion refresh before completing the resource. Otherwise
        // an insertion timer could hide a missing stylesheet-load notification.
        try await waitForStyleRead(in: web)
        precondition(stylesheet.pending != nil, "Local stylesheet was not requested")
        let beforeLoad = try await web.evaluateJavaScript(black)
        precondition(beforeLoad as? Bool == true)
        stylesheet.finish("body { color: white; background: black; }")
        try await wait(in: web, for: "themeLink.sheet !== null && (\(white))")
        _ = try await web.evaluateJavaScript("themeLink.remove()")
        try await wait(in: web, for: black)

        // Ordinary content/meta changes must not read style; a synchronous burst
        // of resize and stylesheet mutations must result in one refresh only.
        _ = try await web.evaluateJavaScript("globalThis.__scrollbarReads = 0", in: nil, contentWorld: world)
        _ = try await web.evaluateJavaScript("for (let i = 0; i < 100; i++) content.append(document.createTextNode('text')); document.head.append(document.createElement('meta'))")
        try await Task.sleep(for: .milliseconds(200))
        let unrelated = try await web.evaluateJavaScript("globalThis.__scrollbarReads", in: nil, contentWorld: world)
        precondition(unrelated as? Int == 0, "Unrelated DOM changes caused style reads")
        _ = try await web.evaluateJavaScript("for (let i = 0; i < 100; i++) window.dispatchEvent(new Event('resize')); responsive.textContent = 'html { overflow: scroll; } body { color: white; background: black; min-height: 2000px; }'")
        try await wait(in: web, for: white)
        try await Task.sleep(for: .milliseconds(200))
        let burst = try await web.evaluateJavaScript("globalThis.__scrollbarReads", in: nil, contentWorld: world)
        precondition(burst as? Int == 1, "A resize/style burst caused redundant style reads: \(String(describing: burst))")
        _ = try await web.evaluateJavaScript("window.bodyTheme = document.createElement('style'); bodyTheme.textContent = 'body { color: black; background: white; }'; document.body.append(bodyTheme)")
        try await wait(in: web, for: black)
        precondition(web.window == nil)
    }

    private static func waitForStyleRead(in web: WKWebView) async throws {
        for _ in 0..<100 {
            let count = try await web.evaluateJavaScript("globalThis.__scrollbarReads", in: nil,
                                                        contentWorld: .world(name: "Mokusei.Scrollbars"))
            if let count = count as? Int, count > 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        preconditionFailure("Stylesheet insertion did not trigger a style refresh")
    }

    private static func wait(in web: WKWebView, for condition: String) async throws {
        for _ in 0..<100 {
            let value = try? await web.evaluateJavaScript(condition)
            if value as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        preconditionFailure("Windowless WebKit document did not become ready: \(condition)")
    }
}

/// Hold a real local CSS request until the replay releases it. No HTTP server,
/// network page, window or synthetic load event is involved.
@MainActor private final class ScrollbarStylesheetFixture: NSObject, WKURLSchemeHandler {
    var pending: (any WKURLSchemeTask)?
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        precondition(pending == nil)
        pending = urlSchemeTask
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        if pending === urlSchemeTask { pending = nil }
    }
    func finish(_ css: String) {
        let task = pending!
        pending = nil
        let data = Data(css.utf8)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/css",
                                    expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
}
