# 演示能力清单

本目录包含当前源码可定位的独立预览。可构建状态来自 build.py 的输入、参数和
生产模块检查，本次没有重新构建/启动这些 App，不宣称 GUI 或编译全部通过。
内存 fixture 只能展示其状态，不能认证 Runtime 持久化、模型、语音、真实输入和回执。
截图或 headless 数据导出不等于 e2e 验收；已有证据只覆盖其记录的源码/制品身份。

| 目录 | 当前边界 |
| --- | --- |
| [execution-handoff](execution-handoff/README.md) | 独立交互/材质方案 fixture；生产行为见所属模块 |
| [landing-setup](landing-setup/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [moku-gradient-material](moku-gradient-material/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [moku-history-theme](moku-history-theme/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [moku-landing](moku-landing/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [moku-mention-transition](moku-mention-transition/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [moku-note-transition](moku-note-transition/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [moku-panel-transition](moku-panel-transition/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [moku-thinking-orbit](moku-thinking-orbit/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [report-thread](report-thread/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [settings-navigation](settings-navigation/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [settings-tabs](settings-tabs/README.md) | 独立交互/材质方案 fixture；生产行为见所属模块 |
| [super-thread-carousel](super-thread-carousel/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| `tag-cloud-loading/` | 构建不可用：build.py 引用缺失的 NativeContentHost.swift；不提供验证覆盖 |
| [tag-filter-morph](tag-filter-morph/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |
| [tag-glass-morph](tag-glass-morph/README.md) | 独立交互/材质方案 fixture；生产行为见所属模块 |
| [tag-selection-preview](tag-selection-preview/README.md) | 独立 HTML 样式预览；不代表生产组件 |
| [thread-card-cloud](thread-card-cloud/README.md) | 构建不可用：build.py 引用缺失的 NativeContentHost.swift；不提供验证覆盖 |
| `thread-card-glass-timeline/` | 构建不可用：build.py 引用缺失的 NativeContentHost.swift；不提供验证覆盖 |
| [thread-panel-transition](thread-panel-transition/README.md) | 链接生产组件的交互 fixture；不连接真实 Runtime/账户，无自动验收 |

当前产品事实归属见[索引](../tools/verification/facts.md)，验证分工见[策略](../scripts/ci/verification-policy.md)。
