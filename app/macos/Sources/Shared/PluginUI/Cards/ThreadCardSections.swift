import SwiftUI
import MokuseiCore

/// The native equivalent of the renderer's checkpoint window.
public func threadCardPlanWindow(_ variant: ThreadCardVariantId) -> (before: Int, after: Int) {
    variant == .tall ? (2, 5) : (1, 2)
}

public struct CardPlanLadder: View {
    public let steps: [ThreadCardPlanStep]
    public let variant: ThreadCardVariantId
    @Environment(\.locale) private var locale
    @Namespace private var lens

    public init(steps: [ThreadCardPlanStep], variant: ThreadCardVariantId) {
        self.steps = steps; self.variant = variant
    }

    public var body: some View {
        if !steps.isEmpty {
            let current = steps.firstIndex { $0.status == .inProgress }
                ?? steps.firstIndex { $0.status == .pending } ?? (steps.count - 1)
            let window = threadCardPlanWindow(variant)
            GeometryReader { geometry in
                let rowsHeight = max(0, geometry.size.height - CardPlanGeometry.headerHeight - CardPlanGeometry.headerGap)
                let capacity = max(1, Int((rowsHeight + CardPlanGeometry.rowGap) / (CardPlanGeometry.rowHeight + CardPlanGeometry.rowGap)))
                let count = min(steps.count, min(window.before + window.after + 1, capacity))
                let before = min(window.before, count - 1)
                let start = max(0, min(current - before, steps.count - count))
                let end = start + count
                VStack(alignment: .leading, spacing: CardPlanGeometry.headerGap) {
                    HStack {
                        Text(sectionText(locale, "执行计划", "Plan"))
                        Spacer(minLength: 12)
                        Text("\(steps.filter { $0.status == .completed }.count) / \(steps.count) \(sectionText(locale, "完成", "complete"))")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(NativeTypography.inter(size: 10, weight: 500))
                    .foregroundStyle(NativePalette.overview.muted.swiftUI)
                    .lineLimit(1)
                    .frame(height: CardPlanGeometry.headerHeight)
                    .padding(.horizontal, CardPlanGeometry.rowInset)
                    GlassEffectContainer(spacing: CardPlanGeometry.rowGap) {
                        VStack(alignment: .leading, spacing: CardPlanGeometry.rowGap) {
                            ForEach(start..<end, id: \.self) { index in
                                CardPlanRow(step: steps[index], number: index + 1,
                                            connectsAfter: index < end - 1, lens: lens,
                                            lensID: index == current ? "current-step" : "step-\(index)")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(.smooth(duration: 0.4), value: steps.map(\.status))
            }
        }
    }
}

private enum CardPlanGeometry {
    static let headerHeight: CGFloat = 12
    static let headerGap: CGFloat = 9
    static let rowHeight: CGFloat = 40
    static let rowGap: CGFloat = 5
    static let rowInset: CGFloat = 10
    static let markerSize: CGFloat = 24
    static let cornerRadius: CGFloat = 15
}

private struct CardPlanRow: View {
    let step: ThreadCardPlanStep
    let number: Int
    let connectsAfter: Bool
    let lens: Namespace.ID
    let lensID: String
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let palette = NativePalette.overview

    private var textOpacity: Double {
        switch step.status { case .completed: 0.48; case .pending: 0.62; case .inProgress: 0.92 }
    }

    var body: some View {
        surface
            .background(alignment: .bottomLeading) {
                if connectsAfter {
                    Rectangle()
                        .fill(step.status == .completed ? palette.accent.swiftUI.opacity(0.25) : palette.ink.swiftUI.opacity(0.12))
                        .frame(width: 1, height: 8)
                        .offset(x: CardPlanGeometry.rowInset + CardPlanGeometry.markerSize / 2 - 0.5, y: 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(statusLabel)
    }

    @ViewBuilder private var surface: some View {
        if step.status == .inProgress {
            if reduceTransparency {
                content.background(palette.surfaceStrong.swiftUI, in: .rect(cornerRadius: CardPlanGeometry.cornerRadius))
            } else {
                content
                    .glassEffect(.regular.tint(palette.accent.swiftUI.opacity(0.08)), in: .rect(cornerRadius: CardPlanGeometry.cornerRadius))
                    .glassEffectID(lensID, in: lens)
            }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(step.status == .inProgress ? palette.accent.swiftUI : palette.ink.swiftUI.opacity(step.status == .completed ? 0.06 : 0.035))
                switch step.status {
                case .completed:
                    NativeIcon(name: "Check", size: 10, strokeWidth: 2.5)
                        .foregroundStyle(palette.accent.swiftUI)
                case .inProgress:
                    Text("\(number)").foregroundStyle(palette.surface.swiftUI)
                case .pending:
                    Text("\(number)").foregroundStyle(palette.muted.swiftUI)
                }
            }
            .font(NativeTypography.inter(size: 11, weight: 620))
            .monospacedDigit()
            .frame(width: CardPlanGeometry.markerSize, height: CardPlanGeometry.markerSize)
            .accessibilityHidden(true)
            Text(step.step)
                .font(NativeTypography.inter(size: 12, weight: step.status == .inProgress ? 620 : 500))
                .foregroundStyle(palette.ink.swiftUI.opacity(textOpacity))
                .lineLimit(2)
                .help(step.step)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, CardPlanGeometry.rowInset)
        .frame(height: CardPlanGeometry.rowHeight)
    }

    private var statusLabel: String {
        switch step.status {
        case .pending: sectionText(locale, "待执行", "Pending")
        case .inProgress: sectionText(locale, "进行中", "In progress")
        case .completed: sectionText(locale, "完成", "Completed")
        }
    }
}

public struct CardDerivedWork: View {
    public let rows: [ThreadCardDerivedRow]
    public let variant: ThreadCardVariantId
    public let capacity: Int

    public init(rows: [ThreadCardDerivedRow], variant: ThreadCardVariantId, capacity: Int) {
        self.rows = rows; self.variant = variant; self.capacity = capacity
    }

    public var body: some View {
        if !rows.isEmpty {
            let visible = Array(rows.prefix(max(0, capacity)))
            VStack(alignment: .leading, spacing: 0) {
                if variant == .wide {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                        derivedRows(visible)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) { derivedRows(visible) }
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 5)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NativePalette.overview.ink.swiftUI.opacity(0.045))
            .overlay(alignment: .bottom) {
                if visible.contains(where: { $0.status == .running }) { CardDerivedScan() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func derivedRows(_ visible: [ThreadCardDerivedRow]) -> some View {
        ForEach(visible) { CardDerivedRowView(row: $0) }
        if rows.count > visible.count { CardSectionOverflow(count: rows.count - visible.count) }
    }
}

private struct CardDerivedRowView: View {
    let row: ThreadCardDerivedRow
    @Environment(\.locale) private var locale
    private let palette = NativePalette.overview
    private var finished: Bool { row.status == .completed || row.status == .cancelled }
    private var secondaryColor: Color {
        row.status == .failed ? palette.danger.swiftUI : palette.ink.swiftUI.opacity(finished ? 0.38 : 0.46)
    }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch row.kind {
                case .shell: Text("$").font(NativeTypography.mono(size: 10.5, weight: 700))
                case .agent: NativeIcon(name: "Bot", size: 11, strokeWidth: 2)
                case .task: NativeIcon(name: "Hourglass", size: 11, strokeWidth: 2)
                }
            }
            .foregroundStyle(row.status == .failed ? palette.danger.swiftUI : palette.ink.swiftUI.opacity(finished ? 0.38 : 0.34))
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            Group {
                if row.commandLine { Text(cardCommandText(row.label, finished: finished)).tracking(-0.132) }
                else {
                    Text(row.label).font(NativeTypography.inter(size: 11, weight: 560))
                        .foregroundStyle(palette.ink.swiftUI.opacity(finished ? 0.38 : 0.78))
                }
            }
            .lineLimit(1)
            .help(row.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.status != .running || !row.commandLine {
                Text(statusLabel).font(NativeTypography.inter(size: 9.5, weight: 640))
                    .foregroundStyle(secondaryColor).fixedSize()
            }
        }
        .frame(minHeight: 21)
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: String {
        switch row.status {
        case .completed: sectionText(locale, "完成", "Completed")
        case .failed: sectionText(locale, "失败", "Failed")
        case .cancelled: sectionText(locale, "已取消", "Cancelled")
        case .running:
            switch row.kind {
            case .shell: "shell"
            case .agent: sectionText(locale, "子 Agent", "Sub-agent")
            case .task: sectionText(locale, "任务", "Task")
            }
        }
    }
}

private struct CardDerivedScan: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility
    private var animates: Bool { scenePhase != .background && !reduceMotion && enabled && (visibility?.isVisible ?? true) }

    var body: some View {
        TimelineView(.animation(minimumInterval: NativeFrameRate.interval, paused: !animates)) { context in
            GeometryReader { geometry in
                let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.4) / 3.4
                LinearGradient(colors: [.clear, NativePalette.overview.ink.swiftUI.opacity(0.3), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * 0.34)
                    .offset(x: geometry.size.width * (progress * 1.34 - 0.34))
            }
        }
        .frame(height: 1.5)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct CardSectionOverflow: View {
    let count: Int
    var body: some View {
        Text("+\(count)")
            .font(NativeTypography.inter(size: 9.5, weight: 650))
            .foregroundStyle(NativePalette.overview.ink.swiftUI.opacity(0.44))
    }
}

/// Stateless boundary: a new authoritative interaction ID starts a new answer
/// session, while updates to the same pending interaction preserve its local lock.
public struct CardInterventionPanel: View {
    public let intervention: ThreadCardIntervention
    public let variant: ThreadCardVariantId
    public var onRespond: ThreadCardInterventionHandler?
    public var onOpenThread: (() -> Void)?
    public var details: AnyView?
    public var actionLabel: ((ThreadCardDecisionAction) -> String)?

    public init(intervention: ThreadCardIntervention, variant: ThreadCardVariantId,
                onRespond: ThreadCardInterventionHandler? = nil, onOpenThread: (() -> Void)? = nil,
                details: AnyView? = nil, actionLabel: ((ThreadCardDecisionAction) -> String)? = nil) {
        self.intervention = intervention; self.variant = variant; self.onRespond = onRespond
        self.onOpenThread = onOpenThread; self.details = details; self.actionLabel = actionLabel
    }

    public var body: some View {
        CardInterventionSession(intervention: intervention, variant: variant, onRespond: onRespond,
                                onOpenThread: onOpenThread, details: details, actionLabel: actionLabel)
            .id(intervention.id)
    }
}

private struct CardInterventionSession: View {
    let intervention: ThreadCardIntervention
    let variant: ThreadCardVariantId
    let onRespond: ThreadCardInterventionHandler?
    let onOpenThread: (() -> Void)?
    let details: AnyView?
    let actionLabel: ((ThreadCardDecisionAction) -> String)?
    @Environment(\.locale) private var locale
    @State private var step = 0
    @State private var responding = false
    @State private var responseError: String?
    @State private var answers = CardInteractionAnswers()
    @State private var detailsOpen = false
    private let palette = NativePalette.overview
    private var questions: [ThreadCardQuestion] { intervention.questions }
    private var currentIndex: Int { min(step, max(0, questions.count - 1)) }
    private var current: ThreadCardQuestion? { questions.isEmpty ? nil : questions[currentIndex] }
    private var currentAnswered: Bool { current.map { !answers.answer(for: $0).isEmpty } ?? true }
    private var lastStep: Bool { currentIndex >= questions.count - 1 }

    var body: some View {
        Group {
            if variant == .wide {
                HStack(alignment: .center, spacing: 28) {
                    content.frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize(horizontal: true, vertical: false)
                }
            } else {
                VStack(alignment: .leading, spacing: questions.isEmpty ? 6 : 12) {
                    content
                    actions.padding(.top, questions.isEmpty ? 16 : 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: variant == .tall && !questions.isEmpty ? .leading : .topLeading)
        .overlay(alignment: .topTrailing) {
            if questions.count > 1 {
                Text("\(currentIndex + 1) / \(questions.count)")
                    .font(NativeTypography.inter(size: 10.5, weight: 560))
                    .foregroundStyle(palette.ink.swiftUI.opacity(0.34))
                    .monospacedDigit()
                    .allowsHitTesting(false)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: questions.isEmpty ? 6 : 12) {
            if questions.isEmpty {
                Text(intervention.title)
                    .font(NativeTypography.inter(size: 14.5, weight: 660)).tracking(-0.174)
                    .foregroundStyle(palette.ink.swiftUI).lineLimit(1)
                if let detail = intervention.detail, !detail.isEmpty {
                    Text(detail).font(NativeTypography.inter(size: 12))
                        .foregroundStyle(palette.ink.swiftUI.opacity(0.56)).lineLimit(2).lineSpacing(2)
                }
            }
            if let details {
                DisclosureGroup(isExpanded: $detailsOpen) { details } label: {
                    Text(sectionText(locale, "请求详情", "Request details"))
                }
                .font(NativeTypography.inter(size: 10)).foregroundStyle(palette.muted.swiftUI)
            }
            if let current {
                CardQuestionField(question: current, answers: $answers, disabled: responding)
                    .id(current.id)
            }
            if let responseError {
                Text(responseError).font(NativeTypography.inter(size: 10.5))
                    .foregroundStyle(palette.danger.swiftUI)
                    .accessibilityLabel(responseError)
            }
        }
    }

    private var actions: some View {
        CardActionFlow(spacing: 6) {
            if !questions.isEmpty {
                if lastStep {
                    ForEach(Array(intervention.actions.enumerated()), id: \.element.id) { index, action in
                        actionButton(action, primary: index == 0,
                                     disabled: responding || (action.id == intervention.submitActionId && !currentAnswered))
                    }
                } else {
                    Button(sectionText(locale, "下一步", "Next")) { step = currentIndex + 1 }
                        .buttonStyle(CardInterventionButtonStyle(question: true, primary: true))
                        .disabled(responding || !currentAnswered)
                }
                if let skip = intervention.skipAction { actionButton(skip, primary: false, disabled: responding, skip: true) }
                if currentIndex > 0 {
                    Button(sectionText(locale, "上一步", "Previous")) { step = max(0, currentIndex - 1) }
                        .buttonStyle(CardInterventionButtonStyle(question: true, primary: false)).disabled(responding)
                }
            } else if !intervention.actions.isEmpty {
                ForEach(Array(intervention.actions.enumerated()), id: \.element.id) { index, action in
                    actionButton(action, primary: index == 0, disabled: responding)
                }
            } else {
                Button(sectionText(locale, "在 thread 中处理", "Handle in thread")) { onOpenThread?() }
                    .buttonStyle(CardInterventionButtonStyle(question: false, primary: true))
            }
        }
    }

    private func actionButton(_ action: ThreadCardDecisionAction, primary: Bool, disabled: Bool, skip: Bool = false) -> some View {
        Button(skip ? action.label : (actionLabel?(action) ?? action.label)) { respond(action.id, skip: skip) }
            .buttonStyle(CardInterventionButtonStyle(question: !questions.isEmpty, primary: primary))
            .disabled(disabled)
    }

    private func respond(_ actionID: JSONText, skip: Bool) {
        guard !responding, let onRespond else { return }
        // Lock synchronously before creating the task, closing the double-click window.
        responding = true
        responseError = nil
        let submittedAnswers: [JSONText: ThreadCardAnswer]? = !questions.isEmpty && (skip || actionID == intervention.submitActionId)
            ? (skip ? [:] : answers.answers(for: questions)) : nil
        let response = ThreadCardInterventionResponse(actionId: actionID, answers: submittedAnswers)
        Task { @MainActor in
            do {
                try await onRespond(response)
                // Authority removes the intervention; successful local state stays locked.
            } catch {
                responseError = error.localizedDescription
                responding = false
            }
        }
    }
}

private struct CardInteractionAnswers {
    var picked: [JSONText: [JSONText]] = [:]
    var other: [JSONText: String] = [:]

    func answer(for question: ThreadCardQuestion) -> [JSONText] {
        let raw = other[question.id] ?? ""
        let custom = question.secret ? raw : cardTrimAnswer(raw)
        let chosen = picked[question.id] ?? []
        guard !custom.isEmpty else { return chosen }
        return question.multiple ? chosen + [JSONText(custom)] : [JSONText(custom)]
    }

    mutating func toggle(_ value: JSONText, for question: ThreadCardQuestion) {
        if !question.multiple { other.removeValue(forKey: question.id); picked[question.id] = [value]; return }
        let selected = picked[question.id] ?? []
        picked[question.id] = selected.contains(value) ? selected.filter { $0 != value } : selected + [value]
    }

    mutating func openOther(for question: ThreadCardQuestion) {
        other[question.id] = ""
        if !question.multiple { picked[question.id] = [] }
    }

    func answers(for questions: [ThreadCardQuestion]) -> [JSONText: ThreadCardAnswer] {
        var result: [JSONText: ThreadCardAnswer] = [:]
        for question in questions {
            let values = answer(for: question)
            if let first = values.first { result[question.id] = question.multiple ? .strings(values) : .string(first) }
        }
        return result
    }
}

private struct CardQuestionField: View {
    let question: ThreadCardQuestion
    @Binding var answers: CardInteractionAnswers
    let disabled: Bool
    @Environment(\.locale) private var locale
    @FocusState private var textFocused: Bool
    private let palette = NativePalette.overview
    private var otherOpen: Bool { question.options.isEmpty || answers.other[question.id] != nil }
    private var customText: Binding<String> {
        Binding(get: { answers.other[question.id] ?? "" }, set: { answers.other[question.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let header = question.header, !header.isEmpty {
                    Text(header).font(NativeTypography.inter(size: 10.5, weight: 500)).foregroundStyle(palette.muted.swiftUI)
                }
                Text(question.prompt).font(NativeTypography.inter(size: 13, weight: 600))
                    .foregroundStyle(palette.ink.swiftUI).lineSpacing(3)
            }
            .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(question.options) { option in
                    let selected = answers.picked[question.id, default: []].contains(option.value)
                    Button { answers.toggle(option.value, for: question) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            CardQuestionIndicator(multiple: question.multiple, selected: selected).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(NativeTypography.inter(size: 12, weight: 500))
                                    .foregroundStyle(palette.ink.swiftUI)
                                if let description = option.description, !description.isEmpty {
                                    Text(description).font(NativeTypography.inter(size: 11))
                                        .foregroundStyle(palette.muted.swiftUI).lineLimit(2).lineSpacing(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 46, alignment: .topLeading)
                    }
                    .buttonStyle(CardQuestionOptionStyle(selected: selected))
                    .help(option.description ?? option.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if question.options.isEmpty || (question.allowOther && otherOpen) {
                    textInput
                } else if question.allowOther {
                    Button {
                        answers.openOther(for: question)
                    } label: {
                        HStack(spacing: 10) {
                            CardQuestionIndicator(multiple: question.multiple, selected: false)
                            Text(sectionText(locale, "其它…", "Other…"))
                                .font(NativeTypography.inter(size: 12)).foregroundStyle(palette.muted.swiftUI)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7).frame(minHeight: 32)
                    }
                    .buttonStyle(CardQuestionOptionStyle(selected: false))
                }
            }
        }
        .disabled(disabled)
    }

    private var textInput: some View {
        Group {
            if question.secret { SecureField(placeholder, text: customText) }
            else { TextField(placeholder, text: customText) }
        }
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .textContentType(nil)
        .font(NativeTypography.inter(size: 12))
        .foregroundStyle(palette.ink.swiftUI)
        .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 36)
        .background(palette.ink.swiftUI.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(textFocused ? palette.ink.swiftUI : palette.line.swiftUI, lineWidth: 1))
        .focused($textFocused)
        .accessibilityLabel(question.prompt)
        .onAppear { if !question.options.isEmpty && !disabled { textFocused = true } }
        .onChange(of: textFocused) { _, focused in
            if !focused, !question.options.isEmpty {
                let raw = answers.other[question.id] ?? ""
                if (question.secret ? raw : cardTrimAnswer(raw)).isEmpty {
                    answers.other.removeValue(forKey: question.id)
                }
            }
        }
        .onKeyPress(.escape) {
            guard !disabled, !question.options.isEmpty else { return .ignored }
            answers.other.removeValue(forKey: question.id)
            textFocused = false
            return .handled
        }
    }

    private var placeholder: String {
        question.options.isEmpty ? sectionText(locale, "输入回答", "Enter an answer") : sectionText(locale, "输入你的回答", "Enter your answer")
    }
}

private struct CardQuestionIndicator: View {
    let multiple: Bool
    let selected: Bool
    private let palette = NativePalette.overview
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: multiple ? 3 : 7)
                .fill(selected ? palette.ink.swiftUI : .clear)
            RoundedRectangle(cornerRadius: multiple ? 3 : 7)
                .stroke(selected ? palette.ink.swiftUI : palette.faint.swiftUI, lineWidth: 1)
            if selected {
                if multiple { NativeIcon(name: "Check", size: 10, strokeWidth: 3).foregroundStyle(palette.surfaceStrong.swiftUI) }
                else { Circle().stroke(palette.surfaceStrong.swiftUI, lineWidth: 3).padding(2) }
            }
        }
        .frame(width: 14, height: 14).accessibilityHidden(true)
    }
}

private struct CardQuestionOptionStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        CardQuestionOptionBody(configuration: configuration, selected: selected)
    }
}

private struct CardQuestionOptionBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .background(NativePalette.overview.ink.swiftUI.opacity(selected || (enabled && hovered) ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 4))
            .opacity(enabled ? 1 : 0.65)
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .onHover { hovered = $0 }
    }
}

private struct CardInterventionButtonStyle: ButtonStyle {
    let question: Bool
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        CardInterventionButtonBody(configuration: configuration, question: question, primary: primary)
    }
}

private struct CardInterventionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let question: Bool
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    private let palette = NativePalette.overview
    private var fill: Color {
        if !enabled { return question ? palette.ink.swiftUI.opacity(0.05) : .clear }
        if question { return palette.ink.swiftUI }
        return primary ? palette.action.swiftUI : palette.ink.swiftUI.opacity(hovered ? 0.06 : 0)
    }
    private var ink: Color {
        if !enabled { return question ? palette.faint.swiftUI : palette.ink.swiftUI.opacity(0.34) }
        return question || primary ? palette.surfaceStrong.swiftUI : palette.ink.swiftUI.opacity(hovered ? 1 : 0.58)
    }
    var body: some View {
        configuration.label
            .font(NativeTypography.inter(size: question || primary ? 12 : 11.5, weight: question ? 600 : primary ? 680 : 600))
            .foregroundStyle(ink)
            .padding(.horizontal, question ? 12 : primary ? 17 : 16)
            .padding(.vertical, question ? 5 : 6)
            .frame(minHeight: 30)
            .background(fill, in: RoundedRectangle(cornerRadius: question ? 4 : 999))
            .background {
                if primary && !question && enabled { CardPermissionAttention() }
            }
            .overlay(RoundedRectangle(cornerRadius: question ? 4 : 999)
                .stroke(!enabled && (question || primary) ? palette.line.swiftUI : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .onHover { hovered = $0 }
    }
}

private struct CardPermissionAttention: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility
    private var animates: Bool { scenePhase != .background && !reduceMotion && enabled && (visibility?.isVisible ?? true) }

    var body: some View {
        TimelineView(.animation(minimumInterval: NativeFrameRate.interval, paused: !animates)) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let progress = min(1, cycle / 0.7)
            RoundedRectangle(cornerRadius: 999)
                .fill(NativePalette.overview.action.swiftUI.opacity(0.55 * (1 - progress)))
                .padding(-9 * progress)
        }
        .allowsHitTesting(false).accessibilityHidden(true)

    }
}

/// Small action strips wrap at the available cell width, matching CSS flex-wrap.
private struct CardActionFlow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let limit = width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: limit.isFinite ? limit : nil, height: nil))
            if x > 0 && x + size.width > limit { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}

private func sectionText(_ locale: Locale, _ chinese: String, _ english: String) -> String {
    locale.language.languageCode?.identifier == "zh" ? chinese : english
}

private func cardTrimAnswer(_ text: String) -> String {
    func whitespace(_ scalar: Unicode.Scalar) -> Bool {
        // Match JavaScript String.trim rather than Foundation's broader set.
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
    let trimmed = text.unicodeScalars.drop(while: whitespace).reversed().drop(while: whitespace).reversed()
    return String(String.UnicodeScalarView(trimmed))
}

/// Bounded card-face tokenization, intentionally not a shell parser. All source
/// characters survive, including unmatched quotes and the unparsed tail.
private func cardCommandText(_ command: String, finished: Bool) -> AttributedString {
    let characters = Array(command)
    let operators = ["2>&1", "&&", "||", "|&", ">>", "<<", "2>", "|", ";", ">", "<", "&"]
    let breaks: Set<String> = ["&&", "||", "|&", "|", ";", "&"]
    var result = AttributedString()
    var index = 0, tokens = 0
    var segmentStart = true
    func append(_ text: String, role: String) {
        var segment = AttributedString(text)
        let opacity: Double = finished ? 0.38 : role == "program" ? 1 : role == "flag" ? 0.46 : role == "operator" ? 0.38 : role == "string" ? 0.72 : 0.64
        segment.foregroundColor = NativePalette.overview.ink.swiftUI.opacity(opacity)
        segment.font = NativeTypography.mono(size: 11, weight: role == "program" ? 640 : role == "operator" ? 700 : 500)
        if role == "string" && !finished { segment.backgroundColor = NativePalette.overview.ink.swiftUI.opacity(0.07) }
        result.append(segment)
    }
    func operatorAt(_ position: Int) -> String? {
        operators.first { candidate in
            let chars = Array(candidate)
            return position + chars.count <= characters.count && Array(characters[position..<(position + chars.count)]) == chars
        }
    }
    guard !command.isEmpty, command.utf16.count <= 400 else { append(command, role: "arg"); return result }
    while index < characters.count && tokens < 64 {
        let start = index
        let character = characters[index]
        let role: String
        if character == " " || character == "\t" || character == "\n" {
            while index < characters.count && [" ", "\t", "\n"].contains(characters[index]) { index += 1 }
            role = "space"
        } else if character == "\"" || character == "'" {
            index += 1
            while index < characters.count && characters[index] != character { index += 1 }
            if index < characters.count { index += 1 }
            role = "string"; segmentStart = false
        } else if let operation = operatorAt(index) {
            index += operation.count
            if breaks.contains(operation) { segmentStart = true }
            role = "operator"
        } else {
            while index < characters.count && ![" ", "\t", "\n", "\"", "'"].contains(characters[index]) && operatorAt(index) == nil { index += 1 }
            let flag = character == "-"
            role = flag ? "flag" : segmentStart ? "program" : "arg"
            if !flag { segmentStart = false }
        }
        append(String(characters[start..<index]), role: role)
        tokens += 1
    }
    if index < characters.count { append(String(characters[index...]), role: "arg") }
    return result
}
