# Agent Thread 转场 · 生产组件回放

推荐使用生产路径：

```sh
python3 demos/thread-panel-transition/build.py --production --open
```


已有当前 Swift build 时可加 `--skip-build`。`--production` 使用正式
`NativeReadingPageStack` / compositor、真实卡片身份锚点和生产 Markdown 阅读器；
只由内存 fixture 提供已完成/执行中内容和模拟加载，不连接 Runtime 或用户 profile。
不带 `--production` 的入口是独立视觉原型，不认证生产导航。

- 「让阅读回到工作现场」：已完成执行，正文加载后完整显示，页脚使用正常布局。
- 「整理原生交互细节」：执行中，沿用生产最新消息定位。
- title/emoji 的目标由无正文的真实阅读布局提前测量，与面板在同一次展开中到位；主阅读器在原生动画开始后隐藏预加载，到位后才放行绘制；加载完成只交接绘制，不再移动标题。
- 左上角关闭按钮复用生产控件。关闭时整体缩放、详情内容淡出；前 86% 行程完整缩到卡片尺寸，再于最后 14% 交接原卡片内容，总计仍为 420ms。
- Moku 和三个真实 Sidecard 插件仍在；fixture 不执行任务、不打开麦克风。
- 原生菜单提供打开首个任务、关闭、深浅色。慢速开关仅作用于独立原型；生产路径使用正式时序。


入口提供交互预览与内存 fixture，不配置自动断言、截图验收或验证报告。
