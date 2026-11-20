# Moku landing 原生 demo

复用生产 `NativeMokuScene`、`NativeMokuDock`、原生 composer、Overview 和窗口材质，
以内存 fixture 展示空工作区、首次派发、失败、归档和窄窗口状态。

```sh
python3 demos/moku-landing/build.py --open
```

已有当前生产 Swift build 可加 `--skip-build`。按 Command-D 打开演示控制，
Command-1/2/3/4 分别重置、演示成功、失败及归档。
独立 app 路径写入 `.build/moku-landing/app-path.txt`。
预览不配置自动断言、截图验收或验证报告，也不启动 Runtime 或真实模型。

## Nested workspace header replay

Build the current Debug package and use a new output directory.

```sh
xcrun swift build --package-path app/macos
python3 demos/moku-landing/verify_header.py --capture --output .build/nested-header-replay
```

The replay mounts the production workspace and its nested reading host with
a temporary fixture catalog. It starts at 5×, checks single-row filters at 1×
and 1.44×, checks stacked filters at 2.5×, and returns to 5× at two window
heights. It checks the rendered filter position and native window button
centers independently. The JSON records button hits, filter bounds, header
exclusion and whether a window-local wheel sample pans the canvas. It exercises
the camera pinch path with an injected magnification. Optional captures show
the fixture's offline workspace.
Physical dragging, trackpad delivery and system fullscreen are outside this
replay.
