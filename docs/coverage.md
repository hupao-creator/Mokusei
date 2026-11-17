# 文档事实覆盖表

本表映射当前树的文档、事实所有者和可定位证据，不表示全项目动态验证通过。
核对粒度包括正文声明、实现主路径、命令目标与链接；不证明全部异常/并发分支。
每行的限制与所属文档共同约束可作出的结论。

固定审计输入用 `git ls-tree -r --name-only 6b1be7af` 枚举 Markdown、MDX、RST、
AsciiDoc、README、文本运行说明/生产 prompt、证据文本及 LICENSE，包含隐藏 `.agents/`
和 `CLAUDE.md` 符号链接：共 **197** 个范围标识，其中 **190** 项自有/适用文档、
**7** 项第三方原文/生成数据。范围标识数量不是当前文件数量。
当前树有 **136** 个文档候选：下表 **129** 项自有/适用入口，另列 **7** 项第三方输入；
其中 **9** 项当前入口不在固定审计输入中。**70** 个没有独立当前文件的输入标识
逐项映射到当前事实所有者；日志接口类标识明确映射到现有能力边界，不声明日志实现。

第三方依赖源码、SwiftPM/Go 缓存、构建输出、图片/字体二进制、JSON/CSV 原始采样和
源码内注释不作为叙述文档逐份重写；其中被引用的 source/manifest/schema 是核查证据。
唯一 HTML 是 `demos/tag-selection-preview/index.html` 的可执行预览，归入该 demo 的
README/入口核对。资源来源说明属于自有文档；法律原文与生产 prompt 保持原文身份。
所有未提交/外部分支实现均不计入此源码的已实现覆盖。

## 当前入口、证据与界限

“静态核对”是实际源码/参数/引用核查，不是 PBT/e2e/benchmark 通过状态。
“测量归属”只确认文件与其记录制品的对应关系，绝不把已有报告认证成当前运行结果。
完整的职责和判据追溯格式见[事实索引](facts.md)。

