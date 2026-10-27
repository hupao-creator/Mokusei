import AppKit
typealias MarkdownPlatformRepresentable = NSViewRepresentable
typealias MarkdownPlatformTextView = NSTextView
typealias MarkdownPlatformTextDelegate = NSTextViewDelegate
import MokuseiCore
import SwiftUI

/// TextKit owns selection, accessibility, native Copy, and links. Attributed
/// strings, attachments and layout are created only on the main actor.
struct MarkdownSelectableText: MarkdownPlatformRepresentable {
    let spans: [MarkdownSpan]
    let fontSize: CGFloat
    var weight: CGFloat = 400
    var muted = false
    var strongInk = false
    var tracking: CGFloat = 0
    var lineHeight: CGFloat? = nil
    var alignment: MarkdownAlignment = .left
    var code = false
    var images: [String: NativePlatformImage] = [:]
    var selectionScope: String? = nil
    var openLink: (URL) -> Void
    @Environment(\.nativePerformanceOperation) private var performanceOperation

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = makeTextView(context: performanceOperation)
        view.delegate = context.coordinator
        return view
    }


    func makeTextView(context: UInt64? = nil) -> MarkdownTextView {
        let measurement = NativePerformance.begin(.textCreate, context: context)
        defer { measurement?.end() }
        let storage = NSTextStorage()
        let layout = MarkdownCodeLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.performanceOperation = context
        view.ownedTextStorage = storage
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.isVerticallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        layout.usesFontLeading = false
        view.linkTextAttributes = [.foregroundColor: NativePlatformPalette.thread.accent,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .underlineColor: NativePlatformPalette.thread.accent.withAlphaComponent(0.35)]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        view.performanceOperation = performanceOperation
        context.coordinator.openLink = openLink
        updateTextView(view)
    }


    func updateTextView(_ view: MarkdownTextView) {
        view.setSelectionScope(selectionScope)
        view.setContent(MarkdownTextInput(spans: spans, fontSize: fontSize, weight: weight,
            muted: muted, strongInk: strongInk, tracking: tracking, lineHeight: lineHeight,
            alignment: alignment, code: code, images: images.mapValues(MarkdownTextInput.Image.init)),
            build: { width in attributedString(width: width) })
    }

    static func dismantleNSView(_ view: MarkdownTextView, coordinator: Coordinator) { view.setSelectionScope(nil) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        measuredSize(proposal, view: nsView)
    }

    private func measuredSize(_ proposal: ProposedViewSize, view: MarkdownTextView) -> CGSize {
        let width = max(1, proposal.width ?? NativeGeometry.readingWidth)
        let scale = view.markdownDisplayScale
        let layoutWidth = max(1, floor(width * scale) / scale)
        return CGSize(width: width, height: view.measuredHeight(width: layoutWidth))
    }

    private func attributedString(width: CGFloat) -> NSAttributedString {
        let measurement = NativePerformance.begin(.textAttributed, context: performanceOperation)
        defer { measurement?.end() }
        let output = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight ?? fontSize * (code ? 1.7 : 1.8)
        paragraph.maximumLineHeight = images.isEmpty ? paragraph.minimumLineHeight : 0
        paragraph.lineBreakMode = .byWordWrapping
        if code { paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: NativeMarkdownTypography.code(size: fontSize)]).width * 8 }
        switch alignment { case .left: paragraph.alignment = .left; case .center: paragraph.alignment = .center; case .right: paragraph.alignment = .right }
        for span in spans {
            let size = span.superscript ? fontSize * 0.72 : span.code ? fontSize * 0.88 : fontSize
            // The source stylesheet disables font synthesis. Its bundled Inter
            // family has no italic face, whereas the platform Menlo family does.
            let font = code || span.code ? NativeMarkdownTypography.code(size: size, weight: span.strong ? 700 : weight, italic: span.emphasis)
                : NativeTypography.interPlatformFont(size: size, weight: span.strong ? 700 : weight)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: muted ? NativePlatformPalette.thread.muted : strongInk ? NativePlatformPalette.thread.inkStrong : NativePlatformPalette.thread.ink,
                .paragraphStyle: paragraph,
            ]
            if tracking != 0 { attributes[.kern] = tracking }
            if span.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if span.code { attributes[.nativeMarkdownCode] = true }
            if span.superscript { attributes[.baselineOffset] = fontSize * 0.35 }
            if let url = MarkdownURLPolicy.url(span.link) { attributes[.link] = url }
            if let anchor = span.anchor { attributes[.init("MokuseiMarkdownAnchor")] = anchor }
            if let title = span.title { attributes[.toolTip] = title }
            if let source = span.image, let image = images[source], image.size.width > 0 {
                let attachment = NSTextAttachment()
                let scale = min(1, width / image.size.width, 480 / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let displayedImage = (image.copy() as? NSImage) ?? image
                displayedImage.size = size
                attachment.image = displayedImage
                let cell = NSTextAttachmentCell(imageCell: displayedImage)
                cell.setAccessibilityLabel(span.text)
                attachment.attachmentCell = cell
                attachment.bounds = CGRect(origin: .zero, size: size)
                let imageString = NSMutableAttributedString(attachment: attachment)
                imageString.addAttributes(attributes, range: NSRange(location: 0, length: imageString.length))
                imageString.addAttribute(.accessibilityDescription, value: span.text, range: NSRange(location: 0, length: imageString.length))
                output.append(imageString)
            } else {
                if span.code { output.append(markdownCodePadding(attributes: attributes)) }
                output.append(NSAttributedString(string: span.text, attributes: attributes))
                if span.code { output.append(markdownCodePadding(attributes: attributes)) }
            }
        }
        return output
    }

    final class Coordinator: NSObject, MarkdownPlatformTextDelegate {
        var openLink: (URL) -> Void
        init(openLink: @escaping (URL) -> Void) { self.openLink = openLink }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap({ MarkdownURLPolicy.url($0) }) else { return true }
            if let encodedFragment = url.fragment, url.scheme == nil {
                let fragment = encodedFragment.removingPercentEncoding ?? encodedFragment
                func find(_ view: NSView) -> NSView? {
                    if view.identifier?.rawValue == fragment { return view }
                    for child in view.subviews { if let found = find(child) { return found } }
                    return nil
                }
                if let root = textView.window?.contentView {
                    if let destination = find(root) { destination.scrollToVisible(destination.bounds) }
                    else {
                        func findReference(_ view: NSView) -> Bool {
                            if let text = view as? NSTextView, let storage = text.textStorage {
                                var found: NSRange?
                                storage.enumerateAttribute(.init("MokuseiMarkdownAnchor"), in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                                    if value as? String == fragment { found = range; stop.pointee = true }
                                }
                                if let found { text.scrollRangeToVisible(found); return true }
                            }
                            return view.subviews.contains(where: findReference)
                        }
                        _ = findReference(root)
                    }
                }
                return true
            }
            openLink(url); return true
        }
    }
}

