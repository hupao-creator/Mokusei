import AppKit
import MokuseiCore
import SwiftUI

/// Shared metrics for the composer attachment strip. Every radius is derived
/// from the host container so the chips stay concentric with whichever input
/// surface mounts them (the 15pt full composer or Moku's 29pt capsule).
enum NativeComposerChipMetrics {
    /// Chip inset from the host edge. The strip uses the same value for its
    /// leading and trailing padding, so every chip starts on this rhythm.
    static let containerInset: CGFloat = 12
    static let topInset: CGFloat = 9
    /// Keeps the chip off the editor row instead of fusing with the placeholder.
    static let bottomInset: CGFloat = 6
    static let spacing: CGFloat = 6
    static let height: CGFloat = 28
    static let contentSpacing: CGFloat = 6
    static let leadingInset: CGFloat = 8
    /// The close button is 22pt wide; a 4pt trailing inset balances its center
    /// against the 8pt icon inset at the leading edge.
    static let trailingInset: CGFloat = 4
    static let iconSize: CGFloat = 13
    static let nameFontSize: CGFloat = 10.5
    static let sizeFontSize: CGFloat = 9.5
    /// Larger than the old 17pt glyph box so the close target stays usable
    /// inside the 28pt chip; the icon itself remains 10pt.
    static let removeButtonSize: CGFloat = 22
    static let maximumWidth: CGFloat = 210
    static let minimumWidth: CGFloat = 96
    /// Image previews use a square footprint so a pasted picture is recognisable
    /// without expanding the strip to a media gallery.
    static let imageSize: CGFloat = 56

    /// Concentric radius: a chip `containerInset` from the host edge needs
    /// `containerRadius - containerInset` to follow the host corner. A chip is
    /// shorter than that arc, and a rounded rectangle cannot express a radius
    /// larger than half its height, so the result is capped there. Moku's 29pt
    /// capsule derives 17pt, drawn as a 14pt capsule.
    static func radius(containerRadius: CGFloat) -> CGFloat {
        min(max(0, containerRadius - containerInset), height / 2)
    }

    /// A 56pt square must not become a circle inside Moku's 29pt capsule, so the
    /// concentric derivation is capped at 14pt. The 8pt floor keeps the preview
    /// a rounded square inside the full composer's 15pt container.
    static func imageRadius(containerRadius: CGFloat) -> CGFloat {
        min(14, max(8, containerRadius - containerInset))
    }
}

