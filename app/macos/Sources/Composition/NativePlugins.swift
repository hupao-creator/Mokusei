import ChiefPluginAPI
import ChiefUI
import ChiefHarnessCodex
import ChiefHarnessPi
import ChiefHarnessClaude
import ChiefHarnessOpenCode
import ChiefApplications
import ChiefSidecardConversation
import ChiefSidecardBrowser

/// Both application hosts register the same modules. New features belong here
/// once, so neither device can silently miss a renderer or capability.
@MainActor public enum NativePlugins {
    public static func make() throws -> NativePluginComposition {
        try NativePluginComposition(
            harnesses: [AnyHarnessPlugin(PiHarnessPlugin()), AnyHarnessPlugin(CodexHarnessPlugin()),
                        AnyHarnessPlugin(ClaudeHarnessPlugin()), AnyHarnessPlugin(OpenCodeHarnessPlugin())],
            sidecards: [AnySidecardPlugin(NativeConversationSidecard()), AnySidecardPlugin(NativeBrowserSidecard())],
            applications: NativeApplicationModules.make())
    }
}
