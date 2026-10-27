---
name: commit-message
description: "Write or revise Git commit messages that explain a change and its rationale. Use when drafting a commit message, improving an existing message, or preparing a requested commit."
---

# Commit Message

## 写之前

阅读本次准备提交的 diff，结合相关需求和讨论，确认实际改动及其动机。根据仓库已有提交习惯选择语言和必要的范围前缀。描述必须对应本次提交；无法确认的动机、效果或验证结果不要编造。

## 标题

- 用一行有意义的话概括改动，让只看 `git log --oneline` 的读者也能理解。
- 范围不明确时，在标题中指出涉及的子系统或模块。
- 英文标题使用祈使句，例如 `Add …`、`Fix …`、`Remove …`。
- 标题与正文之间空一行。

## 正文

为不了解当前讨论的读者，以及将来回看历史的人写正文：

- 说明为什么需要这次改动，以及采用了什么解决办法。新功能可以从使用场景或缺失的能力讲起；修复可以从错误行为及其影响讲起。
- 对有取舍的改动，保留理解决定所需的背景、约束，以及选择此方案的理由。避免逐行复述 diff。
- 让篇幅与改动复杂度相称。简单改动简短说明；复杂改动用短段落展开，不强制填充固定栏目。
- 必要的上下文直接写在正文里。链接用于补充；引用已有提交时，同时给出可读的标题和 commit hash。
- 英文正文在约 74 列以内换行，便于带缩进的 `git log` 阅读。

涉及 merge commit 时，说明合入了什么、为什么合入，并保留日后理解这次合并所需的信息。

项目使用 `Fixes:`、`Reported-by:`、`Signed-off-by:` 等 trailer 时，按其约定和实际情况填写。

用户只要求撰写消息时，直接给出可使用的 commit message。
