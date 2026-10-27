# 2026-10-25 本地性能证据

- `manifest.json`：60 个接受的区段、4 个被并发检查污染并排除的尝试，含实际命令、二进制 SHA、时段与宿主负载。未观察到重叠不代表宿主完全空闲。
- `r1-*.json` / `r2-*.json`：before→after 与 after→before 顺序的原始输出。Moku/Codex 文件为 NDJSON；每场景每版本合计 6 个样本。
- `summary.json`：25 个场景的中位数、范围、样本数量；Codex 同类型/规模前后终态 SHA 一致。耗时是每个样本的平均操作耗时再取中位数。
- `excluded/`：原样保留的污染区段，不进入 summary。
- `sources.json` / `validation.json`：源码身份、生产提交、检查命令与本地原始日志 SHA、已修正的初次验证失败和未测范围。
- `queue-controls.json`、`final-*-queue-control.jsonl`、`relay-controls.json`、`negative-control-*.go.txt`：最终队列与 relay 单点负控；`initial-*.jsonl` 仅保存早期验证，未进入汇总，不能与最终 pre-cancel 计时混用。
- `runner.py.txt` / `summarize.py.txt`：本次实际编排与汇总脚本记录，保留任务临时目录约定；不是安装后的通用 CLI。可重复的公共入口与参数见上级 README 和 manifest。

Runtime 的进程级 CPU/分配包含重叠的后台工作。通知只等待 durable 提交与同步 callback，不等待异步 publisher；不据此推导 GUI、真实模型延迟或泄漏结论。
