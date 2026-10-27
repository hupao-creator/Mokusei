import MokuseiPluginUI
import MokuseiVoice
import SwiftUI

/// Surface-local visibility owns metering demand, never the voice session itself.
public struct NativeMokuVoiceCloud: View {
    public let client: NativeVoiceMediaClient
    public var visible: Bool
    @State private var owner = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(client: NativeVoiceMediaClient, visible: Bool) { self.client = client; self.visible = visible }
    private var active: Bool { client.state.phase != .closed && client.state.phase != .failed }
    private var needsAnalysis: Bool { visible && client.state.phase == .listening && !client.state.muted && !client.state.mediaSuspended }
    public var body: some View {
        // Retain the drawing's layout identity through capsule resizing. A newly
        // inserted cloud would appear at the final compact width mid-collapse.
        // The inactive drawing is transparent and its timeline is paused.
        NativeVoiceCloud(level: client.inputAnalysis.level, pitchHz: client.inputAnalysis.pitchHz,
            confidence: client.inputAnalysis.confidence, capturedAt: client.inputAnalysis.capturedAt,
            listening: client.state.phase == .listening, muted: client.state.muted || client.state.mediaSuspended,
            visible: visible, motionEnabled: active && !reduceMotion)
        .opacity(active ? 1 : 0)
        // Follow semantic activity, including preparation and stopping. This
        // transaction only presents the cloud; it never delays media startup.
        .animation(reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0), value: active)
        .onChange(of: needsAnalysis, initial: true) { _, needed in client.setVisualizationVisible(needed, owner: owner) }
        .onDisappear { client.setVisualizationVisible(false, owner: owner) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
