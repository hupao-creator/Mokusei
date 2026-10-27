# 工作项

工作项使用当前 Git origin 指向仓库的 GitHub Issues；先用 `git remote get-url origin` 确认目标，再使用可用的 GitHub 工具或 CLI。

- 读取 issue 时包含正文、评论和 labels；CLI 发布正文用 `--body-file` 保留 Markdown。
- `ready-for-agent` 表示需求明确、可由 agent 实现；发布此类 spec 时使用该 label。
- PR 是改动审查入口，需求记录放在 issue。
