import MokuseiCore
import SwiftUI

public struct ThreadActivityRow: View {
    public let id: JSONText
    public let state: AnyView
    public let icon: AnyView?
    public let label: AnyView
    public let detail: AnyView?
    @State private var expanded = false
    @Environment(\.locale) private var locale
    public init(id: JSONText, state: AnyView, icon: AnyView? = nil,
                label: AnyView, detail: AnyView? = nil) {
        self.id = id
        self.state = state
        self.icon = icon
        self.label = label
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    state.frame(width: 20)
                    if let icon { icon }
                    label.lineLimit(1).truncationMode(.tail)
                    if detail != nil {
                        NativeIcon(name: expanded ? "ChevronDown" : "ChevronRight", size: 13)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(ThreadActivityButtonStyle())
            .nativeReadingAction("activity." + nativeReadingInteractionKey(id), role: "activity", label: "Activity detail",
                value: .bool(expanded), enabled: detail != nil, action: toggle)
            .accessibilityValue(detail == nil ? "" : NativePluginLocalization.localize(
                expanded ? "已展开" : "已收起", locale: locale))
            if expanded, let detail {
                ThreadActivityDetail(content: detail)
                    .padding(.leading, 21)
                    .padding(.top, 5)
                    .padding(.bottom, 10)
            }
        }
        .font(NativeTypography.inter(size: 11))
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
        .padding(.bottom, 7)
        .accessibilityElement(children: .contain)
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .id(id)
    }
    private func toggle() { if detail != nil { expanded.toggle() } }
}

private struct ThreadActivityDetail: View {
    let content: AnyView
    @State private var contentHeight: CGFloat = 220

    var body: some View {
        ScrollView(.vertical) {
            content
                .font(NativeTypography.mono(size: 11))
                .lineSpacing(6.6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(220, contentHeight))
        .background(NativePalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 4))
    }
}

public struct ThreadActivitySlot: Identifiable {
    public let id: JSONText
    public let node: AnyView
    public let running: Bool

    public init(id: JSONText, node: AnyView, running: Bool = false) {
        self.id = id
        self.node = node
        self.running = running
    }
}

/// Disclosure owns opaque activity rows. An explicit expansion displays the
/// complete group; collapsed execution bodies are supplied by a scoped loader.
public struct HarnessToolActivityGroup: View {
    public let groupID: JSONText
    public let items: [ThreadActivitySlot]
    public let summary: AnyView
    public let summaryLabel: String
    public let summaryState: AnyView
    public let alwaysGroup: Bool
    public var expandedContent: AnyView?

    @State private var expanded: Bool
    @FocusState private var summaryFocused: Bool
    @Environment(\.locale) private var locale
    public init(groupID: JSONText, items: [ThreadActivitySlot], summary: AnyView,
                summaryLabel: String, summaryState: AnyView,
                defaultExpanded: Bool = false, alwaysGroup: Bool = false, expandedContent: AnyView? = nil) {
        self.groupID = groupID
        self.items = items
        self.summary = summary
        self.summaryLabel = summaryLabel
        self.summaryState = summaryState
        self.alwaysGroup = alwaysGroup
        self.expandedContent = expandedContent
        _expanded = State(initialValue: defaultExpanded)
    }

    public var body: some View {
        Group {
            if items.count == 1, !alwaysGroup {
                items[0].node
            } else if !items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: toggle) {
                        HStack(spacing: 7) {
                            summaryState.frame(width: 20)
                            summary.frame(maxWidth: .infinity, alignment: .leading)
                            NativeIcon(name: expanded ? "ChevronDown" : "ChevronRight", size: 13)
                        }
                        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ThreadActivityButtonStyle())
                    .focused($summaryFocused)
                    .accessibilityLabel(summaryLabel)
                    .accessibilityValue(NativePluginLocalization.localize(
                        expanded ? "已展开" : "已收起", locale: locale))
                    .help(summaryLabel)
                    .nativeReadingAction("group." + nativeReadingInteractionKey(groupID), role: "execution.group", label: summaryLabel,
                        value: .bool(expanded), action: toggle)
                    if expanded {
                        VStack(alignment: .leading, spacing: 0) {
                            if let expandedContent { expandedContent }
                            else { ThreadActivityList(items: items) }
                        }
                        .nativeReadingScope("group." + nativeReadingInteractionKey(groupID))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                        .overlay(alignment: .top) {
                            Rectangle().fill(NativePalette.thread.lineSoft.swiftUI).frame(height: 1)
                        }
                        .padding(.top, 6)
                    } else if items.contains(where: \.running) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(items.filter(\.running)) { $0.node }
                        }.padding(.top, 2)
                    }
                }
                .font(NativeTypography.inter(size: 11))
                .foregroundStyle(NativePalette.thread.muted.swiftUI)
                .accessibilityElement(children: .contain)
            }
        }
        .id(groupID)
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }

    private func toggle() {
        expanded.toggle()
        summaryFocused = true
    }
}

