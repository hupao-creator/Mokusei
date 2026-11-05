# Report Thread 原生交互提案

保留已确认的卡片对照提案，并提供正式 Report 卡片、分栏与 HTML surface 的确定性 fixture。预览不启动 Runtime 或 Agent。生产 Report 契约与 Host execution reader 已接入；此处的 execution factory 仍注入固定正文，不能认证真实 Harness 内容订阅。

- Report fixture 独立持有 `emoji`、`shortDescription` 与关联 executions。
- 卡片沿用普通 Agent Thread 的 360×200pt 尺寸、18pt 内边距、15pt 单行标题与右上角 44pt emoji 座位。摘要复用 `ThreadCardExcerpt`；emoji 复用 `ThreadCardProviderStatus`。
- 标题下方按关联 execution 的 harness 去重显示 12pt 生产 logo，并在同一行展示更新时间。多来源样本包含 Codex ×3、Claude ×2；同一 harness 仅关联一个 Thread 时不显示数量，侧卡中的执行也标识对应 harness。
- 整张卡片可点击，不单独放置“打开报告”按钮。不显示关联 Thread / execution，也不附加文档 icon 或“报告”类型标签。
- 卡片预览并排展示一个真实 `HarnessThreadCard`，便于比较同一尺寸下的标题、emoji、元信息、摘要、材质及间距。
- 打开后右侧列出关联 execution，侧卡与报告正文为 **2:8**（不含 16pt 间距）；报告始终在左侧。
- 点击 execution 后原侧卡变成该执行的阅读区，与报告正文为 **5:5**。
- 侧卡顶部返回按钮回到关联列表；Escape 先返回列表，再收起报告。报告关闭按钮直接回到卡片。
- 报告的同一个 WKWebView 在列表与 execution 切换之间保持挂载，保留阅读位置；窄列自动把报告中的统计块排成单列。

复用生产 `HarnessThreadCard`（对照）、`ThreadCardExcerpt`、`ThreadCardProviderStatus`、`NativeTypography`、`NativePalette`、`NativeIcon`、`NativeScrollView`、`ThreadMessage`、`NativeReadingPanelCloseButton` 与 Moku Dock。默认模式保留设计对照；`--production` 使用正式 Report 卡片、分栏和 HTML surface。底部 Moku 为环境参照，不接收输入。

## 运行

```sh
python3 demos/report-thread/build.py --production --open
```

生产原生模块已构建且没有变更时，可加 `--skip-build`。App 打包到隔离临时目录，路径保存在 `.build/report-thread/app-path.txt`。预览窗口顶部可切换三种状态和浅深色；⌘1 / ⌘2 / ⌘3 也可切换。窗口最小宽度为 1060pt，以保持本轮指定比例。

## 视觉复核

```sh
python3 demos/report-thread/build.py --skip-build --capture --open
```

截取卡片、2:8 列表、两条 execution、返回列表、深色与窄窗口状态，记录实际挂载后的面板几何到 `.build/report-thread/evidence/geometry.json`。这是设计预览，不运行 XCTest 或完整 CI，不认证生产数据契约。

## 本次本地验证（2026-11-05）

- Swift Debug 生产构建、`make lint`（架构检查及 Go vet）通过。
- Report 与 Application Host 的 race 测试通过；Application Host、Runtime 和 Thread Search race 集成回放通过。
- `reading-presentation --report-navigation` 四个原生用例通过。首次运行的关闭点击仍定位旧的右上角；修正为实际左上角圆形命中区的边缘位置后，保留并通过原有关闭动画和返回断言。
- 正式组件 fixture 实际点击卡片、两条关联执行、返回列表及 HTML 内 Escape；HTML 的 WebKit 文档身份保持不变。
- 用户指定仅合入本地 main；未创建远端 PR、未运行托管 CI，未运行全套 `make check`。数量标记追加前，签名生产 Release 导航（300 次随机交互）及阅读（三个种子与 trace 重放）通过。追加后重新构建最终签名产物，导航 `--steps 10`（30 次随机交互）及阅读 `--steps 10 --seeds 41`（含 trace 重放）通过；正式卡片的 Codex ×3、Claude ×2 已检查实际渲染和辅助功能标签。组件 fixture 不单独认证真实 Harness 订阅。