/// Compare source/style before creating native objects. Fresh inline-code
/// attachments are unequal even when their contents are identical, so comparing
/// attributed strings after construction cannot avoid invalidating TextKit.
struct MarkdownTextInput: Equatable {
    let spans: [MarkdownSpan]
    let fontSize: CGFloat
    let weight: CGFloat
    let muted: Bool
    let strongInk: Bool
    let tracking: CGFloat
    let lineHeight: CGFloat?
    let alignment: MarkdownAlignment
    let code: Bool
    let images: [String: Image]

    struct Image: Equatable {
        let identity: ObjectIdentifier
        let size: CGSize
        init(_ image: NativePlatformImage) { identity = ObjectIdentifier(image); size = image.size }
    }
}

final class MarkdownTextView: MarkdownPlatformTextView {
    nonisolated private static let compactDescription =
        ProcessInfo.processInfo.environment["MOKUSEI_TEXT_COMPACT_DESCRIPTION"] != "0"

    nonisolated override var description: String {
        guard Self.compactDescription else { return super.description }
        // SwiftUI's accessibility queries can make AppKit format unsupported-
        // attribute errors while scrolling. The inherited description formats
        // geometry and TextKit state; identify this view without that work.
        let address = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        return "<MarkdownTextView: 0x\(String(address, radix: 16))>"
    }

    var performanceOperation: UInt64?
    var ownedTextStorage: NSTextStorage?
    private var selectionScopeID: String?
    private var selectionScope: MarkdownSelectionScope?

