import AppKit
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct VoiceMessageBubble: View {
    let message: VoiceTranscriptMessage
    let tail: Bool
    let maximumWidth: CGFloat
    let label: String
    @State private var entered = false
    private var user: Bool { message.role == .user }
    private var color: Color { user ? VoicePalette.blue.swiftUI : VoicePalette.incoming.swiftUI }
    private var width: CGFloat {
        guard !message.text.codeUnits.isEmpty else { return min(maximumWidth, 55) }
        let font = NativeTypography.interPlatformFont(size: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20.8; paragraph.maximumLineHeight = 20.8
        paragraph.lineBreakMode = .byWordWrapping
        let measured = (message.text.string as NSString).boundingRect(
            with: CGSize(width: max(8, maximumWidth - 28), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
        return min(maximumWidth, max(36, ceil(measured.width) + 28))
    }
    var body: some View {
        Group {
            if message.text.codeUnits.isEmpty { VoiceTypingDots() }
            else {
                Text(message.text.string)
                    .font(NativeTypography.inter(size: 13))
                    .modifier(VoiceLineHeight(size: 13, height: 20.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: message.text.codeUnits.isEmpty ? 20 : 20.8, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: width, alignment: .leading)
        .foregroundStyle(user ? .white : NativePalette.thread.ink.swiftUI)
        .background {
            ZStack(alignment: user ? .bottomTrailing : .bottomLeading) {
                if tail {
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: user ? 12 : 0,
                                           bottomTrailingRadius: user ? 0 : 12, topTrailingRadius: 0)
                        .fill(color).frame(width: 13, height: 17).offset(x: user ? 5 : -5)
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: user ? 12 : 0,
                                           bottomTrailingRadius: user ? 0 : 12, topTrailingRadius: 0)
                        .fill(VoicePalette.paper.swiftUI).frame(width: 9, height: 19).offset(x: user ? 9 : -9)
                }
                RoundedRectangle(cornerRadius: 19).fill(color)
            }
        }
        .opacity(entered ? 1 : 0)
        .offset(y: entered ? 0 : 5)
        .scaleEffect(entered ? 1 : 0.98)
        .onAppear { withAnimation(.easeOut(duration: 0.2)) { entered = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

}

private struct VoiceTypingDots: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in VoiceTypingDot(delay: Double(index) * 0.15) }
        }.frame(minHeight: 20).padding(.horizontal, 2).accessibilityHidden(true)
    }
}
private struct VoiceTypingDot: View {
    let delay: Double
    @State private var running = false
    var body: some View {
        Group {
            if running {
                PhaseAnimator([0, 1, 2, 3]) { phase in
                    Circle().fill(.foreground).frame(width: 5, height: 5)
                        .opacity(phase == 1 ? 0.8 : 0.3).offset(y: phase == 1 ? -2 : 0)
                } animation: { phase in
                    switch phase {
                    case 1, 2: .easeInOut(duration: 0.455)
                    case 3: .linear(duration: 0.39)
                    default: .linear(duration: 0)
                    }
                }
            } else { Circle().fill(.foreground).frame(width: 5, height: 5).opacity(0.4) }
        }
        .task {
            do { try await Task.sleep(for: .seconds(delay)); running = true } catch {}
        }
    }
}
