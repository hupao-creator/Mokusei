# 演示与历史实验

当前产品截图应由生产组件加确定性 fixture 生成。独立绘制的外观提案和依赖已删除架构的预览保留历史用途，不作为当前产品验收依据。

| 入口 | 状态与用途 |
| --- | --- |
| [Overview / glass world](../tools/verification/overview-input/README.md) | 当前生产 Canvas、Harness/Report 卡片、Chrome 和 Moku Dock；含浅深色 × 材质开关的隔离截图。 |
| [Tag morph](tag-filter-morph/README.md) | 当前生产 `NativeOverviewChrome` 标签回放。 |
| [Overview 搜索](overview-thread-search/README.md) | 当前生产搜索、筛选与几何回放。 |
| [Settings 导航](settings-navigation/README.md) | 当前生产设置与导航组件的隔离回放。 |
| [Moku thinking 历史对照](moku-thinking-orbit/README.md) | 当前生产胶囊 + Arc 的 fixture 演示；另保留 Electron 圆形阅读与后续胶囊环流作为历史对照。 |
| [Moku 渐变玻璃](moku-gradient-material/README.md) | 生产渐变材质的独立原生调参预览；复用胶囊几何、眼睛与当前材质，并排比较深色和浅色。 |
| [Moku mention transition](moku-mention-transition/README.md) | 当前生产 Dock 与已确认原型的菜单/眼睛过渡对照，支持真实输入及自动回放。 |
| [Moku landing](moku-landing/README.md) | 当前生产 Dock/composer 的原生视觉回放；fixture 驱动派发与归档，全局状态接入另有生产页面集成回放。 |
| [Tag glass morph](tag-glass-morph/README.md) | 接入前的独立参数实验；保留实验源码与参数，不同步成生产副本。 |
| [Tag selection HTML](tag-selection-preview/README.md) | 历史静态视觉提案；浏览器实色选中样式不代表当前原生玻璃 tint。 |
| [Thread card cloud](thread-card-cloud/README.md) | 历史光云预览；构建仍引用已删除的 `Sources/App/NativeContentHost.swift`，且手动装配卡片玻璃。 |
| `tag-cloud-loading/` | 历史标签光云预览；同样引用已删除的 `NativeContentHost.swift`，并单独编译部分 Host 源码。当前标签请用 Tag morph 回放。 |
| `thread-card-glass-timeline/` | 历史计划阶梯外观预览；同样引用已删除的 `NativeContentHost.swift`，并自绘预览卡片外壳。当前阶梯与材质请用 Overview / glass world 回放。 |

后三个旧预览的构建脚本与素材保留原样，现有命令不是可用性承诺；不要为生成当前截图而恢复已删除的 Host。它们的替代入口已复用真实生产组件，本次不迁移旧预览的独立控制面板，也不改写旧截图。当前回放的检查范围与操作方式以各自 README 为准。
