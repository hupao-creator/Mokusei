# Moku 外观回滚交接

本次基于 `2b6a447`，只在 `moku-sphere-rollback` detached worktree 提交。
不 push、不修改主检出，由调用方统一合入 main。

## 历史边界

日期均为 2026-11-10，UTC+08:00。

| 提交 | 时间 | 标题与作用 |
| --- | --- | --- |
| `3dd5e5a2c58d75cf3542fc00e0f2f5d6cffc3966` | 15:26:04 | Show Harness glass artwork on the Settings Moku Map；首先引入地图球体 PNG。 |
| `51d736c609d420004f24d0db16e41d6abcfcac09` | 17:02:17 | Rebrand Moku as a Harness-colored glass orb；将 Dock 改为球形并引入 Harness 渐变主题。 |
| `656f071538ec6f6ede8d6432648f89115268ab71` | 17:37:26 | Remove remaining Moku eyes and keep native input reachable；移除剩余眼睛，同时修复原生输入。 |

完整带眼睛基线：`51b489f50bf5f2ce39a88d746e54f4b2c5114bf4`，14:24:52，
**Preserve injected Codex tool schemas in developer instructions**，即 `3dd5e5a^`。
Dock 球形化的直接父提交是 `3dd5e5a`，其中 Settings 地图已经球形化、Dock 仍带眼睛。

采用选择性恢复文件/符号，避免整批 revert 覆盖输入修复和后续功能。
按用户追加要求，同时恢复 `bec078f`（18:01:48，Center the Moku note history action in the panel footer）
之前的历史按钮右侧布局，以及 `acbebd0`（18:06:02，Make Settings follow appearance without Liquid Glass）
之前的 Settings 玻璃材质与固定深色环境。

## 逐文件摘要

路径均相对仓库根目录。删除的文件只列路径。

