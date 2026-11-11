# Regular Liquid Glass 生产落地验证

2026-11-11，基线 `d646bcf343d22c6eb65505f05057e7a97b875117`。
环境：macOS 26.5.1 (25F80)、Xcode 26.5 (17F42)、arm64。

## 生产改动与审查

- Super Thread collection policy 声明 `providesCardSurface`。该事实由真实
  Workspace projection 传给 Canvas，省略 collection 的不透明装饰底壳；
  玻璃位于正常传播几何的 semantic camera plane，普通卡片底色保持原样。
- Collection 提供一个连续的 22pt 圆角 regular glass 背板。封面在前景遮住
  上部，现有 4pt 间距由同一玻璃填满，不产生背景缝或独立 body 玻璃边缘。
- 仅 collection 的 emoji badge 显式启用 regular glass + 12% mint tint；
  保留共享 44pt 直径、metadata top 12 / trailing 17 座位，以及原本的打开、
  context menu、输入门禁、无障碍标签和正文揭示蒙版。
- 新材质 helper 在 Reduce Transparency 下使用不透明 palette 色；
  Liquid Glass 不可用时退回系统 regular Material。生产包最低仍为 macOS 26，
  未因此扩展旧系统支持，也未在旧 OS 运行。
- 未修改归组、关闭/阅读资格、轮播选择身份、460ms 时钟、10 秒 dwell、
  取消/可见性语义、原生 cover 输入、navigation 或 archive 回调。
- 审查补上了 Host collection 渲染失败时的实色错误底色，避免 renderer 让出
  外壳后错误文字失去可读背景。未新增测试用例或放宽既有断言。

## Sprint mode 后的最终 headless 验证

1. `xcrun swift build --package-path app/macos --product Mokusei
   --disable-sandbox --disable-automatic-resolution -j 4 -Xswiftc -warnings-as-errors`
   通过。最终增量构建包含错误底色修补，12.56 秒；没有启动 App。
2. `python3 demos/super-thread-carousel/build.py --skip-build --headless`
   通过。fixture 使用当前工作树生产对象，ad-hoc 签名与严格签名验证通过；
   在创建 NSApplication 前退出。输出 13 个数据场景和 30 行生产投影/生命周期
   记录，未创建窗口、未运行 Runtime 或模型任务。
3. 人工审阅其中 14 个 `surfaceOwners` 场景：初始/标签归组、短读返回、长期
   阅读移出、单成员解散、搜索和到期重新归组中，只有实际 collection 为 true；
   单篇 Report 和搜索结果始终为 false。保留的
   [原始投影子集与源码摘要](regular-glass-evidence.json) 对应最终 Swift 源码。
4. diff 空白、本地 Markdown 链接检查通过；提交 hook 的 `make lint` 执行
   architecture / static registration / no-Node、gofmt 和 Go vet，不运行回归测试。

日志位于 `.build/super-thread-glass/production-build-final.log`、
`production-headless-final.log`；完整 JSON 在 `.build/super-thread-carousel/`。

## Sprint mode 补充前的检查及失败记录

- 生产全量 Debug 编译 warnings-as-errors 通过，76.04 秒。
- 已有 `NativeOverviewMountingIntegrationTests` 与 `NativeReportStatusTests`
  共 12 个测试通过、零跳过，运行 23.106 秒（测试构建 77.77 秒）。这发生在
  sprint 补充前，且早于最后的错误底色修补；不作为最终提交的图形认证。
  补充后没有重跑图形测试或无关 regression。
- 当时尝试了生产 Canvas 截图。进程退出 0，但结果只有缩小的窗口画面与大量
  黑色区域，无法评估玻璃、可读性和中间帧；**视觉验证未完成**，不按截图成功
  宣称图形通过。原始文件仍在 `/private/tmp/mokusei-native-replay-carousel-az5w965h/production-glass-evidence/`，
  日志为 `.build/super-thread-glass/production-capture.log`。
- 初次评估 fixture 编译试图设置只读的系统无障碍 Environment 值而失败，
  日志 `production-fixture-attempt-1.log`。随后修正；sprint 补充后删除了新增
  GUI 评估入口，只保留生产组件和既有 headless 导出。未改变全局无障碍设置。

## 门禁与限制

验证前已读取远程实际规则：main 无传统 protection，`main-pr-gates` disabled，
active 的 `main-pr-requirement` 要求 PR / 讨论解决，不含 required status checks。
当时 PR #300 / #290 在列表中，最新 #300 Complete coverage 已通过；这些历史
结果不认证本次代码。本次未触发托管 CI、未运行完整 `make check` 或完整 Swift
suite，不把未运行说成通过。

按 sprint mode，最终本地仅 headless 验证，不新增测试，不再启动 GUI。
Reduce Transparency 的系统实机表现、旧 OS 降级、多卡玻璃性能、光学采样随
pan/zoom 的表现，以及真实触控板交互未获最终图形验证；需要后续有 GUI 的
专门验收。本工作树保持 detached，只提交，不创建/切换分支、操作共享 refs、
推送或合并，由协调方把最终提交集成到本地 main。
