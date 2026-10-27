import MokuseiPluginAPI
import MokuseiUI
import MokuseiHarnessCodex
import MokuseiHarnessPi
import MokuseiHarnessClaude
import MokuseiHarnessOpenCode
import MokuseiApplications
import MokuseiSidecardConversation
import MokuseiSidecardBrowser
import MokuseiSidecardVoice

/// Both application hosts register the same modules. New features belong here
/// once, so neither device can silently miss a renderer or capability.
@MainActor public enum NativePlugins {
    public static func make() throws -> NativePluginComposition {
        try NativePluginComposition(
            harnesses: [AnyHarnessPlugin(PiHarnessPlugin()), AnyHarnessPlugin(CodexHarnessPlugin()),
                        AnyHarnessPlugin(ClaudeHarnessPlugin()), AnyHarnessPlugin(OpenCodeHarnessPlugin())],
            sidecards: [AnySidecardPlugin(NativeConversationSidecard()), AnySidecardPlugin(NativeBrowserSidecard()),
                       AnySidecardPlugin(NativeVoiceSidecard())],
            applications: NativeApplicationModules.make())
    }
}