| 当前文档 | 已核对范围与证据 | 当前证据界限 |
| --- | --- | --- |
| [.agents/issue-tracker.md](../.agents/issue-tracker.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[issue-tracker.md](../.agents/issue-tracker.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [.agents/linting.md](../.agents/linting.md) | 流程/配置静态核对；[Makefile](../Makefile)、[ci.yml](../.github/workflows/ci.yml)、[scope.py](../scripts/ci/scope.py)、[PBT inventory](../tools/verification/pbt/properties.json) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [.agents/skills/commit-message/SKILL.md](../.agents/skills/commit-message/SKILL.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[issue-tracker.md](../.agents/issue-tracker.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [.agents/skills/grilling/SKILL.md](../.agents/skills/grilling/SKILL.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[issue-tracker.md](../.agents/issue-tracker.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [.agents/skills/implement/SKILL.md](../.agents/skills/implement/SKILL.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[issue-tracker.md](../.agents/issue-tracker.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [.agents/skills/to-spec/SKILL.md](../.agents/skills/to-spec/SKILL.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[issue-tracker.md](../.agents/issue-tracker.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [.agents/skills/wait-what/SKILL.md](../.agents/skills/wait-what/SKILL.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[issue-tracker.md](../.agents/issue-tracker.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [AGENTS.md](../AGENTS.md) | 流程/配置静态核对；[Makefile](../Makefile)、[verification-policy.md](../scripts/ci/verification-policy.md)、[facts.md](facts.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [CLAUDE.md](../CLAUDE.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [CONTEXT.md](../CONTEXT.md) | 主路径/符号/约束静态核对；[harness.go](../internal/core/plugin/harness.go)、[state.go](../internal/core/model/state.go)、[model.go](../internal/plugins/applications/report/model.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [LICENSE](../LICENSE) | 资源/归属核对；[LICENSE](../LICENSE) | 限本地资源、metadata 与归属；未重建/逐像素验证 |
| [README.md](../README.md) | 主路径/符号/约束静态核对；[Makefile](../Makefile)、[Package.swift](../app/macos/Package.swift)、[bootstrap.go](../internal/core/composition/bootstrap.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/README.md](../app/macos/README.md) | 主路径/符号/约束静态核对；[Package.swift](../app/macos/Package.swift)、[NativeWorkspaceView.swift](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Core/README.md](../app/macos/Sources/Core/README.md) | 主路径/符号/约束静态核对；[RuntimeClient.swift](../app/macos/Sources/Core/RuntimeClient.swift)、[RuntimeProtocol.swift](../app/macos/Sources/Core/RuntimeProtocol.swift)、[RuntimeCommands.swift](../app/macos/Sources/Core/RuntimeCommands.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Host/Git/README.md](../app/macos/Sources/Host/Git/README.md) | 主路径/符号/约束静态核对；[NativeGitService.swift](../app/macos/Sources/Host/Git/NativeGitService.swift)、[NativeGitWorkspaceModel.swift](../app/macos/Sources/Host/Git/NativeGitWorkspaceModel.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Host/Interaction/README.md](../app/macos/Sources/Host/Interaction/README.md) | 主路径/符号/约束静态核对；[NativeOverviewInteraction.swift](../app/macos/Sources/Host/Interaction/NativeOverviewInteraction.swift)、[NativeReadingInteraction.swift](../app/macos/Sources/Host/Interaction/NativeReadingInteraction.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Host/MokuScene/README.md](../app/macos/Sources/Host/MokuScene/README.md) | 主路径/符号/约束静态核对；[NativeMokuWorkspacePresentation.swift](../app/macos/Sources/Host/MokuScene/NativeMokuWorkspacePresentation.swift)、[NativeMokuSceneState.swift](../app/macos/Sources/Host/MokuScene/NativeMokuSceneState.swift)、[NativeSettingsTransition.swift](../app/macos/Sources/Host/Settings/NativeSettingsTransition.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Host/Onboarding/README.md](../app/macos/Sources/Host/Onboarding/README.md) | 主路径/符号/约束静态核对；[NativeOnboardingSurface.swift](../app/macos/Sources/Host/Onboarding/NativeOnboardingSurface.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Host/Overview/README.md](../app/macos/Sources/Host/Overview/README.md) | 主路径/符号/约束静态核对；[NativeOverviewWorkspaceModel.swift](../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift)、[NativeOverviewCanvas.swift](../app/macos/Sources/Host/Overview/NativeOverviewCanvas.swift)、[NativeOverviewMembership.swift](../app/macos/Sources/Host/Overview/NativeOverviewMembership.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Host/Settings/README.md](../app/macos/Sources/Host/Settings/README.md) | 主路径/符号/约束静态核对；[NativeSettingsNavigation.swift](../app/macos/Sources/Host/Settings/NativeSettingsNavigation.swift)、[NativeSettingsModel.swift](../app/macos/Sources/Host/Settings/NativeSettingsModel.swift)、[NativeSettingsDraft.swift](../app/macos/Sources/Host/Settings/NativeSettingsDraft.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Host/WindowNavigation/README.md](../app/macos/Sources/Host/WindowNavigation/README.md) | 主路径/符号/约束静态核对；[NativeWindowNavigationView.swift](../app/macos/Sources/Host/WindowNavigation/NativeWindowNavigationView.swift)、[NativeWindowControlPlacement.swift](../app/macos/Sources/Host/WindowNavigation/NativeWindowControlPlacement.swift)、[NativeWorkspaceView.swift](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Plugins/Sidecards/README.md](../app/macos/Sources/Plugins/Sidecards/README.md) | 主路径/符号/约束静态核对；[NativePlugins.swift](../app/macos/Sources/Composition/NativePlugins.swift)、[SidecardPlugin.swift](../app/macos/Sources/Shared/PluginAPI/SidecardPlugin.swift)、[NativeSidecardFold.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeSidecardFold.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Shared/PluginAPI/README.md](../app/macos/Sources/Shared/PluginAPI/README.md) | 主路径/符号/约束静态核对；[HarnessPlugin.swift](../app/macos/Sources/Shared/PluginAPI/HarnessPlugin.swift)、[HarnessRegistry.swift](../app/macos/Sources/Shared/PluginAPI/HarnessRegistry.swift)、[HarnessThread.swift](../app/macos/Sources/Shared/PluginAPI/HarnessThread.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Shared/PluginUI/README.md](../app/macos/Sources/Shared/PluginUI/README.md) | 主路径/符号/约束静态核对；[NativeReadingPanelCloseButton.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelCloseButton.swift)、[NativeReadingPanelTransition.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift)、[NativeReadingPlaceholder.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPlaceholder.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/Sources/Shared/PluginUI/Resources/NOTICE.txt](../app/macos/Sources/Shared/PluginUI/Resources/NOTICE.txt) | 资源/归属核对；[SOURCES.md](../app/macos/Sources/Shared/PluginUI/Resources/fonts/SOURCES.md) | 限本地资源、metadata 与归属；未重建/逐像素验证 |
| [app/macos/Sources/Shared/PluginUI/Resources/fonts/SOURCES.md](../app/macos/Sources/Shared/PluginUI/Resources/fonts/SOURCES.md) | 资源/归属核对；[jetbrains-subsets.json](../app/macos/Sources/Shared/PluginUI/Resources/fonts/jetbrains-subsets.json) | 限本地资源、metadata 与归属；未重建/逐像素验证 |
| [app/macos/Sources/Shared/PluginUI/Resources/icons/LUCIDE-SOURCES.md](../app/macos/Sources/Shared/PluginUI/Resources/icons/LUCIDE-SOURCES.md) | 资源/归属核对；[lucide-paths.json](../app/macos/Sources/Shared/PluginUI/Resources/icons/lucide-paths.json) | 限本地资源、metadata 与归属；未重建/逐像素验证 |
| [app/macos/build/README.md](../app/macos/build/README.md) | 主路径/符号/约束静态核对；[bundle.go](../internal/tooling/devtool/bundle.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [app/macos/build/SOURCES.md](../app/macos/build/SOURCES.md) | 主路径/符号/约束静态核对；[generate-app-icon.swift](../app/macos/build/generate-app-icon.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [demos/README.md](../demos/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/thread-card-cloud/build.py)、[build.py](../demos/tag-cloud-loading/build.py)、[build.py](../demos/thread-card-glass-timeline/build.py) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/execution-handoff/README.md](../demos/execution-handoff/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/execution-handoff/build.py)、[main.swift](../demos/execution-handoff/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/landing-setup/README.md](../demos/landing-setup/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/landing-setup/build.py)、[main.swift](../demos/landing-setup/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/moku-gradient-material/README.md](../demos/moku-gradient-material/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/moku-gradient-material/build.py)、[main.swift](../demos/moku-gradient-material/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/moku-history-theme/README.md](../demos/moku-history-theme/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/moku-history-theme/build.py)、[main.swift](../demos/moku-history-theme/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/moku-landing/README.md](../demos/moku-landing/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/moku-landing/build.py)、[main.swift](../demos/moku-landing/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/moku-mention-transition/README.md](../demos/moku-mention-transition/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/moku-mention-transition/build.py)、[main.swift](../demos/moku-mention-transition/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/moku-note-transition/README.md](../demos/moku-note-transition/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/moku-note-transition/build.py)、[main.swift](../demos/moku-note-transition/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/moku-panel-transition/README.md](../demos/moku-panel-transition/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/moku-panel-transition/build.py)、[main.swift](../demos/moku-panel-transition/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/moku-thinking-orbit/README.md](../demos/moku-thinking-orbit/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/moku-thinking-orbit/build.py)、[main.swift](../demos/moku-thinking-orbit/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/report-thread/README.md](../demos/report-thread/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/report-thread/build.py)、[main.swift](../demos/report-thread/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/settings-navigation/README.md](../demos/settings-navigation/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/settings-navigation/build.py)、[main.swift](../demos/settings-navigation/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/settings-tabs/README.md](../demos/settings-tabs/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/settings-tabs/build.py)、[main.swift](../demos/settings-tabs/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/super-thread-carousel/README.md](../demos/super-thread-carousel/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/super-thread-carousel/build.py)、[main.swift](../demos/super-thread-carousel/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/tag-filter-morph/README.md](../demos/tag-filter-morph/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/tag-filter-morph/build.py)、[main.swift](../demos/tag-filter-morph/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/tag-glass-morph/README.md](../demos/tag-glass-morph/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/tag-glass-morph/build.py)、[main.swift](../demos/tag-glass-morph/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/tag-selection-preview/README.md](../demos/tag-selection-preview/README.md) | 构建输入/参数/组件归属核对；[index.html](../demos/tag-selection-preview/index.html) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/thread-card-cloud/README.md](../demos/thread-card-cloud/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/thread-card-cloud/build.py)、[main.swift](../demos/thread-card-cloud/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [demos/thread-panel-transition/README.md](../demos/thread-panel-transition/README.md) | 构建输入/参数/组件归属核对；[build.py](../demos/thread-panel-transition/build.py)、[main.swift](../demos/thread-panel-transition/main.swift) | 未重建/启动；独立 fixture 无 Runtime/e2e 验收证明 |
| [design/composer.md](../design/composer.md) | 主路径/符号/约束静态核对；[NativeWorkspaceView.swift](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift)、[NativeMokuSceneState.swift](../app/macos/Sources/Host/MokuScene/NativeMokuSceneState.swift)、[NativeMokuDock.swift](../app/macos/Sources/Host/MokuScene/NativeMokuDock.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [design/markdown.md](../design/markdown.md) | 主路径/符号/约束静态核对；[Package.swift](../app/macos/Package.swift)、[NativeMarkdownView.swift](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownView.swift)、[NativeMarkdownText.swift](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownText.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [design/motion.md](../design/motion.md) | 主路径/符号/约束静态核对；[NativeOverviewCloudRenderer.swift](../app/macos/Sources/Shared/PluginUI/Design/NativeOverviewCloudRenderer.swift)、[NativeReadingPanelTransition.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift)、[NativeReadingPanelReturn.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelReturn.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [design/note-exposure.md](../design/note-exposure.md) | 主路径/符号/约束静态核对；[NativeMokuNote.swift](../app/macos/Sources/Host/MokuScene/NativeMokuNote.swift)、[NativeMarkdownView.swift](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownView.swift)、[moku.go](../internal/core/runtime/moku.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [design/overview.md](../design/overview.md) | 主路径/符号/约束静态核对；[NativeOverviewLayout.swift](../app/macos/Sources/Host/Overview/NativeOverviewLayout.swift)、[NativeOverviewCamera.swift](../app/macos/Sources/Host/Overview/NativeOverviewCamera.swift)、[ThreadCardText.swift](../app/macos/Sources/Shared/PluginUI/Cards/ThreadCardText.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [design/reading.md](../design/reading.md) | 主路径/符号/约束静态核对；[ThreadConversation.swift](../app/macos/Sources/Shared/PluginUI/Conversation/ThreadConversation.swift)、[ThreadExecutionGroups.swift](../app/macos/Sources/Shared/PluginUI/Conversation/ThreadExecutionGroups.swift)、[NativeHarnessThreadSurface.swift](../app/macos/Sources/Host/HarnessHost/NativeHarnessThreadSurface.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [design/thread-open-animation-profile/sampling-notes.txt](../design/thread-open-animation-profile/sampling-notes.txt) | 测量制品/来源/限制核对；[closing-updates.json](../design/thread-open-animation-profile/closing-updates.json)、[compositor-observation.json](../design/thread-open-animation-profile/compositor-observation.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [docs/coverage.md](coverage.md) | 流程/配置静态核对；[facts.md](facts.md) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [docs/facts.md](facts.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[ci.yml](../.github/workflows/ci.yml)、[Makefile](../Makefile) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [internal/README.md](../internal/README.md) | 主路径/符号/约束静态核对；[bootstrap.go](../internal/core/composition/bootstrap.go)、[check.go](../internal/tooling/architecture/check.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/core/model/README.md](../internal/core/model/README.md) | 主路径/符号/约束静态核对；[commands.go](../internal/core/model/commands.go)、[command_validation.go](../internal/core/model/command_validation.go)、[validate.go](../internal/core/model/validate.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/core/plugin/README.md](../internal/core/plugin/README.md) | 主路径/符号/约束静态核对；[harness.go](../internal/core/plugin/harness.go)、[bootstrap.go](../internal/core/composition/bootstrap.go)、[metadata.go](../internal/core/plugin/metadata.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/core/runtime/README.md](../internal/core/runtime/README.md) | 主路径/符号/约束静态核对；[runtime.go](../internal/core/runtime/runtime.go)、[bootstrap.go](../internal/core/composition/bootstrap.go)、[threads.go](../internal/core/runtime/threads.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/core/store/README.md](../internal/core/store/README.md) | 主路径/符号/约束静态核对；[store.go](../internal/core/store/store.go)、[sqlite.go](../internal/core/store/sqlite.go)、[snapshot.go](../internal/core/store/snapshot.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/hosts/applicationhost/README.md](../internal/hosts/applicationhost/README.md) | 主路径/符号/约束静态核对；[plugin_preferences.go](../internal/core/composition/plugin_preferences.go)、[runner.go](../internal/plugins/applications/background/runner.go)、[registry.go](../internal/hosts/applicationhost/registry.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/hosts/contexthost/README.md](../internal/hosts/contexthost/README.md) | 主路径/符号/约束静态核对；[host.go](../internal/hosts/contexthost/host.go)、[collect.go](../internal/hosts/contexthost/collect.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/platform/daemon/README.md](../internal/platform/daemon/README.md) | 主路径/符号/约束静态核对；[manager.go](../internal/platform/daemon/manager.go)、[service.go](../internal/platform/daemon/service.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/platform/discovery/README.md](../internal/platform/discovery/README.md) | 主路径/符号/约束静态核对；[cache.go](../internal/platform/discovery/cache.go)、[source.go](../internal/platform/discovery/source.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/platform/profile/README.md](../internal/platform/profile/README.md) | 主路径/符号/约束静态核对；[profile.go](../internal/platform/profile/profile.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/platform/transport/README.md](../internal/platform/transport/README.md) | 主路径/符号/约束静态核对；[protocol.go](../internal/platform/transport/protocol.go)、[receipts.go](../internal/platform/transport/receipts.go)、[receipt_query.go](../internal/platform/transport/receipt_query.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/README.md](../internal/plugins/README.md) | 主路径/符号/约束静态核对；[bootstrap.go](../internal/core/composition/bootstrap.go)、[check.go](../internal/tooling/architecture/check.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/applications/git/README.md](../internal/plugins/applications/git/README.md) | 主路径/符号/约束静态核对；[monitor.go](../internal/plugins/applications/git/monitor.go)、[client.go](../internal/plugins/applications/git/client.go)、[domain.go](../internal/plugins/applications/git/domain.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/applications/report/README.md](../internal/plugins/applications/report/README.md) | 主路径/符号/约束静态核对；[plugin.go](../internal/plugins/applications/report/plugin.go)、[domain.go](../internal/plugins/applications/report/domain.go)、[model.go](../internal/plugins/applications/report/model.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/applications/report/instructions.txt](../internal/plugins/applications/report/instructions.txt) | 生产 prompt 与 schema/绑定核对；[plugin.go](../internal/plugins/applications/report/plugin.go) | 未修改执行输入；指令文本不保证模型实际遵守 |
| [internal/plugins/applications/tag/README.md](../internal/plugins/applications/tag/README.md) | 主路径/符号/约束静态核对；[plugin.go](../internal/plugins/applications/tag/plugin.go)、[tools.go](../internal/plugins/applications/tag/tools.go)、[generate-tag-emoji.py](../scripts/generate-tag-emoji.py) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/applications/tag/instructions.txt](../internal/plugins/applications/tag/instructions.txt) | 生产 prompt 与 schema/绑定核对；[tools.go](../internal/plugins/applications/tag/tools.go)、[plugin.go](../internal/plugins/applications/tag/plugin.go) | 未修改执行输入；指令文本不保证模型实际遵守 |
| [internal/plugins/contexts/artificialanalysis/README.md](../internal/plugins/contexts/artificialanalysis/README.md) | 主路径/符号/约束静态核对；[plugin.go](../internal/plugins/contexts/artificialanalysis/plugin.go)、[source.go](../internal/plugins/contexts/artificialanalysis/source.go)、[parser.go](../internal/plugins/contexts/artificialanalysis/parser.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/harness/claude/README.md](../internal/plugins/harness/claude/README.md) | 主路径/符号/约束静态核对；[harness.go](../internal/plugins/harness/claude/harness.go)、[session.go](../internal/plugins/harness/claude/session.go)、[transport.go](../internal/plugins/harness/claude/transport.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/harness/codex/README.md](../internal/plugins/harness/codex/README.md) | 主路径/符号/约束静态核对；[adapter.go](../internal/plugins/harness/codex/adapter.go)、[executable.go](../internal/plugins/harness/codex/executable.go)、[native.go](../internal/plugins/harness/codex/native.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/harness/opencode/README.md](../internal/plugins/harness/opencode/README.md) | 主路径/符号/约束静态核对；[account.go](../internal/plugins/harness/opencode/account.go)、[adapter.go](../internal/plugins/harness/opencode/adapter.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/plugins/harness/pi/README.md](../internal/plugins/harness/pi/README.md) | 主路径/符号/约束静态核对；[adapter.go](../internal/plugins/harness/pi/adapter.go)、[bridge.go](../internal/plugins/harness/pi/bridge.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/services/attachments/README.md](../internal/services/attachments/README.md) | 主路径/符号/约束静态核对；[repository.go](../internal/services/attachments/repository.go)、[RuntimeAttachmentLease.swift](../app/macos/Sources/Core/RuntimeAttachmentLease.swift) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/services/moku/README.md](../internal/services/moku/README.md) | 主路径/符号/约束静态核对；[coordinator.go](../internal/services/moku/coordinator.go)、[ports.go](../internal/services/moku/ports.go)、[tool_schema.go](../internal/services/moku/tool_schema.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/services/moku/catalog-evidence.md](../internal/services/moku/catalog-evidence.md) | 主路径/符号/约束静态核对；[cache.go](../internal/platform/discovery/cache.go)、[source.go](../internal/platform/discovery/source.go)、[tool_schema.go](../internal/services/moku/tool_schema.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/services/threadsearch/README.md](../internal/services/threadsearch/README.md) | 主路径/符号/约束静态核对；[grep.go](../internal/services/threadsearch/grep.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [internal/services/workspaces/README.md](../internal/services/workspaces/README.md) | 主路径/符号/约束静态核对；[manager.go](../internal/services/workspaces/manager.go)、[thread.go](../internal/services/workspaces/thread.go)、[git.go](../internal/services/workspaces/git.go) | 限源码与引用；异常/竞态/环境行为未经动态认证 |
| [scripts/ci/README.md](../scripts/ci/README.md) | 流程/配置静态核对；[ci.yml](../.github/workflows/ci.yml)、[scope.py](../scripts/ci/scope.py)、[PBT inventory](../tools/verification/pbt/properties.json) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [scripts/ci/self-hosted.md](../scripts/ci/self-hosted.md) | 流程/配置静态核对；[ci.yml](../.github/workflows/ci.yml)、[overview-performance.yml](../.github/workflows/overview-performance.yml)、[macos-runner-preflight.py](../scripts/ci/macos-runner-preflight.py) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [scripts/ci/verification-policy.md](../scripts/ci/verification-policy.md) | 流程/配置静态核对；[AGENTS.md](../AGENTS.md)、[Makefile](../Makefile)、[ci.yml](../.github/workflows/ci.yml) | 限已配置流程；不代表远程门禁或行为覆盖通过 |
| [tools/benchmarks/README.md](../tools/benchmarks/README.md) | CLI/采集口径静态核对；[adapter.py](../tools/benchmarks/adapter.py)、[badge_comparison.py](../tools/benchmarks/badge_comparison.py) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/benchmarks/REFERENCES.md](../tools/benchmarks/REFERENCES.md) | CLI/采集口径静态核对；[adapter.py](../tools/benchmarks/adapter.py)、[badge_comparison.py](../tools/benchmarks/badge_comparison.py) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/benchmarks/baselines/2026-11-13-combined-rendering.md](../tools/benchmarks/baselines/2026-11-13-combined-rendering.md) | 测量制品/来源/限制核对；[2026-11-13-combined-rendering.json](../tools/benchmarks/baselines/2026-11-13-combined-rendering.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/benchmarks/baselines/2026-11-13-live-cloud-candidates.md](../tools/benchmarks/baselines/2026-11-13-live-cloud-candidates.md) | 测量制品/来源/限制核对；[2026-11-13-live-cloud-candidates.json](../tools/benchmarks/baselines/2026-11-13-live-cloud-candidates.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/benchmarks/baselines/2026-11-13-rendering-costs.md](../tools/benchmarks/baselines/2026-11-13-rendering-costs.md) | 测量制品/来源/限制核对；[2026-11-13-rendering-costs.json](../tools/benchmarks/baselines/2026-11-13-rendering-costs.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/benchmarks/baselines/2026-11-13-runtime-clock.md](../tools/benchmarks/baselines/2026-11-13-runtime-clock.md) | 测量制品/来源/限制核对；[2026-11-13-runtime-clock.json](../tools/benchmarks/baselines/2026-11-13-runtime-clock.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/benchmarks/baselines/2026-11-13-shared-prebaked.md](../tools/benchmarks/baselines/2026-11-13-shared-prebaked.md) | 测量制品/来源/限制核对；[2026-11-13-shared-prebaked.json](../tools/benchmarks/baselines/2026-11-13-shared-prebaked.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/benchmarks/baselines/2026-11-13.md](../tools/benchmarks/baselines/2026-11-13.md) | 测量制品/来源/限制核对；[2026-11-13.json](../tools/benchmarks/baselines/2026-11-13.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/benchmarks/baselines/2026-11-14-emoji-badge-glass.md](../tools/benchmarks/baselines/2026-11-14-emoji-badge-glass.md) | 测量制品/来源/限制核对；[2026-11-14-emoji-badge-glass.json](../tools/benchmarks/baselines/2026-11-14-emoji-badge-glass.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/benchmarks/reading/README.md](../tools/benchmarks/reading/README.md) | CLI/采集口径静态核对；[__init__.py](../tools/benchmarks/reading/__init__.py)、[analysis.py](../tools/benchmarks/reading/analysis.py) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/native-interaction/README.md](../tools/native-interaction/README.md) | CLI/采集口径静态核对；[client.py](../tools/native-interaction/client.py) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/README.md](../tools/verification/README.md) | CLI/采集口径静态核对；[native_replay.py](../tools/verification/native_replay.py) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/moku-note-performance/README.md](../tools/verification/moku-note-performance/README.md) | CLI/采集口径静态核对；[provenance.json](../tools/verification/moku-note-performance/evidence/provenance.json)、[diagnostic-counts.json](../tools/verification/moku-note-performance/evidence/diagnostic-counts.json)、[interaction.json](../tools/verification/moku-note-performance/evidence/interaction.json) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/moku-note-performance/evidence/capture.txt](../tools/verification/moku-note-performance/evidence/capture.txt) | 测量制品/来源/限制核对；[diagnostic-counts.json](../tools/verification/moku-note-performance/evidence/diagnostic-counts.json)、[interaction.json](../tools/verification/moku-note-performance/evidence/interaction.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-ci-performance/README.md](../tools/verification/overview-ci-performance/README.md) | CLI/采集口径静态核对；[overview-performance.yml](../.github/workflows/overview-performance.yml) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/overview-ci-performance/runtime/README.md](../tools/verification/overview-ci-performance/runtime/README.md) | CLI/采集口径静态核对；[clock.go](../tools/verification/overview-ci-performance/runtime/clock.go)、[fixture.go](../tools/verification/overview-ci-performance/runtime/fixture.go) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/overview-glass/README.md](../tools/verification/overview-glass/README.md) | CLI/采集口径静态核对；[analyze.py](../tools/verification/overview-glass/analyze.py)、[geometry.py](../tools/verification/overview-glass/geometry.py) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/overview-glass/REPORT.md](../tools/verification/overview-glass/REPORT.md) | 测量制品/来源/限制核对；[host-environment.json](../tools/verification/overview-glass/evidence/host-environment.json)、[status.json](../tools/verification/overview-glass/evidence/status.json)、[baseline-five-status.json](../tools/verification/overview-glass/evidence/baseline-five-status.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-glass/evidence/developer-mode.txt](../tools/verification/overview-glass/evidence/developer-mode.txt) | 测量制品/来源/限制核对；[baseline-five-status.json](../tools/verification/overview-glass/evidence/baseline-five-status.json)、[geometry.json](../tools/verification/overview-glass/evidence/geometry.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-glass/evidence/instruments-templates.txt](../tools/verification/overview-glass/evidence/instruments-templates.txt) | 测量制品/来源/限制核对；[baseline-five-status.json](../tools/verification/overview-glass/evidence/baseline-five-status.json)、[geometry.json](../tools/verification/overview-glass/evidence/geometry.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-glass/evidence/macos-version.txt](../tools/verification/overview-glass/evidence/macos-version.txt) | 测量制品/来源/限制核对；[baseline-five-status.json](../tools/verification/overview-glass/evidence/baseline-five-status.json)、[geometry.json](../tools/verification/overview-glass/evidence/geometry.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-glass/evidence/power.txt](../tools/verification/overview-glass/evidence/power.txt) | 测量制品/来源/限制核对；[baseline-five-status.json](../tools/verification/overview-glass/evidence/baseline-five-status.json)、[geometry.json](../tools/verification/overview-glass/evidence/geometry.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-glass/evidence/swift-version.txt](../tools/verification/overview-glass/evidence/swift-version.txt) | 测量制品/来源/限制核对；[baseline-five-status.json](../tools/verification/overview-glass/evidence/baseline-five-status.json)、[geometry.json](../tools/verification/overview-glass/evidence/geometry.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-glass/evidence/xcode-version.txt](../tools/verification/overview-glass/evidence/xcode-version.txt) | 测量制品/来源/限制核对；[baseline-five-status.json](../tools/verification/overview-glass/evidence/baseline-five-status.json)、[geometry.json](../tools/verification/overview-glass/evidence/geometry.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-performance/README.md](../tools/verification/overview-performance/README.md) | CLI/采集口径静态核对；[analyze.py](../tools/verification/overview-performance/analyze.py)、[plot.py](../tools/verification/overview-performance/plot.py) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/overview-performance/RESULTS.md](../tools/verification/overview-performance/RESULTS.md) | 测量制品/来源/限制核对；[build.json](../tools/verification/overview-performance/evidence/round1/build.json)、[build.json](../tools/verification/overview-performance/evidence/round2/build.json)、[build.json](../tools/verification/overview-performance/evidence/round3/build.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-performance/SUMMARY.md](../tools/verification/overview-performance/SUMMARY.md) | 测量制品/来源/限制核对；[analyze.py](../tools/verification/overview-performance/analyze.py)、[plot.py](../tools/verification/overview-performance/plot.py) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-performance/evidence/baseline/summary.md](../tools/verification/overview-performance/evidence/baseline/summary.md) | 测量制品/来源/限制核对；[summary.json](../tools/verification/overview-performance/evidence/baseline/summary.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-performance/evidence/glass-run-3/summary.md](../tools/verification/overview-performance/evidence/glass-run-3/summary.md) | 测量制品/来源/限制核对；[build.json](../tools/verification/overview-performance/evidence/glass-run-3/build.json)、[metadata.json](../tools/verification/overview-performance/evidence/glass-run-3/metadata.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-performance/evidence/round1/summary.md](../tools/verification/overview-performance/evidence/round1/summary.md) | 测量制品/来源/限制核对；[build.json](../tools/verification/overview-performance/evidence/round1/build.json)、[summary.json](../tools/verification/overview-performance/evidence/round1/summary.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-performance/evidence/round2/summary.md](../tools/verification/overview-performance/evidence/round2/summary.md) | 测量制品/来源/限制核对；[build.json](../tools/verification/overview-performance/evidence/round2/build.json)、[summary.json](../tools/verification/overview-performance/evidence/round2/summary.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/overview-performance/evidence/round3/summary.md](../tools/verification/overview-performance/evidence/round3/summary.md) | 测量制品/来源/限制核对；[build.json](../tools/verification/overview-performance/evidence/round3/build.json)、[summary.json](../tools/verification/overview-performance/evidence/round3/summary.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/pbt/README.md](../tools/verification/pbt/README.md) | 属性/入口/域/判据静态核对；[properties.json](../tools/verification/pbt/properties.json)、[run.py](../tools/verification/pbt/run.py)、[Makefile](../Makefile) | 11 个声明属性；常规与可选分开，不把未运行、缺失 capability 或历史结果当通过 |
| [tools/verification/runtime-performance/AUDIT.md](../tools/verification/runtime-performance/AUDIT.md) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[sources.json](../tools/verification/runtime-performance/results/20261025/sources.json)、[summary.json](../tools/verification/runtime-performance/results/20261025/summary.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/runtime-performance/README.md](../tools/verification/runtime-performance/README.md) | CLI/采集口径静态核对；[application_scenarios.go](../tools/verification/runtime-performance/application_scenarios.go)、[main.go](../tools/verification/runtime-performance/main.go) | 限当前参数/生产边界；不认证 live/GUI/当前性能 |
| [tools/verification/runtime-performance/results/20261025/README.md](../tools/verification/runtime-performance/results/20261025/README.md) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[queue-controls.json](../tools/verification/runtime-performance/results/20261025/queue-controls.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/runtime-performance/results/20261025/negative-control-precheck.go.txt](../tools/verification/runtime-performance/results/20261025/negative-control-precheck.go.txt) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[queue-controls.json](../tools/verification/runtime-performance/results/20261025/queue-controls.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/runtime-performance/results/20261025/negative-control-relay-delegate.go.txt](../tools/verification/runtime-performance/results/20261025/negative-control-relay-delegate.go.txt) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[queue-controls.json](../tools/verification/runtime-performance/results/20261025/queue-controls.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/runtime-performance/results/20261025/relay-control-fixed.log.txt](../tools/verification/runtime-performance/results/20261025/relay-control-fixed.log.txt) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[queue-controls.json](../tools/verification/runtime-performance/results/20261025/queue-controls.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/runtime-performance/results/20261025/relay-control-unfixed.log.txt](../tools/verification/runtime-performance/results/20261025/relay-control-unfixed.log.txt) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[queue-controls.json](../tools/verification/runtime-performance/results/20261025/queue-controls.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/runtime-performance/results/20261025/runner.py.txt](../tools/verification/runtime-performance/results/20261025/runner.py.txt) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[queue-controls.json](../tools/verification/runtime-performance/results/20261025/queue-controls.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |
| [tools/verification/runtime-performance/results/20261025/summarize.py.txt](../tools/verification/runtime-performance/results/20261025/summarize.py.txt) | 测量制品/来源/限制核对；[manifest.json](../tools/verification/runtime-performance/results/20261025/manifest.json)、[queue-controls.json](../tools/verification/runtime-performance/results/20261025/queue-controls.json) | 仅记录的版本/制品；未重测、未重算全部统计，不认证当前源码 |

## 输入路径到当前事实所有者

输入路径是范围标识；规格正文使用右栏的当前文件。此映射只连接事实归属，
不保存调查叙事、旧设计、迁移过程或未来计划。各所有者的实现/验证限制见上表。

| 输入路径标识 | 当前事实所有者 | 核对边界 |
| --- | --- | --- |
| `app/macos/build/layout-logging.md` | [app/macos/build/README.md](../app/macos/build/README.md)、[业务证据边界](../internal/README.md#business-evidence) | 无 layout/performance 日志实现；启动 PID 回执及退出 helper 独立存在 |
| `demos/execution-handoff/validation.md` | [demos/execution-handoff/README.md](../demos/execution-handoff/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `demos/moku-panel-transition/evidence/validation.md` | [demos/moku-panel-transition/README.md](../demos/moku-panel-transition/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `demos/super-thread-carousel/collection-expansion-validation.md` | [demos/super-thread-carousel/README.md](../demos/super-thread-carousel/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `demos/super-thread-carousel/collection-panel-validation.md` | [demos/super-thread-carousel/README.md](../demos/super-thread-carousel/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `demos/super-thread-carousel/regular-glass-validation.md` | [demos/super-thread-carousel/README.md](../demos/super-thread-carousel/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `demos/super-thread-carousel/validation.md` | [demos/super-thread-carousel/README.md](../demos/super-thread-carousel/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/agent-detail-dark-tone.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/agent-detail-entry-orbit.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/agent-thread-execution-heading-regression.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/animation-main-thread.md` | [design/motion.md](../design/motion.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/attributegraph-focus-20261114.md` | [design/motion.md](../design/motion.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/browser-annotation-resident-input.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/card-status-layout-shift.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/detail-background-optimization.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/direct-send-transition.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/documentation-audit-2026-11-04.md` | [docs/coverage.md](coverage.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/emoji-title-transition-handoff.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/empty-execution-summary.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/execution-composer-focus.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/execution-handoff-production.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/execution-route-slide.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/history-author-title-transition.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/maintenance-integration-2026-11-04.md` | [README.md](../README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/markdown-code-block-clipping.md` | [design/markdown.md](../design/markdown.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/markdown-layout-performance.md` | [design/markdown.md](../design/markdown.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/markdown-repeat-visit-performance.md` | [design/markdown.md](../design/markdown.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/message-settlement-flicker.md` | [design/markdown.md](../design/markdown.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/moku-character-rollback.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/moku-input-card-dimming.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/moku-talk-note-handoff.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/moku-talk-note-transition.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/note-read-awareness-implementation.md` | [design/note-exposure.md](../design/note-exposure.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/note-read-awareness.md` | [design/note-exposure.md](../design/note-exposure.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/overview-click-refit-investigation.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/overview-fitall-layout.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/reader-8k-performance.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/reader-active-opening-20261114.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/reader-opening-20261114.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/reading-entrance-choreography.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/reading-placeholder-alignment.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/related-thread-fade.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/remove-reduce-motion.md` | [design/motion.md](../design/motion.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/report-execution-continuation.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/report-sidecard-admission.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/report-sidecard-close.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/sidecard-fold-performance.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/steer-message-identity.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/super-thread-animated-covers.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/super-thread-associated-open.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/super-thread-collection-ink.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/super-thread-cover-flicker.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/super-thread-cover-layout.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/super-thread-cover-top-space.md` | [design/overview.md](../design/overview.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/terminal-assistant-disclosure.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-attachment-ownership.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-detail-input-dismissal.md` | [design/composer.md](../design/composer.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-loading-performance-cache.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-open-animation-investigation.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-open-window-backdrop.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-opening-admission.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-opening-entry-admission.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-overview-isolation.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-scroll-observation.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `design/thread-transition-latency.md` | [design/reading.md](../design/reading.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `internal/platform/diagnostics/README.md` | [业务证据边界](../internal/README.md#business-evidence)、[Moku](../internal/services/moku/README.md) | 无私有 service/tool/settings 日志接口；transcript、usage、receipt 与用户错误保留 |
| `internal/plugins/harness/codex/t3-discovery.md` | [internal/services/moku/catalog-evidence.md](../internal/services/moku/catalog-evidence.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `internal/plugins/harness/pi/catalog-receipts.md` | [internal/plugins/harness/pi/README.md](../internal/plugins/harness/pi/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `internal/services/moku/t3-native-discovery.md` | [internal/services/moku/catalog-evidence.md](../internal/services/moku/catalog-evidence.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |
| `tools/verification/runtime-performance/HANDOFF.md` | [tools/verification/runtime-performance/README.md](../tools/verification/runtime-performance/README.md) | 约束归属/引用核对；不沿用输入文档的运行通过声明 |

## 第三方原文与生成数据范围

这些条目不作为自有规格重写；来源/消费者/存在性纳入范围核对，不宣称第三方内容由本项目验证。

| 路径 | 范围边界 |
| --- | --- |
| [.agents/skills/LICENSE](../.agents/skills/LICENSE) | 第三方 skill 许可证，原文保留 |
| [app/macos/Sources/Shared/PluginUI/Resources/fonts/inter-LICENSE.txt](../app/macos/Sources/Shared/PluginUI/Resources/fonts/inter-LICENSE.txt) | 第三方字体许可证，原文保留 |
| [app/macos/Sources/Shared/PluginUI/Resources/fonts/jetbrains-mono-LICENSE.txt](../app/macos/Sources/Shared/PluginUI/Resources/fonts/jetbrains-mono-LICENSE.txt) | 第三方字体许可证，原文保留 |
| [app/macos/Sources/Shared/PluginUI/Resources/icons/lucide-LICENSE.txt](../app/macos/Sources/Shared/PluginUI/Resources/icons/lucide-LICENSE.txt) | 第三方图标许可证，原文保留 |
| [internal/plugins/applications/report/eli5-skill.md](../internal/plugins/applications/report/eli5-skill.md) | 第三方原文快照/生产输入；仅核对本地 hash 与 attribution，不改正文 |
| [internal/services/taglabel/UNICODE-LICENSE.txt](../internal/services/taglabel/UNICODE-LICENSE.txt) | Unicode 许可证，原文保留 |
| [internal/services/taglabel/emoji.txt](../internal/services/taglabel/emoji.txt) | 第三方 Unicode 生成表；核对来源/消费者，不逐行重写 |

## 覆盖的能力界限

逐文件映射不认证真实账户、硬件语音、输入权限、WindowServer 中间帧、并发取消、
长时内存、原生构建或当前性能预算。构建、链接和静态核查结果须关联实际提交与运行记录；
PBT/e2e/benchmark 结论须关联实际 runner 与制品，不能从入口齐全推导行为已通过。
外部出处只记录本地版本/归属，不表示逐一联网核实其最新状态。
远程 required checks 和 `Complete coverage` 状态、独立 GLM-5.3 审查结果由各自实际记录证明，
本表不声明这些门禁或审查已完成。
