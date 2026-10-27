import MokuseiCore
import SwiftUI

/// The interaction owner controls asynchronous lifetime and retry semantics.
/// Pending disables every input without discarding its draft.
public enum InteractionSubmissionState: Hashable, Sendable {
    case idle
    case submitting
    case failed(String)

    public var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
}

/// Optional shared form chrome. Plugins may instead compose individual fields
/// with their own action bar, validation, submission, and cancellation behavior.
public struct InteractionQuestionsForm: View {
    private let questions: [InteractionQuestionSpec]
    @Binding private var answers: InteractionAnswers
    private let state: InteractionSubmissionState
    private let errors: [JSONText: String]
    private let disabled: Bool
    private let canSubmit: Bool?
    private let submitLabel: String?
    private let style: InteractionQuestionStyle
    private let palette: NativePalette.Surface
    private let submit: () -> Void
    @Environment(\.locale) private var locale

    public init(questions: [InteractionQuestionSpec], answers: Binding<InteractionAnswers>,
                state: InteractionSubmissionState = .idle, errors: [JSONText: String] = [:],
                disabled: Bool = false, canSubmit: Bool? = nil, submitLabel: String? = nil,
                style: InteractionQuestionStyle = .compact,
                palette: NativePalette.Surface = NativePalette.thread, submit: @escaping () -> Void) {
        self.questions = questions; _answers = answers; self.state = state; self.errors = errors
        self.disabled = disabled; self.canSubmit = canSubmit; self.submitLabel = submitLabel
        self.style = style; self.palette = palette; self.submit = submit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 16 : 24) {
            ForEach(questions) { question in
                InteractionQuestionField(question: question, answers: $answers,
                    disabled: inputsDisabled, error: errors[question.id], style: style, palette: palette)
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(NativeTypography.inter(size: 12))
                    .foregroundStyle(palette.danger.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel(text("提交失败", "Submission failed"))
                    .accessibilityValue(message)
            }
            HStack {
                Spacer(minLength: 0)
                Button(action: submitIfReady) {
                    HStack(spacing: 7) {
                        if state.isSubmitting {
                            ProgressView().controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text(state.isSubmitting ? text("正在提交…", "Submitting…")
                             : (submitLabel ?? text("提交", "Submit")))
                            .font(NativeTypography.inter(size: 12, weight: 600))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(palette.surfaceStrong.swiftUI)
                    .background(palette.accent.swiftUI.opacity(submittable ? 1 : 0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!submittable)
                .help(text("⌘ Return 提交", "⌘ Return to submit"))
            }
        }
        .onKeyPress(.return, phases: .down) { event in
            guard event.modifiers.contains(.command) || event.modifiers.contains(.control) else { return .ignored }
            submitIfReady()
            return .handled
        }
    }

    private var inputsDisabled: Bool { disabled || state.isSubmitting }
    private var submittable: Bool {
        // A plugin's explicit result is authoritative (a required schema key may
        // legitimately allow an empty string/array). Otherwise use basic gating.
        !inputsDisabled && errors.isEmpty && (canSubmit ?? answers.isComplete(for: questions))
    }
    private func submitIfReady() {
        guard submittable else { return }
        submit()
    }
    private func text(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}
