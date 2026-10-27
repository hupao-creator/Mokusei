import SwiftUI

public enum InteractionQuestionStyle: Hashable, Sendable {
    /// Conversation/overview: Other becomes a focused single-row editor and
    /// closes on Escape or an empty blur.
    case compact
    /// Document questions use the thread theme's borderless 13-point choices.
    case detail
    /// Form layout: Other remains an explicit choice above a persistent editor.
    case form
}

/// A presentation-only field. Error text and semantic validation belong to the
/// plugin, so these controls can also render Harness-private question formats.
public struct InteractionQuestionField: View {
    public let question: InteractionQuestionSpec
    @Binding private var answers: InteractionAnswers
    private let disabled: Bool
    private let error: String?
    private let localeOverride: Locale?
    private let configuredStyle: InteractionQuestionStyle
    private let palette: NativePalette.Surface
    @Environment(\.locale) private var environmentLocale
    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.nativeInteractionQuestionInDocument) private var inDocument
    @FocusState private var editorFocused: Bool
    @FocusState private var focusedChoice: Int?

    public init(question: InteractionQuestionSpec, answers: Binding<InteractionAnswers>,
                disabled: Bool = false, error: String? = nil, locale: Locale? = nil,
                style: InteractionQuestionStyle = .compact,
                palette: NativePalette.Surface = NativePalette.thread) {
        self.question = question; _answers = answers; self.disabled = disabled
        self.error = error; localeOverride = locale; self.configuredStyle = style; self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 5 : 9) {
            heading
            if !question.required { hint(text("选填", "Optional")) }
            ForEach(Array(question.hints.enumerated()), id: \.offset) { _, value in hint(value) }
            if question.editor == .jsonObject {
                hint(text("请填写有效的 JSON 对象。", "Enter a valid JSON object."))
            }
            if question.multiple && !question.options.isEmpty && style == .form {
                hint(text("可多选", "Select all that apply"))
            }
            if question.isTextOnly {
                editor(other: false)
            } else {
                VStack(alignment: .leading, spacing: style == .compact ? 4 : 5) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                        choice(label: option.label, description: option.description,
                               selected: answers.picked(question).contains(option.value), focusIndex: index) {
                            answers.toggle(question, value: option.value)
                        }
                    }
                    if question.allowOther { otherAnswer }
                }
            }
            if let error, !error.isEmpty {
                Text(InteractionQuestionError.localized(error, locale: locale))
                    .font(NativeTypography.inter(size: 11))
                    .foregroundStyle(palette.danger.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(text("回答错误", "Answer error"))
                    .accessibilityValue(InteractionQuestionError.localized(error, locale: locale))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.prompt)
    }

    private var locale: Locale { localeOverride ?? environmentLocale }
    private var style: InteractionQuestionStyle { configuredStyle == .compact && inDocument ? .detail : configuredStyle }
    private var interactionDisabled: Bool { disabled || !environmentEnabled }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(question.header.flatMap { $0.isEmpty ? nil : $0 } ?? question.prompt)
                .font(NativeTypography.inter(size: style == .compact ? 12 : 13, weight: style == .detail ? 500 : 600))
                .foregroundStyle(palette.ink.swiftUI)
            if let header = question.header, !header.isEmpty {
                Text(question.prompt)
                    .font(NativeTypography.inter(size: style == .compact ? 11 : 12))
                    .foregroundStyle(palette.muted.swiftUI)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func hint(_ value: String) -> some View {
        Text(value).font(NativeTypography.inter(size: 10))
            .foregroundStyle(palette.faint.swiftUI)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var otherAnswer: some View {
        if style != .form {
            if answers.otherOpen(question) { editor(other: true) }
            else {
                choice(label: text("其它…", "Other…"), description: nil, selected: false,
                       focusIndex: question.options.count, other: true) {
                    answers.toggleOther(question)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                choice(label: text("其他回答", "Other answer"), description: nil,
                       selected: answers.otherOpen(question), focusIndex: question.options.count) {
                    if !question.multiple && answers.otherOpen(question) { editorFocused = true }
                    else { answers.toggleOther(question) }
                }
                if answers.otherOpen(question) { editor(other: true).padding(.leading, 34) }
            }
        }
    }

    private func choice(label: String, description: String?, selected: Bool,
                        focusIndex: Int, other: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: style == .detail ? 10 : 9) {
                RoundedRectangle(cornerRadius: question.multiple ? 3 : 7)
                    .fill(selected ? palette.accent.swiftUI : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: question.multiple ? 3 : 7).strokeBorder((selected ? palette.accent : palette.faint).swiftUI))
                    .overlay {
                        if selected { RoundedRectangle(cornerRadius: question.multiple ? 2 : 6).strokeBorder(palette.surface.swiftUI, lineWidth: 3).padding(1) }
                    }
                    .frame(width: 14, height: 14).padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(NativeTypography.inter(size: style == .detail ? 13 : 12, weight: 500))
                        .foregroundStyle((other ? palette.muted : palette.ink).swiftUI)
                    if let description, !description.isEmpty {
                        Text(description).font(NativeTypography.inter(size: style == .detail ? 12 : 11))
                            .foregroundStyle(palette.muted.swiftUI)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, style == .detail ? 12 : 10).padding(.vertical, style == .detail ? 12 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? (style == .detail ? palette.surface : palette.accentSoft).swiftUI : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder((selected ? palette.accent : palette.line).swiftUI.opacity(style == .detail ? 0 : style == .form ? (selected ? 0.2 : 0) : selected ? 0.65 : 0.55),
                              style: StrokeStyle(lineWidth: 1, dash: other ? [3, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .focused($focusedChoice, equals: focusIndex)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { event in
            guard style == .form, !question.multiple, !interactionDisabled, event.modifiers.isEmpty else { return .ignored }
            let step = event.key == .upArrow || event.key == .leftArrow ? -1 : 1
            let count = question.options.count + (question.allowOther ? 1 : 0)
            let next = (focusIndex + step + count) % count
            focusedChoice = next
            if next < question.options.count { answers.toggle(question, value: question.options[next].value) }
            else if !answers.otherOpen(question) { answers.toggleOther(question) }
            return .handled
        }
        .accessibilityLabel(label)
        .accessibilityValue(selected ? text("已选择", "Selected") : text("未选择", "Not selected"))
        .accessibilityHint([question.multiple ? text("多选", "Multiple choice") : text("单选", "Single choice"),
                            description ?? ""].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func editor(other: Bool) -> some View {
        editorControl(other: other)
            .font(question.editor == .jsonObject ? NativeTypography.mono(size: 12) : NativeTypography.inter(size: style == .detail && other ? 13 : 12))
            .foregroundStyle(palette.ink.swiftUI)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style == .detail ? Color.clear : palette.surfaceSoft.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(editorBorder.swiftUI, lineWidth: 1))
            .focused($editorFocused)
            .accessibilityLabel(question.prompt)
            .accessibilityHint(error.map { InteractionQuestionError.localized($0, locale: locale) } ?? "")
            .onAppear {
                if other && style != .form && !interactionDisabled { editorFocused = true }
            }
            .onChange(of: editorFocused) { wasFocused, focused in
                if !interactionDisabled && wasFocused && !focused && other && style != .form && answers.customIsEmpty(question) {
                    answers.closeOther(question)
                }
            }
            .onKeyPress(.escape) {
                guard other && style != .form && !interactionDisabled else { return .ignored }
                answers.closeOther(question)
                editorFocused = false
                return .handled
            }
    }

    @ViewBuilder private func editorControl(other: Bool) -> some View {
        if question.secret {
            SecureField(placeholder, text: customText)
                .textContentType(nil)
        } else if question.editor == .multiline || question.editor == .jsonObject {
            TextField(placeholder, text: customText, axis: .vertical)
                .lineLimit((other ? 2 : 3)...8)
        } else if question.editor == .number || question.editor == .integer {
            // Keep the raw numeric draft (including incomplete/invalid input).
            // The owning plugin validates range and integer semantics.
            TextField(placeholder, text: customText)
                .onKeyPress(.upArrow) { stepNumber(by: 1) }
                .onKeyPress(.downArrow) { stepNumber(by: -1) }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: _ = stepNumber(by: 1)
                    case .decrement: _ = stepNumber(by: -1)
                    @unknown default: break
                    }
                }
        } else {
            TextField(placeholder, text: customText)
        }
    }

    private func stepNumber(by step: Double) -> KeyPress.Result {
        guard !interactionDisabled else { return .ignored }
        let raw = answers.otherText(question).trimmingCharacters(in: .whitespacesAndNewlines)
        var next = raw.isEmpty ? (question.minimum ?? 0) : (Double(raw).map { $0 + step } ?? .nan)
        guard next.isFinite else { return .ignored }
        if let minimum = question.minimum { next = max(minimum, next) }
        if let maximum = question.maximum { next = min(maximum, next) }
        guard next.isFinite else { return .ignored }
        answers.writeOther(question, text: String(next))
        return .handled
    }

    private var customText: Binding<String> {
        Binding(get: { answers.otherText(question) }, set: { answers.writeOther(question, text: $0) })
    }
    private var radius: CGFloat { style == .compact ? 10 : style == .detail ? 4 : 5 }
    private var editorBorder: NativeColor {
        if error != nil { return palette.danger }
        return editorFocused ? palette.accent : palette.line
    }
    private var placeholder: String {
        question.editor == .jsonObject ? "{ }" : text("输入你的回答", "Write your answer")
    }
    private func text(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}

private struct NativeInteractionQuestionDocumentKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    var nativeInteractionQuestionInDocument: Bool {
        get { self[NativeInteractionQuestionDocumentKey.self] }
        set { self[NativeInteractionQuestionDocumentKey.self] = newValue }
    }
}

public extension NativePalette.Surface {
    /// Components accept the owning product's accent without selecting a theme by plugin identity.
    func withAccent(_ accent: NativeColor, soft: NativeColor) -> Self {
        Self(canvas: canvas, surface: surface, surfaceStrong: surfaceStrong, surfaceSoft: surfaceSoft,
             ink: ink, inkStrong: inkStrong, muted: muted, faint: faint, line: line, lineSoft: lineSoft,
             accent: accent, accentSoft: soft, action: action, provider: provider, danger: danger,
             warning: warning, success: success, agentRun: agentRun)
    }
}

public enum InteractionQuestionError {
    /// Keep unknown plugin errors intact instead of hiding details behind a
    /// generic label. Known public-form errors use the shared field vocabulary.
    public static func localized(_ error: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "zh" else { return error }
        let labels = [
            "An answer is required.": "请填写回答。", "Enter text.": "请填写文字。",
            "Answer must be a JSON object.": "回答必须是 JSON 对象。", "Answer must be valid JSON.": "请填写有效的 JSON。",
            "Answer does not match the required pattern.": "回答不符合要求的格式。",
            "Choose an available option.": "请选择已有选项。", "Choose available options.": "请选择已有选项。",
            "Enter an email address.": "请填写电子邮箱地址。", "Enter a URI.": "请填写有效地址。",
            "Enter a valid date.": "请填写有效日期。", "Enter a valid date and time.": "请填写有效日期和时间。",
            "Enter a finite number.": "请填写有效数字。", "Enter a number.": "请填写数字。", "Enter an integer.": "请填写整数。",
            "Choose yes or no.": "请选择是或否。", "Choose one or more answers.": "请选择一个或多个回答。",
            "Answers must not contain duplicates.": "回答不能重复。", "Enter a single answer.": "请填写一个回答。",
            "Confirm that this step is complete.": "请确认已完成此步骤。"
        ]
        if let translated = labels[error] { return translated }
        for (prefix, suffix, translatedPrefix, translatedSuffix) in [
            ("Enter at least ", " characters.", "请填写至少 ", " 个字符。"),
            ("Enter at most ", " characters.", "请填写至多 ", " 个字符。"),
            ("Enter a number of at least ", ".", "请填写不小于 ", " 的数字。"),
            ("Enter a number of at most ", ".", "请填写不大于 ", " 的数字。"),
            ("Choose at least ", " answers.", "请至少选择 ", " 个回答。"),
            ("Choose at most ", " answers.", "请至多选择 ", " 个回答。")
        ] where error.hasPrefix(prefix) && error.hasSuffix(suffix) {
            return translatedPrefix + error.dropFirst(prefix.count).dropLast(suffix.count) + translatedSuffix
        }
        return error
    }
}
