# Moku 历史布局与主题

基于 `0a56037`（包含共享 Moku 历史面板 `5affdc8`）。
核查生产 `NativeAgentThreadWorkspace`：圆角 message 阅读卡片由自己的
surface/clip/border/Close 包住，底部 Moku Dock 由 workspace 的 scene 独立呈现。
`NativeWorkspaceView` 的 `preferredColorScheme` 将应用偏好映射为
light / dark / nil（跟随系统）。

Moku 历史现在只将 transcript、会话菜单和页面错误放在共享阅读卡片内，
把原有 `NativeMokuHistoryComposer` 放到卡片下面，间隔 12pt，水平中心对齐。
卡片继承应用主题，输入胶囊继续使用原有深色玻璃、编辑器与光标。
归档会话没有 composer；当前会话继续持有 workspace draft 和原来的回调。

## 隔离预览

```sh
python3 demos/moku-history-theme/build.py --open
# 已构建当前 Mokusei 产品：
python3 demos/moku-history-theme/build.py --skip-build --open
```

只编译 `--product Mokusei`，不使用 `--build-tests` 或测试运行器。
构建脚本复用 `NativeReplay` 的打包/签名与隔离基础设施，不运行其测试。
app 路径记在 `.build/moku-history-theme/app-path.txt`；临时 app、资源、
独立 profile 和工作目录放在 `/private/tmp/mokusei-native-replay-history-*`。

主窗口复用生产 `NativeMokuScene`、`NativeMokuThreadView`、Harness host、
`CodexThreadView`、`ThreadConversation`、Markdown、原生编辑器、Dock、Note 和共享面板。
fixture 在真实 content subscription 事件上提供内存 Codex 内容；
**不启动 RuntimeClient**，没有 Runtime、账户、模型请求或真实用户数据。
父页面仅为内存背景和打开入口，不模拟完整 Overview/Agent 导航。

控制窗口提供 light/dark/system、历史、关闭、Note、运行状态和三档窗口尺寸。
发送/停止仅修改 fixture 的运行状态；语音和附件服务没有接入真实设备/文件。

对脚本打印的临时 app 路径运行以下命令，可记录自身窗口的展示截图：

```sh
open -W -n /private/tmp/mokusei-native-replay-history-<id>/MokuHistoryPreview.app --args --capture
```

这是一段无断言的展示序列，不是测试或性能回放。生成浅/深/系统主题 ×
1200×800、760×600、420×420 窗口截图，以及关闭历史后的 Note 截图。
控件正常使用时仍可实际点选会话、滚动和编辑。

## 本次记录

- `xcrun swift build --package-path app/macos --product Mokusei` 成功。
- `xcrun swift build --package-path app/macos --product Mokusei -c release` 成功。
- 隔离预览编译成功；已查看浅/深主题三档窗口截图、system 窄窗口和 Note。
  窄窗口通过原有 reader 滚动浏览内容，Close 与输入胶囊没有重叠。
- 实际控件操作观察到：归档菜单切换为只读且移除 composer；原生编辑器
  通过无障碍赋值后显示文本和 Send；Escape 关闭后重新打开，草稿仍存在。
  自动键入/粘贴未改变编辑器文本，因此不将其记为键盘输入验证通过。
- 本地 review 检查卡片/胶囊边界、主题继承、草稿归属、回调、嵌套返回与
  会话只读逻辑，并完成 `git diff --check` 和文档链接核查。
- 首次沙箱构建因 SwiftPM/宏插件能力及网络限制失败，审批后生产构建成功。
  预览首次启动暴露 fixture 的 archived/transcript 契约遗漏，已修正。

截图保留在 [evidence](evidence)；例如 [浅色宽窗口](evidence/light-1200.png)、
[深色宽窗口](evidence/dark-1200.png)、[浅色窄窗口](evidence/light-420.png)、
[深色窄窗口](evidence/dark-420.png)、[Note](evidence/note-return.png)。

## 验证限制

按本次 sprint mode，没有新增或运行测试、历史测试、CI、测试 hooks 或
本地全套检查；没有推送或创建 PR。构建与人工预览不等同于回归测试通过。
跟随系统只观察当前系统解析结果，没有切换全局系统偏好来验证两端热切换。
没有接入真实 Runtime、历史加载、模型、语音、附件导入、IME、真实发送/停止，
也没有验证签名安装包及完整 Agent/Git/Report 返回路由、Reduce Motion 或逐帧转场。
本次未修改并行 Agent Thread 执行摘要修复所涉及的共享 Conversation/Harness 代码。
