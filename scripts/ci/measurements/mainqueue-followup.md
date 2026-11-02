# 主队列观察诊断

PR `41393168410` 仍失败，不能把零 sleep tolerance/进程活动请求宣称为修复。
`reversal-outgoing` 的真实部分淡出帧在输入 B 后 151.017ms 才被分析，
超过原 150ms 早期回转条件。该帧年龄 17.568ms、墨迹 21.52%，但提交输入已太迟。
展开观察最大采样间隔仍为 76.196ms；这次中点命中只说明该次观察完成。
原始数据在该 run 的 native artifact 中，失败仍保留，不重跑碰运气。

候选改用实际主队列一次性 Dispatch timer，10ms、zero leeway，记录安排、
计时器触发和 actor 恢复的各自 uptime。取消和触发在 main 上消费同一 continuation，
唤醒前后检查取消；没有扩大任何窗口、期限、动画时长，也没有使用旧帧补判。
普通主动布局 wait 保留旧 sleep。该请求仍不能保证 OS/主线程实时性。

本地构建通过，真实七项捕获全部通过；展开 55 次观察，最大间隔 13.769ms。
实际 test-support 源码的探针完成 50 次等待、一次预取消、25 次运行中取消。
这些是本地证据，不替代托管验证；探针输入和摘要见
[mainqueue-observer-probe.json](mainqueue-observer-probe.json)、
[mainqueue-local-capture.json](mainqueue-local-capture.json)。

为减少盲目完整 CI 循环，独立诊断分支只通过现有 CI workflow 的手动 dispatch
执行同机 A/B/B/A。生产模块只构建一次：A 使用 `916fd32` 的原 Task.sleep
观察源码，B 使用主队列观察源码；两边都运行相同七项实际原生测试和全部原断言。
旧 A 仍保留上一轮 user-initiated/latency-critical runner 和 SDK cache，
因此只隔离观察等待差异。每轮都有独立 app、完整截图、源码哈希和实际进程状态，
失败不挑掉；任一条件失败，诊断 job 即失败。诊断无 Complete coverage check，
不能满足 PR 门禁。诊断文件不合入 main；最终 PR 合成提交仍完整构建、普通 suite、
fixtures、interop、native 和审计。
