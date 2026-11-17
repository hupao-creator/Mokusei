# Collection 成员面板本地验证（2026-11-17）

本次在 `collection-super-thread-panel` worktree 接手，基线 `f5f305de`。
最初只读检查进程列表：没有存活的遗留 Swift 构建；未停止其他项目进程，未删除缓存。

## 实现审查

- Host 先按当前 scope/tag 过滤，再以创建时间稳定排序；collection 只选符合阅读资格的成员。
  `NativeReportCollection` 面板遍历完整 `props`，不使用轮播最多四篇的预加载列表。
- 复用 `NativeReportCard`、原有打开回调和归档能力。面板只负责关闭与成员动作准入，
  不写阅读记录、不改变轮播选择，不新增数据源或排序。
- 修正交接实现的普通 ScrollView 为 `NativeScrollView`；成员卡恢复普通报告的实色底板。
  入口保留原有玻璃样式；增加展开状态、键盘/AX focus 绑定、离开视图清理和关闭后动作守卫。
- 面板打开参与轮播时钟的取消键，关闭后重新计时。失活、离屏、卸载路径均收起。

## 已执行

- 实际产品构建：`xcrun swift build --package-path app/macos --product Mokusei
  --cache-path "$PWD/.build/swift-cache" --disable-sandbox --disable-automatic-resolution -j 4`，
  exit 0，62.76 秒。日志：`.build/collection-panel-build.log`。
- `make lint`：架构、静态注册、no-Node、gofmt 检查及 Go vet 通过，exit 0。
  首次沙箱内运行因用户 Go 缓存权限失败；同一命令在授权环境重新运行通过。
  日志：`.build/collection-panel-lint.log`。
- `python3 demos/super-thread-carousel/build.py --skip-build --headless`：使用本次生产对象
  编译、链接、签名独立 demo，并导出 13 个 fixture 场景和 30 条生产投影记录，exit 0。
  默认三成员、产品标签两成员、其他标签独立卡片、搜索和阅读资格场景仍保留。
  数据与 App 路径在 `.build/super-thread-carousel/`；日志在 `.build/collection-panel-demo.log`。
- Computer Use 挂载真实生产组件：初始九成员、滚动后到达第九篇无封面卡片，点击进入
  对应示意阅读页；返回后再次展开成功。原有最近关闭成员自然到期后集合增至十篇。
- 面板从第二页打开并跨越一个以上 8 秒周期仍保持第二页；关闭后观察到继续轮换。
  重复点击 x/x 收起、重新展开、Escape 关闭均观察到预期结果。
- 缩小 demo 至约 840×660 窗口，面板仍可展开并滚动至末尾（AX 滚动位置为 1）。
  浅色、深色均查看实际截图。面板是独立 popover，可越过父窗口边缘；工具的父窗口截图
  不包含超出父窗口的全部面板像素，不据此声称全屏边缘适配已验证。
- AX 树包含展开/收起状态、关闭按钮、原始成员标题、关联信息及滚动控件。
  无封面成员与超出轮播预加载范围的成员均可访问。
- UI 工具初期使 App 失活；后续用显式 demo 活动开关隔离交互检查，也在关掉该开关后
  观察到按钮随失活禁用。一次深色截图遭 ScreenCaptureKit -3811，后续重试成功。
  最后退出隔离 demo，未操作正式应用的数据或进程。

## 未执行与合入说明

- Tab/Space 完整焦点遍历未在当前工具环境建立可靠证据；Escape 已执行。
  未做 VoiceOver 实机、多显示器、小屏幕、Reduce Motion 或物理触控板验收。
- 离屏与卸载的收起路径通过代码审查，未在生产 Canvas 做完整交互回放。
- demo 打开回调的目的地是示意阅读页；没有启动真实 Runtime 或验证完整生产阅读动画。
  没有运行完整 Swift 测试、report-covers 原生 CI owner 或全套 `make check`。
- 本次未推送、未触发 CI、未合并。只读远程查询显示 main 有 PR ruleset，
  没有 required status check；经典 branch protection 返回未保护。
  仓库流程仍要求最终提交的托管 `Complete coverage`。其他提交的历史成功不认证本次改动。
- 合入时将本地提交移植到最新 main，复核冲突和上述交互边界，运行最终提交的 CI 后通过 PR 合入。
  接手基线与远程 main 不同，未为本地交付改动基线或主 checkout。
