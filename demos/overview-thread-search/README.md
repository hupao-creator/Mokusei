# 原生 Overview 搜索隔离回放

直接链接当前 Debug `MokuseiUI` 生产对象，复用
`NativeOverviewSearchTests.swift`；不复制搜索界面，不启动 runtime，不读取用户
profile、真实 thread、模型权重或外部推理服务。需要 macOS 26 / Xcode 26。

```sh
make check
xcrun swift test --package-path app/macos --filter NativeOverviewSearchTests
python3 demos/overview-thread-search/build.py
MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY=1 \
MOKUSEI_OVERVIEW_SEARCH_EVIDENCE="$PWD/.build/overview-thread-search/screenshots" \
.build/overview-thread-search/OverviewSearchReplay.app/Contents/MacOS/OverviewSearchReplay \
  --filter NativeOverviewSearchTests
```

SwiftPM 执行 metadata/目录同步、查询取消、自动准备与索引刷新及可见标签几何用例；
需要真实应用事件循环的用例由独立 app 提供 `NSApplication.run()` 后执行，失败返回非零。
回放直接链接共享 SwiftUIReplay 测试支持，不依赖 SwiftPM test host 的窗口事件循环。

选中 tag 搜索转场回放覆盖 1100、540、360 pt 与深浅色，捕获标签、展开中间态、搜索完成态、
关闭中途反转、关闭中间态和恢复标签；同时断言搜索控件的出现/移除及选中范围保持。
截图仅捕获 fixture window ID。回放放慢真实转场以检查中间帧；生产时长仍为 380 ms。
其他原生用例覆盖中文混合结果及连续搜索不捕获退出卡片。输出位置可省略以禁用截图。

混合结果使用受控 runtime 响应，证明真实原生 UI 的状态与排序；不代表真实
EmbeddingGemma 2 实际模型质量。完整 managed local process / HTTP / SQLite / 删除与清空链路由
[后端隔离回放](../../tools/verification/thread-search/README.md)验证。两者均不需要真实模型权重或凭据。

截图中的卡片来自只显示公开字段的测试 Harness（不是 Codex 插件私有数据），卡片
外层、画布、搜索与 glass 是正式生产组件；本 fixture 不伪造 emoji 行为或系统无障碍设置。

build.py 使用 Swift 6 / warnings-as-errors，按 `xcrun` 当前工具链找到 Swift Testing
框架和宏插件。产物及日志位于 Git 忽略的 `.build/overview-thread-search/`，不安装、
替换、重启 Dev。生产代码改动后先 `make check` 再重建 fixture。

生产选中 tag→搜索框展开、邻居排开渐隐与反向中断见 [当前搜索转场规格](../../app/macos/Sources/Host/Overview/README.md)。不链接独立搜索 demo 的源码或样本。
