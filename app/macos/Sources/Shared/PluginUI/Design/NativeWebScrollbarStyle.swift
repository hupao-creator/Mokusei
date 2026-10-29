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
      let writtenRootStyle;
      const updateViewport = () => {
        const color = getComputedStyle(document.body || root).color;
        if (root.style.getPropertyValue('--mokusei-viewport-scrollbar-thumb') !== color) {
          root.style.setProperty('--mokusei-viewport-scrollbar-thumb', color);
          writtenRootStyle = root.getAttribute('style');
        }
      };
      // Throttle resize bursts and merge DOM/load notifications into one read.
      // A timer also runs in windowless/occluded WebKit, where rAF may be paused.
      let refreshPending = false;
      const scheduleViewport = () => {
        if (refreshPending) return;
        refreshPending = true;
        setTimeout(() => { refreshPending = false; updateViewport(); }, 50);
      };
      const isStylesheet = node => node instanceof Element && node.matches('style,link[rel~="stylesheet" i]');
      const containsStylesheet = node => node instanceof Element &&
        (isStylesheet(node) || node.querySelector('style,link[rel~="stylesheet" i]'));
      const headObserver = new MutationObserver(records => {
        const changed = records.some(record => {
          if (record.type === 'attributes')
            return isStylesheet(record.target) || (record.target.localName === 'link' && record.attributeName === 'rel');
          if (record.type === 'characterData') return isStylesheet(record.target.parentElement);
          return isStylesheet(record.target) || [...record.addedNodes, ...record.removedNodes].some(containsStylesheet);
        });
        if (changed) scheduleViewport();
      });
      let body, head;
      const bodyObserver = new MutationObserver(scheduleViewport);
      const observeContainers = () => {
        if (body !== document.body) {
          bodyObserver.disconnect(); body = document.body;
          if (body) bodyObserver.observe(body, {attributes: true, attributeFilter: ['class', 'style']});
        }
        if (head !== document.head) {
          headObserver.disconnect(); head = document.head;
          if (head) headObserver.observe(head, {childList: true, subtree: true, characterData: true,
            attributes: true, attributeFilter: ['href', 'rel', 'media', 'disabled', 'title']});
        }
      };
      const rootObserver = new MutationObserver(records => {
        observeContainers();
        // Ignore the style mutation from our own custom-property write. Other
        // root/body changes still schedule a refresh, including a changed body.
        if (records.some(record => record.type !== 'attributes' || record.attributeName !== 'style' ||
            root.getAttribute('style') !== writtenRootStyle)) scheduleViewport();
      });
      rootObserver.observe(root, {attributes: true, attributeFilter: ['class', 'style'], childList: true});
      // Capture non-bubbling resource loads, including CSS outside head and
      // @imports. An insertion refresh can precede the stylesheet's actual load.
      document.addEventListener('load', event => { if (isStylesheet(event.target)) scheduleViewport(); }, true);
      window.addEventListener('resize', scheduleViewport);
      matchMedia('(prefers-color-scheme: dark)').addEventListener('change', scheduleViewport);
      observeContainers();
      updateViewport();
      globalThis.__mokuseiScrollbarSheet = sheet;
    })();
    """#
}
