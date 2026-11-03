# Agent Thread 转场 · 生产组件回放

推荐使用生产路径：

```sh
python3 demos/thread-panel-transition/build.py --production --verify --open
```

已有当前 Swift build 时可加 `--skip-build`。`--production` 使用正式
`NativeReadingPageStack` / compositor、真实卡片身份锚点和生产文本揭示组件；
只由内存 fixture 提供已完成/执行中内容和模拟加载，不连接 Runtime 或用户 profile。
不带 `--production` 的入口保留为此前视觉提案的对照，不认证生产导航。

- 「让阅读回到工作现场」：已完成执行，正文自上而下揭示，完成时间最后显示。
- 「整理原生交互细节」：执行中，沿用生产最新消息定位，再自下而上揭示。
- title/emoji 的目标由无正文的真实阅读布局提前测量，与面板在同一次展开中到位；正文仍延后挂载，加载完成只交接绘制，不再移动标题。
- 左上角关闭按钮复用生产控件。关闭时整体缩放、详情内容淡出；前 86% 行程完整缩到卡片尺寸，再于最后 14% 交接原卡片内容，总计仍为 420ms。
- Moku 和三个真实 Sidecard 插件仍在；fixture 不执行任务、不打开麦克风。
- 原生菜单提供打开首个任务、关闭、深浅色。慢速开关仅作用于旧提案；生产路径使用正式时序。

`--production --verify` 检查实际来源锚点、加载中和已有正文时的一次到位（真实标题交接偏差小于 1pt）、正文首帧绘制门禁、
完成/运行状态的行方向、页脚显示和遮罩释放、正常关闭和打开中途关闭；原生 presentation layer 断言检查外壳到位前保持不透明、缩放完成后才交接卡片。
另覆盖录屏中的宽窗口、无侧栏场景：标题与正文列必须保持居中，加载前后标题坐标一致。
`production-05-wide-loading.png` 和 `production-06-wide-ready.png` 保存这两个阶段。
`production-*.png` 与 `production-identity.json` 保存在
`.build/thread-panel-transition/evidence/`；独立 app 路径写入同目录上级的 `app-path.txt`。
失败记录保存在 `.build/thread-panel-transition/failures/`。

首次生产回放发现普通 Markdown 没有可选 document token，因此改用独立解析完成信号；
运行中正文的验证等待实际揭示完成，而非固定两秒。视觉复核另发现 hosting 会重置
身份层变换，现改为独立 Core Animation 文字层，保留 reader 的延后挂载策略。

生产工作区、嵌套历史和异步回收还需结合：

```sh
MOKUSEI_SWIFT_SKIP_BUILD=1 python3 tools/verification/reading-presentation/run.py
MOKUSEI_SWIFT_SKIP_BUILD=1 python3 tools/verification/reading-presentation/run.py --moku-landing
```

这些回放串行持有图形会话锁；不可与其他原生/CUA 回放同时运行。
