import AppKit
import MokuseiPluginUI
import SwiftUI

/// A resident Moku communication seat above every route. It adds space rather
/// than covering the editor or permission/voice controls, and never takes focus.
struct NativeMokuTimerBar: View {
    let timer: NativeMokuTimerController
    let exclusions: NativeClickExclusions
    @Environment(\.locale) private var locale

    var body: some View {
        if let message = timer.current {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    NativeMokuCapsuleEyes(expression: .surprised, focus: 0)
                        .fill(.primary).frame(width: 34, height: 38)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localize("Moku 提醒", "Moku timer")).font(.caption.weight(.semibold))
                        NativeMokuTalkContent(message: .init(id: message.id, text: message.text))
                            .frame(height: min(NativeMokuTalkTypography.maximumHeight,
                                               NativeMokuTalkTypography.height(message.text, width: 180)))
                            .accessibilityIdentifier("moku-timer-content")
                    }
                    NativeMokuTimerReceiptButton(title: localize("已收到", "Received")) {
                        timer.acknowledge(id: message.id)
                    }.fixedSize()
                }
                if timer.pending.count > 1 {
                    Text(localize("还有 \(timer.pending.count - 1) 条待确认", "\(timer.pending.count - 1) more waiting"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = timer.audioError {
                    HStack {
                        Text(localize("铃声播放失败：", "Bell unavailable: ") + error).font(.caption)
                        Button(localize("重试铃声", "Retry bell")) { timer.retryAudio() }
                    }
                }
            }
            .padding(14).frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.orange.opacity(0.6)))
            .background(NativeClickExclusionRegion(exclusions: exclusions))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(localize("Moku 提醒，等待确认", "Moku timer, awaiting acknowledgment"))
            .accessibilityIdentifier("moku-timer")
            .padding(.horizontal, 16).padding(.vertical, 8)
            // Static eyes and no insertion/removal choreography also respect
            // Reduce Motion. No timeout, Escape or outside-click dismissal.
            .transaction { $0.animation = nil }
        }
    }

    private func localize(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}

/// Native accessibility remains available in a windowless host. Ignore the
/// second mouse-down of a double click even if the next queued message has
/// already updated this same button's action in between the two events.
struct NativeMokuTimerReceiptButton: NSViewRepresentable {
    let title: String
    let acknowledge: () -> Void

    func makeNSView(context: Context) -> ReceiptButton {
        let button = ReceiptButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.identifier = .init("moku-timer-acknowledge")
        button.target = button
        button.action = #selector(ReceiptButton.receive)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: ReceiptButton, context: Context) {
        button.title = title
        button.setAccessibilityLabel(title)
        button.acknowledge = acknowledge
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReceiptButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class ReceiptButton: NSButton {
        var acknowledge: () -> Void = {}
        @objc func receive() { acknowledge() }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            // A receipt does not need AppKit's click animation or a responder
            // transfer. Report the accessibility action as handled explicitly.
            receive()
            return true
        }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 1 else { return }
            super.mouseDown(with: event)
        }
    }
}
