import AppKit
import WebKit

@MainActor enum WebScrollbarReplay {
    static func run() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(NativeWebScrollbarStyle.script)
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
        print("PASS: windowless WebKit transparent tracks, dark/light foreground contrast without color-scheme, body theme changes, page overrides, subframes, dynamic overflow, CSP, idempotence, geometry, both axes and textarea selection")
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
