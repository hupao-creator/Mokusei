# Settings 导航原生 demo

直接链接当前 checkout 的生产 `NativeSettingsPage` 和
`NativeWindowNavigationView`。设置页与 Thread Detail 均使用左上角同一个玻璃胶囊、
SF Symbol `chevron.left`、32 × 30 pt 返回目标和 Option-Left 快捷键。
侧栏不再显示“设置”标题，分类列表从 74 pt 的导航安全区下方开始；
安全区补偿内容缩放，始终避开固定大小的导航胶囊。关闭仍经过原有 draft close gate。

```sh
make check
python3 demos/settings-navigation/build.py
.build/settings-navigation/SettingsNavigationDemo.app/Contents/MacOS/SettingsNavigationDemo
# 保持窗口可交互：在上一行末尾追加 --interactive
```

运行后 `.build/settings-navigation/result.txt` 保存验证结论，`screenshots/`
保存浅色、深色、540 pt 紧凑设置页、621 pt 窄窗口英文设置页与 Thread 导航对照图。
另存四个 Harness 的 Moku 页浅色、深色截图，复核重复页面标题已移除而
“协调与派发”分组标题保留，以及透明图标座位、派发短横线和虚线路径。
通过生产交互注册切换协调 Harness、增减派发目标，并断言最后一个目标禁用
移除；另存深色单目标截图，复核该图标不会变淡。
缩放场景复用生产窗口的 frame/environment/scaleEffect 装配，覆盖 76% 中英文、
25% 最小缩放及 150% 紧凑布局。截图复核 tab 与固定导航胶囊之间的间距，
各场景同时断言返回目标的实际坐标和尺寸不变。
回放向自己的窗口发送返回点击，检查 IME 组合态阻止关闭、结束组合后可以关闭，
确认旧归档选中值回退到“通用”、侧栏分类不再包含归档和插件管理，
通过真实按键验证箭头循环与 Home/End 导航，
并验证真实返回目标位于 (100, 22)，尺寸 32 × 30 pt。
截图使用 ScreenCaptureKit，仅捕获该 fixture 的窗口。

数据与保存均在 fixture 内存；偏好文件写入该 demo 的私有 profile。
不启动 runtime，不访问用户真实 profile、模型服务或已安装应用。
设置布局、协调派发图、Agent 图标与文本编辑器来自生产组件。
Harness 配置子表单在 fixture 中为空；Thread 对照页只复用
生产窗口导航，正文为占位标记。未恢复已删除的调试提示词选项。

源码依据：

- `app/macos/Sources/Host/Shell/NativeWorkspaceView.swift` 为普通 Thread Detail 装配共享窗口导航。
- `app/macos/Sources/Host/WindowNavigation/NativeWindowNavigationView.swift` 定义胶囊、按钮和坐标。
- `app/macos/Sources/Host/Settings/NativeSettingsPage.swift` 在设置侧栏复用共享窗口导航。

需要 macOS 26 / Xcode 26；fixture 不安装或重启 Dev 应用。截图及 app 产物均由 Git 忽略。
