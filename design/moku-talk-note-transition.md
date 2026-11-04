# Talk 在 Note 开关过程中的连续可见性

## 原录屏观察

本次只读取用户提供的 `录屏2026-11-04 09.44.51.mov`，未运行应用或回放。
原文件为 3248×2124、8.4167 秒，轨道名义帧率约 31.84fps，SHA-256：
`641bfaced14f83d827a5ea8a60fd3fa1566086f0e22eea3d927cce427a55eca3`。
用 AVFoundation 按媒体时间抽帧；静止段可能返回较早的实际样本，因此以下时间
使用返回的实际样本时间，不把请求时间当成逐帧证据。录屏和检查图片不进入仓库。

- Overview 底部的普通 Talk 是两行文本，展开 Note 后仍位于眼睛右侧、历史入口左侧。
  不是 Moku history、Timer、dispatch 卡或独立弹窗。
- 第二次展开：3.6333 秒壳体还接近 Talk 胶囊尺寸，但消息已不可见；3.8、3.8333、3.8833 秒可见
  Note 正文和眼睛，Talk 的底部席位没有可读消息；3.95 秒消息出现在壳体下沿，
  被底边裁切；4.05、4.1 秒回到正常消息行。
- 第一次收起：2.3、2.35 秒 Talk 的底部席位为空；2.4 秒消息出现在尚未收完
  的壳体上部；2.5 秒仍高于眼睛；2.6–2.8 秒逐渐回到眼睛旁。
- 这是消息在中间帧离开其席位/被裁切的可见证据，不能仅凭画面断言消息数据被清空、
  视图重建或透明度归零。原录屏也不能证明修复后的效果。

## 源码定位与设计

实际视图是 [NativeMokuDock](../app/macos/Sources/Host/MokuScene/NativeMokuDock.swift)
底部 overlay 的 `rowMessage`，普通文本由
[NativeMokuTalkContent](../app/macos/Sources/Host/MokuScene/NativeMokuTalkContent.swift)
中的原生滚动容器承载。

身份：`displayedMessage` 在打开 Note 时仍来自同一个 Talk/voice 投影；消息条件分支
没有依赖 `notePanelOpen` 的 key、复制或换位。Note 开关不应触发消息进入/退出。
因此保留现有结构身份和 `followsTail`，不添加 `.id(notePanelOpen)`、快照气泡、
新的保留消息状态或卸载定时器。

布局：壳体、底部消息行及历史入口随 420ms 动画变化。History 会占用尾部宽度，
窄窗口会增加独立动作行，导致消息重排/垂直席位变化。文本的固定 viewport 和 padding
原先整体使用 `.transaction { $0.animation = nil }`，用于避免原生 document/clip
高度插值造成假溢出和滚动条闪烁。SwiftUI 默认把祖先位置/尺寸变化下传到绘制叶子；
结合源码和框架语义，推断这个局部事务同时取消了叶子继承的外层移动，使文本先采用终点
场景坐标，而玻璃仍在途中。该机制与原录屏中展开时向下裁切、收起时向上错位的两个方向一致。

在禁动画事务外增加 `geometryGroup()`，让外层先解析并动画化几何，原生消息在组内
继续按目标尺寸离散排版。这个边界直接使用 SwiftUI 的
[几何隔离语义](https://developer.apple.com/documentation/swiftui/view/geometrygroup())，
无需自建动画时钟或复制原生滚动视图。改动只作用于普通 Talk 和共用该文本路径的语音转写；
dispatch 的按钮、pending/result 过渡及详情目标沿用原实现。

透明度：消息上的 220ms opacity transition 保留为实际插入/移除效果；Note 开关时
分支身份不变，不用额外淡出/淡入遮掩几何问题。该 transition 现在与壳体一样遵守
Reduce Motion。Settings 原有的消息隐藏仍由外层 opacity 和交互限制负责。

## 静态审阅覆盖

以下是源码审阅结论与设计约束，不是运行或动态验收结果：

| 路径 | 保留的行为 |
| --- | --- |
| 展开、收起、快速反向 | 同一个消息分支和几何组，随现有壳体事务变化；没有旧完成回调或延迟恢复 |
| 同操作内容更新 | `receive` 更新当前 message，保留首次呈现的 60 秒 deadline；文本按目标宽高排版 |
| 新 Talk、nil、过期或主动关闭 | 仍由 `NativeMokuTalkState` 和现有 deadline task 决定；几何组不缓存或复活消息 |
| Note 打开时 Talk 消失 | 原消息分支退出，行高度、历史动作布局和壳体仍使用当前消息状态计算 |
| 输入、权限/问题、覆盖路由 | 原来的呈现资格和 Note 关闭路径不变，草稿、焦点和消息消费仍由 scene 管理 |
| 选择、滚动、链接、Stop、History、语音控件 | 几何组不增加内容或命中层；现有控件、手势和测量排除区域保留 |
| 长文本、窄窗口、landing、resize | 保留四/八行 viewport、原生 gutter、目标宽度换行和动作换行；仅外层移动隔离 |
| 无气泡、空 Note | 不进入消息分支；持久眼睛、单玻璃及 Note 空状态沿用原路径 |
| Reduce Motion / Transparency | 消息 fade 使用 nil animation；玻璃、Note 和实色替代仍由原有偏好分支管理 |

## 验证与局限

本轮遵守 sprint mode：不新增测试，不编译 Swift 测试 target，不运行测试、测试回放、视觉
fixture 或 CI，也不启动修复后的应用。原录屏的抽帧检查只用于定位已有问题。
修复后的连续可见性、原生选择/滚动、快速反向、真实系统偏好与完整应用交互尚未动态验收；
构建和静态审阅不能认证这些效果，也不作帧率、性能或 GPU 开销结论。

远程规则只读检查确认 main 的有效 ruleset 要求严格 `Complete coverage` 和 PR；
传统 branch-protection endpoint 返回 404 不代表没有规则。读取的近期 runs 是其他
提交的历史结果，不认证本提交。本次按明确授权仅在 detached 管理 worktree 本地提交，
不推送、不建 PR、不修改 main 或规则。

本次检查结果：

- `swift build --package-path app/macos --configuration release --product Mokusei
  -Xswiftc -warnings-as-errors` 成功（209.05 秒），未使用 `--build-tests`。实际执行另加
  `--disable-sandbox`、工作树内隔离的 cache/config/security 路径及锁定依赖参数；
  依赖由本机 SwiftPM 缓存复制到工作树后使用，不修改其他 checkout 或共享缓存。
- `make lint` 成功：架构/静态注册/no-Node、gofmt 和 `go vet ./...`。
  初次 vet 因隔离缓存缺少依赖、沙箱无法解析下载域名而中断；复制本机已有模块下载
  缓存到工作树后，用 `GOPROXY=off` 完整执行通过。没有运行 `go test`。
- `git diff --check`、两个改动文档的全部 38 个本地链接检查及当前 diff 自审通过。
- 原录屏第一次在沙箱内解码报 AVFoundation `-11821` / OSStatus `-12911`；
  仅为用户指定文件的只读解码使用沙箱外执行，成功取得上述媒体样本。

构建日志在本机 `/tmp/moku-talk-note-build.log`，lint 日志在
`/tmp/moku-talk-note-lint.log`；它们不是测试或修复后动态验收证据。