| 文件 | 改动 |
| --- | --- |
| [app/macos/Sources/Host/ApplicationHost/NativeApplicationBackgroundEditor.swift](../app/macos/Sources/Host/ApplicationHost/NativeApplicationBackgroundEditor.swift) | 将角色模式和 Harness 选项材质恢复为交互玻璃，删除 NativeBackgroundChoiceSurface；选项逻辑不变。 |
| [app/macos/Sources/Host/Moku/MokuCharacterView.swift](../app/macos/Sources/Host/Moku/MokuCharacterView.swift) | 恢复原生矢量角色、控制器与角色绘制生命周期。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuCapsule.swift](../app/macos/Sources/Host/MokuScene/NativeMokuCapsule.swift) | 恢复 168×44 胶囊、眼睛几何和原暖色玻璃；删除球形展开渐变及 PNG 绘制。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuCapsuleBlink.swift](../app/macos/Sources/Host/MokuScene/NativeMokuCapsuleBlink.swift) | 恢复历史输入的眨眼视图和时间采样；不恢复无调用方的旧回放专用 BlinkClock。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuCharacterMotion.swift](../app/macos/Sources/Host/MokuScene/NativeMokuCharacterMotion.swift) | 恢复常驻眼睛绘制、表情过渡、眨眼唤醒及暂停；环绕算法保持原样。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuComposer.swift](../app/macos/Sources/Host/MokuScene/NativeMokuComposer.swift) | 恢复眼睛占位和历史输入眼睛；保留草稿、附件、补全与发送逻辑。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuDock.swift](../app/macos/Sources/Host/MokuScene/NativeMokuDock.swift) | 恢复眼睛座位及 Settings 头部位移、眼睛点击入口和右侧 Stop；历史按钮恢复右侧。保留输入监视器修复、语音高度修复与消息居中。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuDockIdentity.swift](../app/macos/Sources/Host/MokuScene/NativeMokuDockIdentity.swift) | 恢复 Moku 眼睛与 Agent Harness 标志之间的身份呈现。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuSceneState.swift](../app/macos/Sources/Host/MokuScene/NativeMokuSceneState.swift) | 恢复持久化的 Settings 角色控制器；导航状态不变。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuSwipe.swift](../app/macos/Sources/Host/MokuScene/NativeMokuSwipe.swift) | 恢复消息/派发/语音状态的眼睛手势区域和控制排除区。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuTalkContent.swift](../app/macos/Sources/Host/MokuScene/NativeMokuTalkContent.swift) | 为眼睛恢复 64pt 左侧空间，并使用对称边距保持后续消息居中、半粗体。 |
| [app/macos/Sources/Host/MokuScene/NativeMokuTimerBar.swift](../app/macos/Sources/Host/MokuScene/NativeMokuTimerBar.swift) | 恢复提醒条的惊讶眼睛；确认、铃声和队列逻辑不变。 |
| [app/macos/Sources/Host/MokuScene/README.md](../app/macos/Sources/Host/MokuScene/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [app/macos/Sources/Host/Settings/NativeMokuSettings.swift](../app/macos/Sources/Host/Settings/NativeMokuSettings.swift) | 恢复协调角色的矢量绘制、身体与眼睛动画，删除球体 MapLogo 视图；表单逻辑不变。 |
| [app/macos/Sources/Host/Settings/NativeMokuSettingsAnimationState.swift](../app/macos/Sources/Host/Settings/NativeMokuSettingsAnimationState.swift) | 恢复换乘和目标反馈的眼睛动画轨道。 |
| [app/macos/Sources/Host/Settings/NativeMokuSettingsMotion.swift](../app/macos/Sources/Host/Settings/NativeMokuSettingsMotion.swift) | 恢复注视关键帧与采样；保留原身体、引擎和目标运动。 |
| [app/macos/Sources/Host/Settings/NativeRoleConfigurationPanel.swift](../app/macos/Sources/Host/Settings/NativeRoleConfigurationPanel.swift) | 将不透明面板恢复为 Regular Liquid Glass，保留 Reduce Transparency fallback；Tag/Report 动画不变。 |
| [app/macos/Sources/Host/Settings/NativeSettingsPage.swift](../app/macos/Sources/Host/Settings/NativeSettingsPage.swift) | 恢复固定深色环境、头部眼睛占位和角色控制器传递；选项绑定、保存和校验不变。 |
| [app/macos/Sources/Host/Settings/NativeSettingsTransition.swift](../app/macos/Sources/Host/Settings/NativeSettingsTransition.swift) | 同步恢复玻璃表面的所有权注释；过渡逻辑不变。 |
| [app/macos/Sources/Host/Settings/README.md](../app/macos/Sources/Host/Settings/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [app/macos/Sources/Host/Shell/NativeWorkspaceView.swift](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift) | 移除球形主题环境注入，恢复 Settings 角色控制器传递。 |
| `app/macos/Sources/Shared/PluginUI/Design/NativeMokuMapLogoArtwork.swift` | 删除球形 PNG 加载、缩略图缓存和裁切实现。 |
| `app/macos/Sources/Shared/PluginUI/Design/NativeMokuTheme.swift` | 删除球形专用 Harness 配色、亮度计算、渐变插值、Stop 墨色和环境键。 |
| [app/macos/Sources/Shared/PluginUI/README.md](../app/macos/Sources/Shared/PluginUI/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| `app/macos/Sources/Shared/PluginUI/Resources/moku-map/moku-map-claude.png` | 删除该 Harness 的球体 PNG；不改应用图标。 |
| `app/macos/Sources/Shared/PluginUI/Resources/moku-map/moku-map-codex.png` | 删除该 Harness 的球体 PNG；不改应用图标。 |
| `app/macos/Sources/Shared/PluginUI/Resources/moku-map/moku-map-opencode.png` | 删除该 Harness 的球体 PNG；不改应用图标。 |
| `app/macos/Sources/Shared/PluginUI/Resources/moku-map/moku-map-pi.png` | 删除该 Harness 的球体 PNG；不改应用图标。 |
| [app/macos/Tests/Integration/Host/NativeMokuNoteTests.swift](../app/macos/Tests/Integration/Host/NativeMokuNoteTests.swift) | 恢复现有调用的 eyesOnly: false 参数；断言和覆盖范围不变。 |
| [app/macos/Tests/Integration/Host/NativeMokuTalkTests.swift](../app/macos/Tests/Integration/Host/NativeMokuTalkTests.swift) | 恢复现有历史按钮右侧布局的宽度边界预期；没有新增用例。 |
| [app/macos/Tests/Integration/Host/NativeSettingsTransitionTests.swift](../app/macos/Tests/Integration/Host/NativeSettingsTransitionTests.swift) | 恢复现有深色玻璃面板的亮度预期；没有新增用例。 |
| [demos/README.md](../demos/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [demos/landing-setup/README.md](../demos/landing-setup/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [demos/moku-gradient-material/README.md](../demos/moku-gradient-material/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [demos/moku-mention-transition/README.md](../demos/moku-mention-transition/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| `demos/moku-orb-rebrand/README.md` | 删除仅用于球形方案的预览文件，避免引用已删除的主题 API。 |
| `demos/moku-orb-rebrand/build.py` | 删除仅用于球形方案的预览文件，避免引用已删除的主题 API。 |
| `demos/moku-orb-rebrand/main.swift` | 删除仅用于球形方案的预览文件，避免引用已删除的主题 API。 |
| `demos/moku-orb-rebrand/validation.md` | 删除仅用于球形方案的预览文件，避免引用已删除的主题 API。 |
| [demos/settings-navigation/README.md](../demos/settings-navigation/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [tools/verification/README.md](../tools/verification/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [tools/verification/moku-appearance/README.md](../tools/verification/moku-appearance/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [tools/verification/moku-appearance/main.swift](../tools/verification/moku-appearance/main.swift) | 恢复现有 headless 外观回放的深色 Settings 预期；未执行回放。 |
| [tools/verification/moku-orbit/README.md](../tools/verification/moku-orbit/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [tools/verification/moku-orbit/main.swift](../tools/verification/moku-orbit/main.swift) | 仅移除已删除的球形主题环境注入；环绕/推理断言与算法不变。 |
| [tools/verification/moku-reasoning/README.md](../tools/verification/moku-reasoning/README.md) | 同步当前外观、入口或验证范围文档，清除球形预览的失效链接。 |
| [tools/verification/moku-reasoning/main.swift](../tools/verification/moku-reasoning/main.swift) | 仅移除已删除的球形主题环境注入；环绕/推理断言与算法不变。 |

## 清理清单与保留边界

- 删除 `NativeMokuTheme`（含 `orbStops`、`deepTints`、RGB 亮度计算、`gradient(expansion:)`、`orbControlInk`、环境键与所有注入）。
- 删除 `NativeMokuMapLogoArtwork` 和 Codex、Claude、Pi、OpenCode 四张 `moku-map-*.png`。
- 删除 Settings 的球体 `NativeMokuMapLogo` 和材质内的球体 PNG、透明度遮罩及展开插值。
- 删除 `demos/moku-orb-rebrand/` 四个文件和文档入口。
- 删除历史按钮居中专用容器、对称控制空间、堆叠占位和高度变量。
- 删除不透明 Settings 专用 `NativeBackgroundChoiceSurface`，以旧玻璃实现替代 `NativeSettingsPanelSurface`。
- 不恢复无人调用的旧 `NativeMokuCapsuleBlinkClock`；生产眨眼由恢复的常驻角色时钟和时间采样负责。
- 旧暖色胶囊渐变属于带眼睛版本的材质，保留；球形专用渐变已清除。

Settings model/draft、模型能力校验、Tag 动画、Report、注意力整理、Loading 环绕路径与速度未改。
后续原生输入监视器零尺寸修复、语音期间保留草稿的高度修复、消息居中/半粗体保留。
未新增测试；仅同步三处现有测试及现有外观回放的预期。

## 验证范围

- 对比原提交：角色、眼睛、眨眼宿主、输入、身份、Timer 与 Settings 注视等 9 个恢复文件逐字节一致。
- 状态颜色定义和 Loading 几何文件与本次起始 HEAD 一致；Settings model/draft 未改。
- 已检查逐文件 diff、球形资源/API 残留引用和修改文档的本地链接。
- Headless 编译命令：`xcrun swift build --package-path app/macos --build-tests --force-resolved-versions --disable-index-store -j 2`。
- 编译日志：`/tmp/moku-sphere-rollback-build.log`。最终重新编译通过（退出码 0，最后一次 attempt 为 50.53 秒；该值不代表前面构建的总耗时）。
- 没有执行测试、图形回放、全套 `make check` 或托管 CI；没有本次运行的视觉帧验证结果。
- 首次命令在源码编译前遇到 SwiftPM 沙箱冲突；随后因追加范围更新源码，编译器拒绝了构建期间变更的输入。最终固定范围后重新编译，发现现有 Note 测试缺少恢复后的 `eyesOnly` 参数；补回 `false`，保持断言不变后再编译。失败日志保留于 `/tmp/moku-sphere-rollback-build-attempt-3.log`。
