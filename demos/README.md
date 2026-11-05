# 演示与历史实验

当前产品截图应由生产组件加确定性 fixture 生成。独立绘制的外观提案和依赖已删除架构的预览保留历史用途，不作为当前产品验收依据。

| 入口 | 状态与用途 |
| --- | --- |
| [Report Thread 卡片与展开](report-thread/README.md) | 已确认设计对照及正式组件 fixture：emoji / 短介绍 / harness logo 卡片、右侧关联列表 2:8、执行阅读 5:5；生产契约已接入。 |
| [Agent Thread 面板转场](thread-panel-transition/README.md) | 生产 compositor、身份交接和双向正文揭示的 fixture 回放；保留此前独立提案作对照，Moku 常驻。 |
| [Execution 完成交接](execution-handoff/README.md) | 独立原生提案：先收入 sidecard 并让主面板变宽，再向下翻到新结果；支持重复播放、慢速及减弱动态效果，不修改生产交接。 |
| [Overview / glass world](../tools/verification/overview-input/README.md) | 当前生产 Canvas、Harness/Report 卡片、Chrome 和 Moku Dock；含浅深色 × 材质开关的隔离截图。 |
| [Tag morph](tag-filter-morph/README.md) | 当前生产 `NativeOverviewChrome` 标签回放。 |
| [Overview 搜索](overview-thread-search/README.md) | 当前生产搜索、筛选与几何回放。 |
| [Settings 导航](settings-navigation/README.md) | 当前生产设置与导航组件的隔离回放。 |
| [Settings 顶部 tab](settings-tabs/README.md) | 已批准提案的设计对照；正式界面与验收使用 Settings 导航回放。 |
| [Moku thinking 历史对照](moku-thinking-orbit/README.md) | 当前生产胶囊 + Arc 的 fixture 演示；另保留 Electron 圆形阅读与后续胶囊环流作为历史对照。 |
| [Moku 渐变玻璃](moku-gradient-material/README.md) | 生产渐变材质的独立原生调参预览；复用胶囊几何、眼睛与当前材质，保留深浅列标签；当前两列均复用固定深色生产材质，浅色标签不代表另一款产品材质。 |
| [Moku Note 收起](moku-note-transition/README.md) | 当前 Release 生产 Dock 的隔离视觉预览；合成笔记、连续收起帧、快速往返、窄窗口/居中布局与禁动画 fixture。 |
| [Moku mention transition](moku-mention-transition/README.md) | 当前生产 Dock 与已确认原型的菜单/眼睛过渡对照，支持真实输入及自动回放。 |
| [Moku landing](moku-landing/README.md) | 当前生产 Dock/composer 的原生视觉回放；fixture 驱动派发与归档，全局状态接入另有生产页面集成回放。 |
| [Moku 历史布局与主题](moku-history-theme/README.md) | 生产历史页、Codex reader、Dock 与 Note 的隔离预览；浅/深/系统主题与三档尺寸，不运行测试。 |
| [Moku 输入胶囊转场](moku-panel-transition/README.md) | 当前生产 Scene/Dock/原生编辑器的隔离交互预览；包含用户录屏定位、展开收起中间帧、反向操作与窄窗口记录，不运行测试。 |
| [Landing setup](landing-setup/README.md) | 新用户五步设置的原生交互提案；模拟 Agent 发现与配置，最后进入共用的生产 landing 回放，不接入生产首次启动。 |
| [Tag glass morph](tag-glass-morph/README.md) | 接入前的独立参数实验；保留实验源码与参数，不同步成生产副本。 |
| [Tag selection HTML](tag-selection-preview/README.md) | 历史静态视觉提案；浏览器实色选中样式不代表当前原生玻璃 tint。 |
| [Thread card cloud](thread-card-cloud/README.md) | 历史光云预览；构建仍引用已删除的 `Sources/App/NativeContentHost.swift`，且手动装配卡片玻璃。 |
| `tag-cloud-loading/` | 历史标签光云预览；同样引用已删除的 `NativeContentHost.swift`，并单独编译部分 Host 源码。当前标签请用 Tag morph 回放。 |
| `thread-card-glass-timeline/` | 历史计划阶梯外观预览；同样引用已删除的 `NativeContentHost.swift`，并自绘预览卡片外壳。当前阶梯与材质请用 Overview / glass world 回放。 |

后三个旧预览的构建脚本与素材保留原样，现有命令不是可用性承诺；不要为生成当前截图而恢复已删除的 Host。它们的替代入口已复用真实生产组件，本次不迁移旧预览的独立控制面板，也不改写旧截图。当前回放的检查范围与操作方式以各自 README 为准。
