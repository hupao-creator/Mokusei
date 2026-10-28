# Mention 眼睛过渡预览

```sh
python3 demos/moku-mention-transition/build.py --open
```

默认展示已接入的真实 `NativeMokuDock`。关闭“正式 Dock”可对照已确认的视觉提案。
提案复用生产 `NativeMokuComposerInput`、目录菜单、玻璃与眨眼；
眼睛直接位于输入行，菜单展开时随同一布局移动，避免单独测量眼睛位置后再追赶。
正式 Dock 保留同一个角色实例；菜单独立放在输入行上方，由胶囊统一过渡高度。

点击“回放展开 / 收起”会通过真实 NSTextView 依次输入 @、缩小匹配范围和清空；
也可直接打字、方向键选择、Esc 关闭。支持浅深色。
数据来自内存 fixture，发送不执行任务，不启动 Runtime，不访问真实目录。
此交互 demo 侧重菜单视觉；Dock 收缩、运行中角色交接由生产 transition 回放验证，语音入口由 voice-cloud 回放验证。

构建复用生产 SwiftPM 模块，将独立 app 和资源放在临时目录，路径记录于
`.build/moku-mention-transition/app-path.txt`。
已构建当前生产模块时可以加 `--skip-build`。