    func setSelectionScope(_ id: String?) {
        guard id != selectionScopeID else { return }
        selectionScope?.unregister(self)
        selectionScopeID = id
        selectionScope = id.map { MarkdownSelectionScope.register(self, id: $0) }
        invalidateSelectionAppearance()
    }

    func selectionScopeOwnsFirstResponder(in window: NSWindow) -> Bool {
        self.window === window && !isHiddenOrHasHiddenAncestor
            && selectionScope?.ownsFirstResponder(in: window) == true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { selectionScope?.invalidateSelectionAppearance() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { selectionScope?.invalidateSelectionAppearance() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        guard let selectionScope, let window, !event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event); return
        }
        window.makeFirstResponder(self)
        selectionScope.begin(self, event: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        var linkTarget: (Any, Int)?
        if let layoutManager, let textContainer {
            let point = NSPoint(x: localPoint.x - textContainerOrigin.x, y: localPoint.y - textContainerOrigin.y)
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            if glyph < layoutManager.numberOfGlyphs,
               layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(point) {
                let index = layoutManager.characterIndexForGlyph(at: glyph)
                if let link = textStorage?.attribute(.link, at: index, effectiveRange: nil) { linkTarget = (link, index) }
            }
        }
        var dragged = false
        var lastDrag: NSEvent?
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        func extend(_ drag: NSEvent) {
            selectionScope.extend(to: drag.locationInWindow)
            var ancestor: NSView? = self
            while let view = ancestor {
                if let scroll = view as? NSScrollView { _ = scroll.autoscroll(with: drag) }
                ancestor = view.superview
            }
        }
        // NSTextView's own tracking loop consumes events before local monitors.
        // Track this document's selection directly while retaining TextKit's
        // word/paragraph boundaries and native selected-range drawing.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseDragged {
                dragged = true; lastDrag = next
                extend(next)
            } else if next.type == .periodic {
                if let lastDrag { extend(lastDrag) }
            } else {
                if dragged { selectionScope.extend(to: next.locationInWindow) }
                break
            }
        }
        selectionScope.end()
        if !dragged, !event.modifierFlags.contains(.shift), event.clickCount == 1, let (link, index) = linkTarget {
            _ = delegate?.textView?(self, clickedOnLink: link, at: index)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) { selectionScope?.clearOtherSelections(keeping: self) }
        super.keyDown(with: event)
    }


    override func selectAll(_ sender: Any?) {
        if let selectionScope { selectionScope.selectAll() } else { super.selectAll(sender) }
    }

    override func copy(_ sender: Any?) {
        if selectionScope?.copy() != true, !copyWithoutCodePadding() { super.copy(sender) }
    }

    var markdownStorage: NSTextStorage? { textStorage }
    var markdownTextContainer: NSTextContainer? { textContainer }
    var markdownLayoutManager: NSLayoutManager? { layoutManager }
    var markdownSelectedRange: NSRange { selectedRange() }
    var markdownString: String { string }
    var markdownDisplayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    var markdownHidden: Bool { isHiddenOrHasHiddenAncestor }
    var markdownHasFocus: Bool { window?.firstResponder === self }
    func setMarkdownSelectedRange(_ range: NSRange) { setSelectedRange(range) }
    func invalidateSelectionAppearance() { needsDisplay = true }
    private func invalidateMarkdownLayout() { needsLayout = true }
    func setDocumentSelectionActive(_ active: Bool) {}
    private func updateDocumentSelectionDisplay() {}

    private var buildText: ((CGFloat) -> NSAttributedString)?
    private var input: MarkdownTextInput?
    private var measuredWidth: CGFloat = -1
    private var measuredSize: CGFloat = 0
    private var measuredScale: CGFloat = 0
    private struct Measurement: Equatable { let width: CGFloat; let scale: CGFloat; let height: CGFloat }
    private var measurements: [Measurement] = []
    private var renderedWidth: CGFloat = -1
    private var content = NSAttributedString(string: "")

    override var intrinsicContentSize: CGSize {
        // SwiftUI supplies the actual proposal through sizeThatFits. Measuring
        // the initial zero-width frame here lays out the whole paragraph at 1pt,
        // then immediately discards that work when the real proposal arrives.
        CGSize(width: Self.noIntrinsicMetric, height: measuredWidth < 0 ? Self.noIntrinsicMetric : measuredSize)
    }

    func setContent(_ next: MarkdownTextInput, build: @escaping (CGFloat) -> NSAttributedString) {
        NativePerformance.event(.textUpdate, context: performanceOperation, values: ["changed": input != next ? 1 : 0])
        guard input != next else { return }
        input = next
        buildText = build
        renderedWidth = -1
        applyText(width: bounds.width > 0 ? bounds.width : NativeGeometry.readingWidth)
    }

    private func applyText(width: CGFloat) {
        // Only image attachments encode the available width in their content.
        // Ordinary text needs a new container layout, never a new attributed string.
        guard renderedWidth < 0 || (input?.images.isEmpty == false && renderedWidth != width),
              let next = buildText?(width) else { return }
        renderedWidth = width
        replaceContent(next)
    }

    /// Diagram labels already arrive as attributed text at their final scale.
    func setAttributedContent(_ next: NSAttributedString) {
        input = nil
        buildText = nil
        replaceContent(next)
    }

    private func replaceContent(_ next: NSAttributedString) {
        if !next.isEqual(to: content) {
            let measurement = NativePerformance.begin(.textReplace, context: performanceOperation,
                values: ["characters": Double(next.length)])
            defer { measurement?.end() }
            let selections = selectedRanges
            content = next
            markdownStorage?.setAttributedString(next)
            let clamped = selections.compactMap { value -> NSValue? in
                let range = value.rangeValue
                guard range.location <= next.length else { return nil }
                return NSValue(range: NSRange(location: range.location, length: min(range.length, next.length - range.location)))
            }
            selectedRanges = clamped
            measuredWidth = -1
            measurements.removeAll(keepingCapacity: true)
            invalidateMarkdownLayout()
            invalidateIntrinsicContentSize()
        }
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let scale = markdownDisplayScale
        let width = max(1, floor(width * scale) / scale)
        applyText(width: width)
        if let cached = measurements.first(where: { $0.width == width && $0.scale == scale }) {
            NativePerformance.event(.textCache, context: performanceOperation, values: ["hit": 1])
            return cached.height
        }
        NativePerformance.event(.textCache, context: performanceOperation, values: ["hit": 0])
        let height = layoutHeight(width: width, scale: scale)
        // A measurement proposal must not leave the displayed text container at
        // an ideal/probe width. SwiftUI need not call layout again when the final
        // frame is unchanged. Restore the real geometry before returning.
        let actual = max(1, floor(bounds.width * scale) / scale)
        if bounds.width > 0, actual != width {
            applyText(width: actual)
            _ = layoutHeight(width: actual, scale: scale)
        }
        return height
    }

    private func layoutHeight(width: CGFloat, scale: CGFloat) -> CGFloat {
        if measuredWidth == width, measuredScale == scale { return measuredSize }
        guard let textContainer = markdownTextContainer, let layoutManager = markdownLayoutManager else { return 0 }
        let measurement = NativePerformance.begin(.textLayout, context: performanceOperation,
            values: ["width": Double(width), "characters": Double(markdownStorage?.length ?? 0)])
        defer { measurement?.end() }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        measuredSize = ceil(layoutManager.usedRect(for: textContainer).height * scale) / scale
        measuredWidth = width; measuredScale = scale
        if !measurements.contains(where: { $0.width == width && $0.scale == scale }) {
            if measurements.count == 8 { measurements.removeFirst() }
            measurements.append(Measurement(width: width, scale: scale, height: measuredSize))
        }
        return measuredSize
    }

    override func layout() { super.layout(); layoutMarkdown() }

    private func layoutMarkdown() {
        if bounds.width > 0 {
            let scale = markdownDisplayScale
            let width = max(1, floor(bounds.width * scale) / scale)
            applyText(width: width)
            _ = layoutHeight(width: width, scale: scale)
            updateDocumentSelectionDisplay()
        }
    }

    // The conversation owns vertical scrolling; selecting text must not create
    // an independently scrolling text view or resize its enclosing message.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

private extension NSAttributedString.Key {
    static let accessibilityDescription = NSAttributedString.Key("NSAccessibilityDescription")
}
