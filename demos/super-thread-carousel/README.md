# Super Thread 原生轮播集合

已确认的设计已接入生产 Overview。这个独立 App 直接复用生产 `NativeReportCollection`、`NativeReportCard` 和 `NativeReportCover`，只注入确定性报告 fixture；不运行 Runtime、不连接真实会话、不安装或重启正式应用。

## 生产行为

- 当前标签内，已关闭且距离最近一次关闭 **超过 300 秒** 的 Super Thread 自动归入一个 collection。至少两篇才成组；无关闭记录、刚关闭和未来关闭时间记录不合格。
- collection 只是视图投影；成员保留原报告身份，过滤、搜索和关联执行数据不变。非空搜索逐篇展示。关闭时间与短读保留资格由生产客户端保存在当前 profile 的 desktop preferences，collection 本身不持久化。
- 点击封面/body 才打开报告并开始独立阅读访问；翻页不计为打开。打开时从 collection 位置展开；单次前台阅读超过 120 秒才清除原资格，短读返回保留；每次关闭重新开始 300 秒等待；只剩一篇时解散集合。
- 封面在 308pt 区域水平轮播；底部 144pt body 保持原位，旧内容淡出后新内容淡入。两部分共享选择和 460ms 时钟，4pt 间距和外壳固定。
- Liquid Glass 轮播控件固定在封面上。每 8 秒自动切换，手动切换重新计时；离屏、阅读页、失焦或封面手势暂停自动轮播。Reduce Motion 直接切换。
- 集合采用已确认的 regular Liquid Glass：同一背板连续覆盖封面、4pt 布局间距和 body，不露出背景缝。emoji badge 保持生产 44pt 直径、距 metadata 顶部 12pt / 右边 17pt；单篇 Report 仍为不透明材质。降低透明度时新表面使用实色。
- 大集合最多挂载四个封面；超过七篇以菜单代替圆点列表。无封面报告使用自身 emoji 占位。
- 预览根视图注入与生产 Report plugin 相同的封面缓存，标签重建时用已绘制图像衔接 WebKit 首帧；缓存最多 16 项，仅存在于当前预览，不保留浏览器或写入 profile。封面 revision / 主题变更独立加载。见[闪烁定位与验证](../../design/super-thread-cover-flicker.md)。

生产边界和输入归属见 [Overview README](../../app/macos/Sources/Host/Overview/README.md#viewed-application-collections)。没有 Thinking Effort 控件改动。

## 构建与手动查看

要求 macOS 26、项目当前 Xcode/Swift 工具链，以及 `Package.resolved` 的锁定依赖：

```sh
python3 demos/super-thread-carousel/build.py --headless
cat .build/super-thread-carousel/app-path.txt
```

生产模块已按当前源码构建时，加 `--skip-build`。构建脚本只编译、打包、签名和可选的 headless 导出，永不启动 GUI。它使用当前工作树 Debug 对象和独立 bundle ID，将完整依赖/资源复制到 `/private/tmp/mokusei-native-replay-carousel-*/SuperThreadProductionDemo.app`。这是本机 ad-hoc App；临时文件清理后需要重建。

用户手动打开 `app-path.txt` 所列 App，或执行：

```sh
open "$(cat .build/super-thread-carousel/app-path.txt)"
```

如果当前环境的命令行 `open` 报 LaunchServices `-10827`，使用 Finder/桌面接口打开相同路径。此前 demo 已通过桌面接口打开，不需要停止现有正式应用。

## Regular glass 的 headless 验证

`--headless` 导出真实生产投影的 `surfaceOwners`：collection 为 true，单篇
Report 与搜索结果为 false。它在创建 NSApplication 之前退出，不启动 GUI。
生产 Canvas 根据这个声明省略 collection 的实色底壳，regular 背板由 Report
renderer 提供。现有手动 App 的集合外壳同样让出底色，其他卡片保留实色。

本次落地的构建、导出和未完成视觉验证见
[regular-glass-validation.md](regular-glass-validation.md)。

## 查看路径

1. “全部”：三篇集合、一篇最近关闭、一篇无关闭记录。等待十秒或用封面拖动、触控板横向滑动、左右按钮/圆点切换。
2. 勾选“慢速 ×3”，观察封面位移和固定 body 的淡出/淡入。这个仅供预览的选项不进入生产控件。
3. “产品”两篇成组；“原生”“工程”只有一篇合格，不成组；“未读”零篇合格。
4. 打开集合成员可查看示意阅读 sheet；真实开关与计时以生产 headless 导出为准；“时间 +10 分钟”只推进 demo 归组时钟，未打开者始终不自动归组。
5. 深色只影响预览窗口，“重置”恢复 fixture 关闭记录。预览阅读 sheet 是说明页，不模拟真实 Report reader。

可视 App 的关闭记录为内存 fixture，便于重置；生产已使用持久化记录。卡片、动效、封面输入与 Liquid Glass 完全来自生产组件，没有 demo 动效副本。

## Headless 数据导出

`--headless` 在创建 `NSApplication` 之前退出；不挂载 WebKit、不产生截图。

- `.build/super-thread-carousel/headless.json`：13 个 fixture 数据场景，资格判断复用 `ApplicationOverviewCollectionPolicy`，包含严格 300 秒边界。
- `.build/super-thread-carousel/production-projection.json`：[ProductionProjection.swift](ProductionProjection.swift) 经真实 `NativeWorkspaceCatalog`、`NativeOverviewWorkspaceModel` 和 `DesktopPreferences` 导出生产投影。覆盖各标签、短读保留/长读移出/解散、持久化重载、搜索、成员更新、无 catalog 事件的到期归组，以及普通偏好写入保留关闭事实。另通过真实 `NativeWorkspacePresentation.open` 方法验证首次 Overview 投影前的打开标记落盘、旧打开数据不冒充关闭事实、返回后保留记录及无效引用拒绝；不创建窗口。

生产导出使用独立临时 profile，不连接 Runtime；完成后清理该 profile。这是可审阅的 fixture 数据导出，不是新测试套件，不证明视觉中间帧或物理手势通过。已运行和未运行的检查见 [validation.md](validation.md)。
