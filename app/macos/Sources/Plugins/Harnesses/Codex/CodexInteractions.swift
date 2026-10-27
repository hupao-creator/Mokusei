import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct CodexInteractionPanel: View {
    let interaction: CodexInteraction
    let publicInteraction: JSONValue?
    let busy: Bool
    let error: String?
    let respond: (JSONText, JSONValue?) -> Void
    @Environment(\.locale) private var locale
    @State private var answers = InteractionAnswers()
    @State private var formValue = "{}"
    @State private var parseError: String?

    var body: some View {
        if interaction.status != "pending" {
            HStack(spacing: 5) {
                NativeIcon(name: "Check", size: 13)
                Text(interaction.title + " · " + codexLocalized(resolution, locale: locale))
            }.font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ThreadDetailRequest {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if publicInteraction == nil {
                        commandDetail
                        errorText(codexLocalized("该 Codex 请求已失效。", locale: locale))
                    } else if interaction.kind == "mcp-elicitation" {
                        elicitationBody
                    } else if interaction.kind == "user-input" {
                        ForEach(questions) { question in
                            InteractionQuestionField(question: question, answers: $answers, disabled: busy,
                                                     style: .compact).padding(.top, 14)
                        }
                        errorText(error)
                        buttons(questionActions)
                    } else {
                        commandDetail
                        errorText(error)
                        buttons(permissionActions)
                    }
                }
            }
        }
    }

    private var resolution: String {
        ["allowed": "已允许", "denied": "已拒绝", "submitted": "已提交", "cancelled": "已取消"][interaction.status] ?? "已处理"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            NativeIcon(name: publicInteraction != nil && interaction.kind == "user-input" ? "MessageSquare" : "ShieldCheck", size: 15)
                .foregroundStyle(NativePalette.thread.muted.swiftUI).padding(.top, 3)
            VStack(alignment: .leading, spacing: 9) {
                Text(interaction.title).font(NativeTypography.inter(size: 16, weight: 600))
                    .foregroundStyle(NativePalette.thread.inkStrong.swiftUI).textSelection(.enabled)
                if publicInteraction != nil, interaction.kind == "mcp-elicitation", interaction.elicitation?["mode"]?.stringValue == "url" {
                    Text(interaction.elicitation?["url"]?.stringValue ?? "")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(NativePalette.thread.muted.swiftUI).textSelection(.enabled)
                } else if interaction.kind != "command-approval", publicInteraction == nil || interaction.kind != "mcp-elicitation", let detail = interaction.detail, !detail.isEmpty {
                    Text(detail).font(NativeTypography.inter(size: 13)).foregroundStyle(NativePalette.thread.muted.swiftUI).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.bottom, 17)
    }

    @ViewBuilder private var commandDetail: some View {
        if interaction.kind == "command-approval", let detail = interaction.detail, !detail.isEmpty { resourceText(detail) }
    }

    private var questions: [InteractionQuestionSpec] {
        (publicInteraction?["questions"]?.arrayValue ?? []).map { question in
            let options = (question["options"]?.arrayValue ?? []).map { option in
                InteractionQuestionOption(value: option.codexIdentity("value"), label: option["label"]?.stringValue ?? "", description: option["description"]?.stringValue)
            }
            return InteractionQuestionSpec(id: question.codexIdentity("id"), prompt: question["prompt"]?.stringValue ?? "",
                header: question["header"]?.stringValue, multiple: false,
                allowOther: question["allowOther"]?.boolValue == true || options.isEmpty,
                secret: question["secret"]?.boolValue == true, options: options)
        }
    }

    private var questionActions: [JSONValue] {
        let submit = interaction.actions.first { $0["intent"]?.stringValue == "submit" }
        return (submit.map { [$0] } ?? []) + interaction.actions.filter { ["deny", "cancel"].contains($0["intent"]?.stringValue ?? "") }
    }

    private var permissionActions: [JSONValue] {
        let first = interaction.actions.first { $0["intent"]?.stringValue == "allow" }
        guard let first else { return interaction.actions }
        return [first] + interaction.actions.filter { $0["id"] != first["id"] }
    }

    @ViewBuilder private var elicitationBody: some View {
        let schema = interaction.elicitation?["requestedSchema"]
        let form = interaction.elicitation?["mode"]?.stringValue == "form"
        let confirmation = form && codexIsMCPConfirmationSchema(schema)
        if form && !confirmation {
            if let display = schemaDisplay(schema ?? .null) { resourceText(display) }
            else { errorText(codexLocalized("Codex MCP schema presentation 无效", locale: locale)) }
        }
        if let formQuestion {
            TextEditor(text: $formValue).font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).frame(minHeight: 80)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NativePalette.thread.line.swiftUI, lineWidth: 1))
                .disabled(busy).opacity(busy ? 0.45 : 1)
                .accessibilityLabel(formQuestion["prompt"]?.stringValue ?? "JSON")
        }
        errorText(parseError ?? error)
        buttons(interaction.actions)
    }

    private var formQuestion: JSONValue? {
        guard interaction.elicitation?["mode"]?.stringValue == "form",
              !codexIsMCPConfirmationSchema(interaction.elicitation?["requestedSchema"]),
              let index = interaction.questions.firstIndex(where: { $0["id"] == interaction.elicitation?["questionId"] }),
              let questions = publicInteraction?["questions"]?.arrayValue, questions.indices.contains(index) else { return nil }
        return questions[index]
    }

    private func schemaDisplay(_ schema: JSONValue) -> String? {
        // Runtime projection owns the exact JSON.stringify result; this display
        // field is validated against native values and public response authority.
        if let display = interaction.raw["mcpSchemaDisplay"]?.stringValue { return display }
        // A directly materialized canonical fixture may still have a complete
        // public display. Never regenerate a schema from unordered dictionaries.
        if let observed = publicInteraction?["description"]?.stringValue,
           (try? JSONValue(data: Data(observed.utf8))) == schema { return observed }
        return nil
    }

    private var missingSchemaDisplay: Bool {
        interaction.kind == "mcp-elicitation" && interaction.elicitation?["mode"]?.stringValue == "form" &&
        !codexIsMCPConfirmationSchema(interaction.elicitation?["requestedSchema"]) &&
        schemaDisplay(interaction.elicitation?["requestedSchema"] ?? .null) == nil
    }

    private func buttons(_ items: [JSONValue]) -> some View {
        // Button order follows the native action order, with the single primary
        // approval placed first just as the existing detail CSS orders it.
        CodexActionFlow {
            ForEach(Array(items.enumerated()), id: \.offset) { _, action in
                let id = action.codexIdentity("id")
                let intent = action["intent"]?.stringValue ?? ""
                let publicAction = publicInteraction?["actions"]?.arrayValue?.first { $0["id"] == .string(id) } ?? action
                let primary = interaction.kind == "mcp-elicitation" ? ["submit", "allow"].contains(intent)
                    : interaction.kind == "user-input" ? intent == "submit"
                    : id == interaction.actions.first(where: { $0["intent"]?.stringValue == "allow" })?.codexIdentity("id")
                Button(codexActionLabel(publicAction, locale: locale)) { submit(action) }
                    .buttonStyle(CodexInteractionButtonStyle(primary: primary))
                    .disabled(busy || (missingSchemaDisplay && (intent == "submit" || intent == "allow")) ||
                        (interaction.kind == "user-input" && intent == "submit" && !answers.isComplete(for: questions)))
                    .accessibilityIdentifier("codex-interaction-\(id.string)")
            }
        }.padding(.top, 22)
    }

    private func submit(_ action: JSONValue) {
        if missingSchemaDisplay, ["submit", "allow"].contains(action["intent"]?.stringValue ?? "") { return }
        let actionID = action.codexIdentity("id")
        guard action["intent"]?.stringValue == "submit" else { parseError = nil; respond(actionID, nil); return }
        if interaction.kind == "user-input" {
            guard answers.isComplete(for: questions) else { return }
            respond(actionID, answers.json(for: questions)); return
        }
        guard let formQuestion else { parseError = nil; respond(actionID, nil); return }
        let parsed: JSONValue
        do { parsed = try JSONValue(data: Data(formValue.utf8)) }
        catch { parseError = codexLocalized("内容必须是有效 JSON。", locale: locale); return }
        guard parsed.objectValue != nil else { parseError = codexLocalized("内容必须是 JSON object。", locale: locale); return }
        parseError = nil
        respond(actionID, .object([formQuestion.codexIdentity("id"): .text(formValue)]))
    }

    @ViewBuilder private func errorText(_ value: String?) -> some View {
        if let value, !value.isEmpty {
            Text(value).font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.danger.swiftUI)
                .padding(.top, 12).textSelection(.enabled)
        }
    }

    private func resourceText(_ value: String) -> some View {
        Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(NativePalette.thread.ink.swiftUI)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(NativePalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 4))
            .padding(.top, 12).padding(.bottom, 16)
    }
}

