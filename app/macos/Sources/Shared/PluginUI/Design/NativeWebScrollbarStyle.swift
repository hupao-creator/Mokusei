import WebKit

/// Share scrollbar decoration between Report documents and Browser frames.
/// Keep WebKit's native scroll model, hit testing, fading and system preference
/// handling. In particular, do not set scrollbar dimensions or overflow here.
@MainActor public enum NativeWebScrollbarStyle {
    public static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd,
                     forMainFrameOnly: false, in: .world(name: "Mokusei.Scrollbars"))
    }

    public static let source = #"""
    (() => {
      if (globalThis.__mokuseiScrollbarSheet) return;
      // Constructed sheets also work on documents that disallow inline style
      // elements via CSP. No page capabilities or event handlers are replaced.
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(`
        /* Standard colors retain native overlay fading and scrollbar metrics. */
        /* CanvasText can stay black on a black page without color-scheme. Use
           the actual foreground, without reducing its contrast through alpha. */
        * { scrollbar-color: currentColor transparent !important; }
        :root { scrollbar-color: var(--mokusei-viewport-scrollbar-thumb, currentColor) transparent !important; }
        @supports not (scrollbar-color: black transparent) {
          ::-webkit-scrollbar { background: transparent !important; }
          ::-webkit-scrollbar-thumb {
            background: currentColor !important;
            border-radius: 999px;
          }
          :root::-webkit-scrollbar-thumb {
            background: var(--mokusei-viewport-scrollbar-thumb, currentColor) !important;
          }
        }
        /* WebKit before scrollbar-color support, and page-authored pseudo parts. */
        ::-webkit-scrollbar-track, ::-webkit-scrollbar-track-piece, ::-webkit-scrollbar-corner {
          background: transparent !important;
          border: none !important;
          box-shadow: none !important;
        }
      `);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      // The viewport belongs to html, but most pages put their foreground and
      // canvas background on body. Keep only this root color in sync; nested
      // overflow colors follow currentColor directly in CSS.
      const root = document.documentElement;
      const updateViewport = () => {
        const color = getComputedStyle(document.body || root).color;
        if (root.style.getPropertyValue('--mokusei-viewport-scrollbar-thumb') !== color)
          root.style.setProperty('--mokusei-viewport-scrollbar-thumb', color);
      };
      let body;
      const bodyObserver = new MutationObserver(updateViewport);
      const observeBody = () => {
        if (body !== document.body) {
          bodyObserver.disconnect(); body = document.body;
          if (body) bodyObserver.observe(body, {attributes: true, attributeFilter: ['class', 'style']});
        }
        updateViewport();
      };
      const rootObserver = new MutationObserver(observeBody);
      rootObserver.observe(root, {attributes: true, attributeFilter: ['class', 'style'], childList: true});
      matchMedia('(prefers-color-scheme: dark)').addEventListener('change', updateViewport);
      observeBody();
      globalThis.__mokuseiScrollbarSheet = sheet;
    })();
    """#
}