/// Shared horizontal draft strip for the full composer and overview Dock.
public struct NativeComposerAttachmentChips: View {
    private let attachments: [NativeComposerAttachment]
    private let directories: [NativeComposerDirectory]
    private let containerRadius: CGFloat
    private let onRemove: (JSONText) -> Void
    private let onRemoveDirectory: ((JSONText) -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var availableWidth: CGFloat = 0

    /// `containerRadius` is the host's clip radius, used to derive each chip's
    /// concentric radius. Pass the same value the surrounding input uses.
    public init(attachments: [NativeComposerAttachment], directories: [NativeComposerDirectory] = [],
                containerRadius: CGFloat,
                onRemove: @escaping (JSONText) -> Void, onRemoveDirectory: ((JSONText) -> Void)? = nil) {
        self.attachments = attachments; self.directories = directories
        self.containerRadius = containerRadius
        self.onRemove = onRemove; self.onRemoveDirectory = onRemoveDirectory
    }

    public var body: some View {
        if !attachments.isEmpty || !directories.isEmpty {
            NativeScrollView(.horizontal) {
                HStack(spacing: NativeComposerChipMetrics.spacing) {
                    ForEach(directories) { directory in
                        chip(name: directory.name.string, icon: "Folder", size: nil, pending: false, failed: false,
                             help: directory.path.string, remove: onRemoveDirectory.map { action in { action(directory.path) } },
                             removeLabel: composerLocalized("移除目录", locale: locale))
                    }
                    ForEach(attachments) { draft in
                        attachment(draft)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                // A pending chip can change its status (and therefore its
                // 28pt → 56pt height) once staging resolves; animate the
                // swap instead of hard-jumping when a type was guessed late.
                .animation(.easeInOut(duration: 0.18), value: attachments.map(\.status))
            }
            // A horizontal indicator sits directly under the chips and reads as
            // part of the composer. Clipped content already signals scrolling.
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            // The scroll view is already inset by the padding below, so this is
            // the width available to a single chip.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .padding(.init(top: NativeComposerChipMetrics.topInset, leading: NativeComposerChipMetrics.containerInset,
                           bottom: NativeComposerChipMetrics.bottomInset, trailing: NativeComposerChipMetrics.containerInset))
            .accessibilityLabel(composerLocalized("Moku 附件", locale: locale))
        }
    }

    @ViewBuilder private func attachment(_ draft: NativeComposerAttachment) -> some View {
        let removeLabel = composerLocalized("移除附件", locale: locale)
        switch draft.status {
        case .ready(let value) where value.kind == .image:
            NativeComposerImageChip(attachment: draft, containerRadius: containerRadius,
                onRemove: { onRemove(draft.id) }, removeLabel: removeLabel)
        case .ready(let value):
            chip(name: draft.name.string, icon: value.kind == .document ? "FileText" : "Paperclip",
                 size: value.size, pending: false, failed: false, help: value.path.string,
                 remove: { onRemove(draft.id) }, removeLabel: removeLabel)
        case .pending(_, let mimeType) where mimeType.hasPrefix("image/"):
            // Staging keeps the square footprint and shows the image glyph
            // immediately; the decoded thumbnail replaces it in place.
            NativeComposerImageChip(attachment: draft, containerRadius: containerRadius,
                onRemove: { onRemove(draft.id) }, removeLabel: removeLabel)
        case .pending(let size, _):
            chip(name: draft.name.string, icon: "Paperclip", size: size, pending: true, failed: false, help: "",
                 remove: { onRemove(draft.id) }, removeLabel: removeLabel)
        case .failed(let error):
            chip(name: draft.name.string, icon: "Paperclip", size: nil, pending: false, failed: true, help: composerLocalized(error, locale: locale),
                 remove: { onRemove(draft.id) }, removeLabel: removeLabel)
        }
    }

    private var maximumWidth: CGFloat {
        guard availableWidth > 0 else { return NativeComposerChipMetrics.maximumWidth }
        return max(NativeComposerChipMetrics.minimumWidth,
                   min(NativeComposerChipMetrics.maximumWidth, availableWidth))
    }

    private func chip(name: String, icon: String, size: Int?, pending: Bool, failed: Bool,
                      help: String, remove: (() -> Void)?, removeLabel: String) -> some View {
        HStack(spacing: NativeComposerChipMetrics.contentSpacing) {
            NativeIcon(name: icon, size: NativeComposerChipMetrics.iconSize, strokeWidth: 1.6)
                .foregroundStyle(failed ? NativePlatformPalette.thread.danger.swiftUI
                                        : Color.primary.opacity(0.68))
                .frame(width: NativeComposerChipMetrics.iconSize)
                .fixedSize()
            // Name and metadata share a baseline; the icon and close button are
            // centered on the chip's 28pt row.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name)
                    .font(NativeTypography.inter(size: NativeComposerChipMetrics.nameFontSize, weight: 500))
                    .foregroundStyle(failed ? NativePlatformPalette.thread.danger.swiftUI : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                if let size {
                    Text(Self.formatBytes(size))
                        .font(NativeTypography.inter(size: NativeComposerChipMetrics.sizeFontSize, weight: 500))
                        .foregroundStyle(failed ? NativePlatformPalette.thread.danger.swiftUI.opacity(0.8)
                                                : Color.primary.opacity(0.62))
                        .fixedSize()
                        .layoutPriority(2)
                }
                if pending {
                    Text(composerLocalized("暂存中…", locale: locale))
                        .font(NativeTypography.inter(size: NativeComposerChipMetrics.sizeFontSize, weight: 500))
                        .italic().lineLimit(1).fixedSize().layoutPriority(2)
                }
            }
            if let remove {
                Button(action: remove) {
                    NativeIcon(name: "X", size: 10)
                        .frame(width: NativeComposerChipMetrics.removeButtonSize,
                               height: NativeComposerChipMetrics.removeButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ComposerButtonStyle(kind: .remove)).help(removeLabel)
                .accessibilityLabel("\(removeLabel): \(name)")
            }
        }
        .padding(.leading, NativeComposerChipMetrics.leadingInset)
        .padding(.trailing, NativeComposerChipMetrics.trailingInset)
        .frame(height: NativeComposerChipMetrics.height)
        .frame(maxWidth: maximumWidth)
        .modifier(NativeComposerChipSurface(
            cornerRadius: NativeComposerChipMetrics.radius(containerRadius: containerRadius),
            failed: failed, pending: pending, opaque: reduceTransparency))
        .help(help)
    }

    public static func formatBytes(_ size: Int) -> String {
        if size >= 1024 * 1024 { return String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), Double(size) / Double(1024 * 1024)) }
        if size >= 1024 { return "\(Int((Double(size) / 1024).rounded())) KB" }
        return "\(size) B"
    }
}

/// A shape-bound tint above the host surface. Nested Liquid Glass adds its own
/// shadow, which the tight horizontal scroll viewport cuts into rectangular
/// bands around the chips. Keep the host's glass and draw only the chip fill
/// and border here.
private struct NativeComposerChipSurface: ViewModifier {
    let cornerRadius: CGFloat
    let failed: Bool
    let pending: Bool
    let opaque: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }
    private var borderStyle: StrokeStyle { StrokeStyle(lineWidth: 1, dash: pending ? [3, 2] : []) }
    private var border: Color {
        if failed { return NativePlatformPalette.thread.danger.swiftUI.opacity(0.35) }
        if pending { return Color.primary.opacity(0.18) }
        return opaque ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06)
    }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(failed
                ? NativePlatformPalette.thread.danger.swiftUI.opacity(0.10)
                : Color.primary.opacity(0.06)))
            .overlay(shape.strokeBorder(border, style: borderStyle))
    }
}
