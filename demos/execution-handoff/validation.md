# 本次验证记录

2026-11-05，macOS 26.5.1（25F80）、arm64，Apple Swift 6.3.2。
生产组件基线为 `5dda663a38fd91beb9a9229458217d76bd432d77`；
所有展示证据来自本目录最终 Swift 源码构建的独立 app。

## 已执行

- 编译当前 worktree 的产品：`xcrun swift build --disable-sandbox --package-path
  app/macos --product Mokusei`，使用当前 worktree 内的独立 SwiftPM 缓存目录；
  完成（101.06 秒）。无 `--build-tests`。
- `python3 demos/execution-handoff/build.py --skip-build --capture --open`：
  demo 以 Swift 6、warnings-as-errors 编译、ad-hoc 签名并启动，退出状态 0。
  展示序列不含测试断言或测试运行器。独立 app 已打开，供继续交互。
- 观察运行中、完成停顿、先收入并变宽、再翻页的两段中间帧、完整接管、取消后恢复、
  960×680 深色长结果及 demo 减弱动态效果路径。标准窗口为 1240×800。
- 前版在实际 UI 中点击「长结果」和「完成新 execution」，
  确认主 detail 接管后只暴露最新 reader，再用原生滚动滚至文末；
  无障碍滚动条值从 0 到 1。本次只改变外层动画顺序与收入表现，未重复这一交互观察。
- 审查取消/重播的 visit fence、正文 readiness、原生 layer/frame 所有权、
  固定文字宽度、输入/辅助功能门禁；Python 入口语法、文档链接和 diff 检查。

保留 [初始状态](evidence/running.png)、[收入并变宽](evidence/absorbing.png)、[向下翻页中间帧](evidence/paging.png)、
[接管完成](evidence/complete.png) 及 [观察时刻](evidence/samples.json)。
其余截图、stdout/stderr、runtime-isolation.json 与 cleanup.json 保存在
`.build/execution-handoff/evidence/`；最终展示进程 stderr 为空。
实际截图间隔包含截图开销，不是固定 FPS 采样，也不是性能认证。

## 发现与修正

初版待进入页面的 layer 位移会被原生布局覆盖；把 model frame 移出视口又会
让 TextKit 提前裁掉文字。最终采用独立 AppKit seat、透明度准备门禁和仅作用于
呈现层的旅行，保留可见 model viewport 到隐藏时刻。重新构建后的初始画面显示
上一轮。第一段只收入 sidecard 并让主面板变宽，以遮挡表达收入，不缩小或渐出；
宽度动画完成回调才启动第二段，旧页向上、新页从底部进入。
完成操作保留现有主 reader，避免重新挂载时的空白与滚动丢失。
Close 从页面内部移到主面板固定左上角，避免随正文移动或居中。

## 未执行与限制

- 按用户 sprint mode 要求，没有新增测试，也没有运行或回测任何测试用例；
  未运行 `make check`、Swift/Go 测试、生产集成回放或托管 CI。
- 系统 Reduce Motion 观察值为 false。已观察 demo 开关的直接交接；
  未修改全局系统偏好，也不声称已实测系统设置变化通知。
- 不认证真实 Runtime、模型、权限请求、完整 Sidecard 插件会话、网络与存储；
  不模拟 960pt 以下的生产堆叠布局。取消是恢复 fixture，不是任意点反向续播。
- 受限进程环境最初拒绝 SwiftPM sandbox、Swift 宏进程及打包器 `ps`；
  获准在进程沙箱外执行必要编译/打包后完成。未修改系统设置。
- 验证前尝试只读查询 main 的保护规则和当前 PR/run，但 `gh` 无法连接
  api.github.com；未触发远端动作。新增 Swift/Python 源码不属于文档专用 CI 范围。
- 当前 worktree 初始干净。只读 worktree 清单确认 main 与本 worktree 的
  起点相同；没有进入或检查 main 工作区的未提交状态。托管开发者指令要求
  保持 detached HEAD、禁止操作 base checkout / 其他 worktree / shared refs，
  集成由调用方负责。因此只提交当前 worktree，未合并本地 main、推送或创建 PR。
