import Foundation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

public struct ClaudeHarnessPlugin: HarnessPlugin {
    public init() {}
    public var descriptor: HarnessPluginDescriptor { .init(id: "claude", displayName: "Claude", threadCapabilities: .init(instructions: true, threadContext: true, sendContext: true, toolModes: [.extend,.exclusive]), installationGuide: URL(string: "https://code.claude.com/docs/en/setup")!) }
    public func logo(size: CGFloat) -> some View { ClaudeLogo(size:size) }
    public var logoSource: String { ClaudeLogo.source }
    public var translations: HarnessTranslationCatalog { ["en-US": Dictionary(uniqueKeysWithValues: claudeEnglish.map { (JSONText($0.key),JSONText($0.value)) })] }
    public var threadSettingsCodec: PluginValueCodec<ClaudeThreadSettingsUpdate> { ClaudeThreadSettingsUpdate.codec }
    public var harnessSettingsCodec: PluginValueCodec<ClaudeHarnessSettings> { ClaudeHarnessSettings.codec }
    public var settingsPresentationCodec: PluginValueCodec<ClaudeSettingsPresentationData> { ClaudeSettingsPresentationData.codec }
    public func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<ClaudeOverviewView> { try projectClaudeOverview(input: input, availableColumns: availableColumns) }
    public func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? { try claudeExecutionTokenUsage(thread: thread, executionID: executionID) }
    public func projectMokuDock(input: HarnessThreadInput) throws -> HarnessMokuPresentation? { claudeMoku(try ClaudeState(input.thread.sessionState)) }
    public func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) -> some View { ClaudeThreadView(input: input, actions: actions, context: context) }
    public func overviewCard(input: HarnessThreadInput, projection: ClaudeOverviewView, actions: HarnessThreadActions, openThread: @escaping () -> Void) -> some View { ClaudeOverviewCard(input: input, projection: projection, actions: actions, openThread: openThread) }
    public func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<ClaudeSettingsPresentationData>, update: @escaping (ClaudeThreadSettingsUpdate) async throws -> Void) -> some View { ClaudeThreadSettingsView(input: input, resource: resource, update: update) }
    public func harnessSettings(props: HarnessSettingsProps<ClaudeHarnessSettings, ClaudeSettingsPresentationData>) -> some View { ClaudeHarnessSettingsView(props: props) }
}
