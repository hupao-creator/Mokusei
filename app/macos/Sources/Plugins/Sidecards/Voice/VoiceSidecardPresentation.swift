import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

@MainActor @Observable
public final class VoiceSidecardPresentation {
    public private(set) var context: SidecardContext
    public private(set) var state = SidecardVoiceState(phase: .closed, supported: false, available: false,
        loading: false, muted: false, error: "", messages: [])
    public private(set) var actionError = ""
    public var scrollPosition = ScrollPosition(edge: .bottom)
    public private(set) var pinned = true
    public private(set) var away = false
    public private(set) var newMessages = false
    public private(set) var lastCompletedAnnouncement = ""
    @ObservationIgnored private let lifetime: PluginLifetime
    @ObservationIgnored private var unsubscribe: (() -> Void)?
    @ObservationIgnored private weak var capability: SidecardVoiceCapability?
    @ObservationIgnored private var capabilityGeneration: UInt64 = 0
    @ObservationIgnored private var previousExpanded: Bool?
    @ObservationIgnored private var latestTransition: UUID?

    public init(context: SidecardContext, lifetime: PluginLifetime) {
        self.context = context; self.lifetime = lifetime
        lifetime.onCancel { [weak self] in self?.release() }
        update(context: context)
    }
    public var active: Bool { state.phase == .preparing || state.phase == .connecting || state.phase == .listening }
    public var error: String { state.error.codeUnits.isEmpty ? actionError : state.error.string }
    public var status: String { translate("历史语音记录（只读）") }
    public func translate(_ text: String) -> String { context.translate(text) }

    public func update(context: SidecardContext) {
        guard !lifetime.isCancelled else { return }
        let previous = capability
        let changedCapability = previous !== context.voice
        if context.suppressed && !self.context.suppressed { cancelLatestTransition() }
        self.context = context
        if changedCapability {
            cancelLatestTransition()
            capabilityGeneration += 1
            unsubscribe?(); unsubscribe = nil
            capability = context.voice
            actionError = ""
            if let voice = context.voice {
                receive(voice.snapshot())
                let generation = capabilityGeneration
                unsubscribe = voice.subscribe(lifetime: lifetime) { [weak self, weak voice] in
                    guard let self, let voice, !self.lifetime.isCancelled, generation == self.capabilityGeneration else { return }
                    self.receive(voice.snapshot())
                }
            } else {
                receive(.init(phase: .closed, supported: false, available: false, loading: false, muted: false, error: "", messages: []))
            }
        }
        if previousExpanded != context.expanded {
            cancelLatestTransition()
            messagesChanged()
        }
        previousExpanded = context.expanded
        refreshAnnouncement()
    }
    private func receive(_ next: SidecardVoiceState) {
        let changedMessages = state.messages != next.messages
        state = next
        if !next.error.codeUnits.isEmpty { actionError = "" }
        if changedMessages { messagesChanged() }
        refreshAnnouncement()
    }
    private func messagesChanged() {
        if pinned { scrollToLatest() }
        else if !state.messages.isEmpty { newMessages = true }
    }
    public func jumpToLatest(bottom: CGFloat, reduceMotion: Bool) {
        pinned = true; away = false; newMessages = false
        let transition = UUID()
        latestTransition = transition
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35), completionCriteria: .removed) {
            // A fixed offset does not acquire SwiftUI's growth-following edge
            // anchor until this transition's completion admits it below.
            scrollPosition.scrollTo(y: bottom)
        } completion: {
            guard self.latestTransition == transition else { return }
            self.latestTransition = nil
            if self.pinned { self.scrollToLatest() }
        }
    }
    private func scrollToLatest() {
        guard latestTransition == nil else { return }
        pinned = true; away = false; newMessages = false
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { scrollPosition.scrollTo(edge: .bottom) }
    }
    public func userScrollBegan(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        latestTransition = nil
        // Tracking can begin without moving at a scroll boundary. The current
        // geometry, not that phase alone, decides whether following is lost.
        didScroll(offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight)
    }
    public func cancelLatestTransition() { latestTransition = nil }
    public func finishLatestTransition() {
        guard latestTransition != nil else { return }
        latestTransition = nil
        if pinned { scrollToLatest() }
    }
    public func didScroll(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        guard latestTransition == nil else { return }
        let atBottom = contentHeight - offset - viewportHeight < 48
        pinned = atBottom; away = !atBottom
        if atBottom { newMessages = false }
    }
    public func contentSizeChanged() {
        guard pinned else { return }
        // ScrollPosition resolves the edge against the next committed layout.
        scrollToLatest()
    }
    private func refreshAnnouncement() {
        let message = state.messages.last { message in
            message.complete && message.text.codeUnits.contains { unit in
                switch unit {
                case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: false
                default: true
                }
            }
        }
        let announcement = message.map { "\(translate($0.role == .user ? "你" : "助手")): \($0.text.string)" } ?? ""
        if lastCompletedAnnouncement != announcement { lastCompletedAnnouncement = announcement }
    }
    public func start() async { actionError = translate("线程内语音已移除，请在 Overview 使用全局 Moku 语音。") }
    public func stop() async {}
    public func toggleMute() {}
    public func refresh() async {
        guard !lifetime.isCancelled, let voice = capability else { return }
        await run(voice) { try await $0.refresh() }
    }
    public func close() { context.close() }
    private func run(_ voice: SidecardVoiceCapability, action: (SidecardVoiceCapability) async throws -> Void) async {
        let generation = capabilityGeneration
        actionError = ""
        do { try await action(voice) }
        catch {
            if !lifetime.isCancelled && generation == capabilityGeneration { actionError = error.localizedDescription }
        }
    }
    private func release() {
        cancelLatestTransition()
        capabilityGeneration += 1
        unsubscribe?(); unsubscribe = nil
        capability = nil
    }
}
