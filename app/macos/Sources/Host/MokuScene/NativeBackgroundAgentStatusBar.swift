import MokuseiPluginUI
import SwiftUI

/// Background work has its own passive seat, independent of Moku's messages,
/// composer and cancellation authority. Multiple scopes collapse to one role.
struct NativeBackgroundAgentStatusBar: View {
    let presentation: NativeMokuWorkspacePresentation
    @Environment(\.locale) private var locale

    private var roleLabels: [String] {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return chinese ? ["Tag Agent 正在运行", "Super Thread Agent 正在运行"]
            : ["Tag Agent is running", "Super Thread Agent is running"]
    }

    var body: some View {
        let roles = roleLabels
        let labels = zip(roles, [presentation.tagAgentRunning, presentation.superThreadAgentRunning])
            .filter { $0.1 }.map { $0.0 }
        ZStack(alignment: .leading) {
            // Activity must not move the resident editor or repack the canvas.
            // Measure both localized roles even while idle, without native rings.
            layout(roles, placeholder: true).hidden().accessibilityHidden(true)
            layout(labels, placeholder: false)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.regularMaterial)
        .opacity(labels.isEmpty ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.joined(separator: ", "))
        .accessibilityHidden(labels.isEmpty)
        .accessibilityIdentifier("background-agent-status")
        // Execution completion and disconnect retire the claim immediately.
        .transaction { $0.animation = nil }
    }

    private func layout(_ labels: [String], placeholder: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { statuses(labels, placeholder: placeholder) }
                .fixedSize()
            VStack(alignment: .leading, spacing: 6) { statuses(labels, placeholder: placeholder) }
        }
    }

    @ViewBuilder private func statuses(_ labels: [String], placeholder: Bool) -> some View {
        ForEach(labels, id: \.self) { label in
            HStack(spacing: 6) {
                if placeholder { Color.clear.frame(width: 10, height: 10) }
                else { NativeStatusSpinner(size: 10, lineWidth: 1.5).accessibilityHidden(true) }
                Text(label).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
