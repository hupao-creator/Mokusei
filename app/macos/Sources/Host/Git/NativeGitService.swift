import MokuseiCore
import MokuseiPluginAPI

/// Internal domain declarations for the built-in Git monitor; no thread/card contribution.
@MainActor enum NativeGitService {
    static func module() throws -> ApplicationPluginModule {
        try ApplicationPluginModule(manifest: .init(id: "git", displayName: "Git", contributes: .init(
            backgroundAgents: ["git.monitor"], collections: ["git.worktrees"],
            queries: ["git.list", "git.files", "git.diff"], commands: ["git.sync"])))
    }
}