/// Full execution content appears together after the reader opens its group.
public struct ThreadActivityList: View {
    public let items: [ThreadActivitySlot]
    public let spacing: CGFloat
    public init(items: [ThreadActivitySlot], spacing: CGFloat = 0) { self.items = items; self.spacing = spacing }
    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(items) { item in item.node.nativeReadingScope("item." + nativeReadingInteractionKey(item.id)) }
        }
    }
}

public struct ThreadSurfacePlan<Content: View>: View {
    public let explanation: String?
    public let label: String
    public let completed: Int
    public let total: Int
    private let content: Content
    @Environment(\.locale) private var locale
    public init(explanation: String? = nil, label: String = "计划", completed: Int,
                total: Int, @ViewBuilder content: () -> Content) {
        self.explanation = explanation
        self.label = label
        self.completed = completed
        self.total = total
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ThreadPlanGlyph().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14).accessibilityHidden(true)
                Text(NativePluginLocalization.localize(label, locale: locale))
                    .font(NativeTypography.inter(size: 11, weight: 500))
                Spacer(minLength: 0)
                Text("\(completed)/\(total)").font(NativeTypography.inter(size: 10))
            }
            if let explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(NativeTypography.inter(size: 12))
                    .lineSpacing(7.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 9) { content }.padding(.top, 12)
        }
        .font(NativeTypography.inter(size: 12))
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
        .padding(.vertical, 5)
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Rectangle().fill(NativePalette.thread.line.swiftUI).frame(width: 1)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NativePluginLocalization.localize("计划", locale: locale))
    }
}

public struct ThreadSurfacePlanRow<Content: View>: View {
    public let state: AnyView
    public let inProgress: Bool
    private let content: Content

    public init(state: AnyView, inProgress: Bool = false, @ViewBuilder content: () -> Content) {
        self.state = state
        self.inProgress = inProgress
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 8) {
            state.frame(width: 12, height: 12).accessibilityHidden(true)
            content.fixedSize(horizontal: false, vertical: true)
        }
        .font(NativeTypography.inter(size: 12))
        .foregroundStyle((inProgress ? NativePalette.thread.ink : NativePalette.thread.muted).swiftUI)
    }
}

public struct ThreadSurfaceDisclosure<Content: View>: View {
    public let label: String
    public let live: Bool
    private let content: () -> Content
    @State private var expanded: Bool
    @Environment(\.locale) private var locale
    public init(label: String, live: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.live = live
        self.content = content
        _expanded = State(initialValue: live)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    ThreadTraceGlyph().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14).accessibilityHidden(true)
                    Text(label)
                    Spacer(minLength: 0)
                    NativeIcon(name: "ChevronRight", size: 13).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ThreadActivityButtonStyle())
            .accessibilityValue(NativePluginLocalization.localize(expanded ? "已展开" : "已收起", locale: locale))
            .nativeReadingAction("disclosure", role: "disclosure", label: label, value: .bool(expanded), action: toggle)
            if expanded {
                content()
                    .font(NativeTypography.inter(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(NativePalette.thread.line.swiftUI).frame(width: 1)
                    }
                    .padding(.top, 8)
            }
        }
        .font(NativeTypography.inter(size: 11))
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .onChange(of: live) { _, value in expanded = value }
    }
    private func toggle() { expanded.toggle() }
}

private struct ThreadActivityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThreadActivityButtonBody(configuration: configuration)
    }
}

private struct ThreadActivityButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .foregroundStyle((hovered || configuration.isPressed
                              ? NativePalette.thread.ink : NativePalette.thread.muted).swiftUI)
            .background(hovered || configuration.isPressed ? NativePalette.thread.surfaceSoft.swiftUI : .clear)
            .onHover { hovered = $0 }
    }
}

private struct ThreadPlanGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for y in [4.0, 8.0, 12.0] {
            path.move(to: CGPoint(x: 6.25, y: y)); path.addLine(to: CGPoint(x: 12.25, y: y))
            path.move(to: CGPoint(x: 2.6, y: y)); path.addLine(to: CGPoint(x: 3.6, y: y + 1))
            path.addLine(to: CGPoint(x: 5.3, y: y - 1))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}

private struct ThreadTraceGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2.5, y: 11.5))
        path.addCurve(to: CGPoint(x: 6.1, y: 4.5), control1: CGPoint(x: 4.2, y: 11.5), control2: CGPoint(x: 4.2, y: 4.5))
        path.addCurve(to: CGPoint(x: 9.8, y: 11.5), control1: CGPoint(x: 8, y: 4.5), control2: CGPoint(x: 7.9, y: 11.5))
        path.addCurve(to: CGPoint(x: 13.5, y: 6.5), control1: CGPoint(x: 11.7, y: 11.5), control2: CGPoint(x: 11.6, y: 6.5))
        path.addEllipse(in: CGRect(x: 1.8, y: 10.8, width: 1.4, height: 1.4))
        path.addEllipse(in: CGRect(x: 12.8, y: 5.8, width: 1.4, height: 1.4))
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}