private struct CodexInteractionButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(NativeTypography.inter(size: 11, weight: 500))
            .foregroundStyle(primary ? NativePalette.thread.canvas.swiftUI : NativePalette.thread.muted.swiftUI)
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 34)
            .background(primary ? NativePalette.thread.accent.swiftUI : configuration.isPressed ? NativePalette.thread.surface.swiftUI : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

private struct CodexActionFlow: Layout {
    private let gap: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let item = layout.items[index]
            view.place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y), proposal: ProposedViewSize(item.size))
        }
    }
    private func positions(proposal: ProposedViewSize, subviews: Subviews) -> (items: [CGRect], size: CGSize) {
        let width = proposal.width ?? .infinity
        var items: [CGRect] = []; var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0; var maxX: CGFloat = 0
        for view in subviews {
            let natural = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, natural.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + gap; rowHeight = 0 }
            items.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            maxX = max(maxX, x + size.width); x += size.width + gap; rowHeight = max(rowHeight, size.height)
        }
        return (items, CGSize(width: proposal.width ?? maxX, height: y + rowHeight))
    }
}

func codexActionLabel(_ action: JSONValue, locale: Locale) -> String {
    let label: String
    switch action["id"]?.stringValue {
    case "allow-once": label = "允许一次"
    case "allow-session": label = "本会话始终允许"
    case "deny": label = "拒绝"
    case "cancel": label = "取消"
    case "submit": label = action["intent"]?.stringValue == "allow" ? "允许" : "提交"
    default: return action["label"]?.stringValue ?? ""
    }
    return codexLocalized(label, locale: locale)
}
