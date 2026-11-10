# 生产接入验证

基线 `d2127dbf70280bddac5a1d0ba8515bac6ec1c3b5`，2026-11-10。用户先确认独立 demo，随后授权落地生产；本轮交付 detached 工作树提交，由调用方集成 main。不安装、关闭或重启正在运行的正式应用。

## 已完成

- 当前源码 `Mokusei` Debug product 构建通过，最终生产代码构建日志为 `.build/super-thread-carousel/production-integration-build-3.log`。SwiftPM 的用户缓存只读提示未影响编译。
- 既有 `NativeOverviewMembershipTests` 的 7 个无窗口方法、`NativeOverviewScopeFilterTests` 的 7 个方法通过，共 **14 项**，零失败。`MOKUSEI_TEST_HEADLESS=1`，显式排除需要 display 的 `mountedContentUpdatesAvoidCanvasInvalidationAndRetainLatestExitSnapshot`；该图形用例未运行，不算通过。日志 `.build/super-thread-carousel/focused-headless-tests.log`。
- `mokusei-check architecture` 通过，覆盖模块边界、静态注册及 no-Node 规则；日志 `.build/super-thread-carousel/architecture.log`。
- 生产组件 demo 以 Swift 6 warnings-as-errors 编译，ad-hoc 签名、严格签名验证和动态依赖检查通过。最终日志 `.build/super-thread-carousel/production-demo-final.log`，产物 `/private/tmp/mokusei-native-replay-carousel-5xft2l1w/SuperThreadProductionDemo.app`。
- 原 13 个 fixture 场景导出完成，资格判断使用生产 policy，严格 600 秒边界符合要求。
- 16 个生产模型场景导出并人工核对：各标签内一组/零组；成员与独立项无重复；打开 source 指向集合；展开期间背景不变、返回后移出；单候选解散；preferences 重载保留事实；搜索不集合；成员内容更新可见；临近门槛前独立、定时到期后无 catalog 事件也能归组；普通偏好写入保留打开记录。所有模型 error 字段为空。文件 `.build/super-thread-carousel/production-projection.json`，headless stderr 为空。
- 本地审阅：集合身份与真实报告身份分离；回程按重新布局后的成员卡片定位；取消/隐藏时停止任务；打开失败写盘时保留本次会话事实并报错；最大四个封面挂载；集合参与语义导航且不成为 Runtime 实体。新文件空白、Python AST 与新增本地文档链接已检查。

## 远端状态与范围限制

初次沙箱内 GitHub 查询连接失败。扩展执行下重新读取：旧 branch protection endpoint 返回 `Branch not protected`，实际 main ruleset `26378950` 要求 PR、解决 review threads，返回规则中没有 required-status-check 条目。查询时可见 PR #300、#290 已有各自成功的 Complete coverage；这些是其他提交的结果，不能认证本次改动。

本工作树不创建/切换分支，不推送、不创建 PR、不合并或修改共享 refs；调用方负责最终集成与最终提交的 CI。没有新增测试，没有运行全套 `make check`、无关回归或托管 CI。本地 fixture 数据不是图形验证：真实触控板路由、Liquid Glass 像素、转场中间帧和生产 reader 展开/返回的图形回放未运行，不宣称通过。原设计 demo 的启动观察只属于当时产物。

此前 demo 迭代的编译参数缺失、JSONText 重载歧义及 Animatable actor isolation 问题均已修复；相关保留日志在 `.build/super-thread-carousel/*attempt-*.log`。这些旧失败不替代本次最终源码验证。
