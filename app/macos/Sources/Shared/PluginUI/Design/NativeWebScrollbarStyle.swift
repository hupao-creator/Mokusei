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
        * { scrollbar-color: color-mix(in srgb, CanvasText 55%, transparent) transparent !important; }
        @media (prefers-contrast: more), (forced-colors: active) {
          * { scrollbar-color: CanvasText transparent !important; }
        }
        @supports not (scrollbar-color: black transparent) {
          ::-webkit-scrollbar { background: transparent !important; }
          ::-webkit-scrollbar-thumb {
            background: color-mix(in srgb, CanvasText 55%, transparent) !important;
            border-radius: 999px;
          }
          @media (prefers-contrast: more), (forced-colors: active) {
            ::-webkit-scrollbar-thumb { background: CanvasText !important; }
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
      globalThis.__mokuseiScrollbarSheet = sheet;
    })();
    """#
}
