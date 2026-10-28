# 工作项

工作项使用当前 Git origin 指向仓库的 GitHub Issues；先用 `git remote get-url origin` 确认目标。

当前仓库的 GitHub 操作统一使用本机 `gh` CLI 的 `hupao-creator` 身份。
操作前用 `gh api user --jq .login` 确认；不要用连接器的登录身份替代。

- 读取 issue 时包含正文、评论和 labels；CLI 发布正文用 `--body-file` 保留 Markdown。
- `ready-for-agent` 表示需求明确、可由 agent 实现；发布此类 spec 时使用该 label。
- PR 是改动审查入口，需求记录放在 issue。
