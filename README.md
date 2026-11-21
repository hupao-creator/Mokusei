# Chief

<p align="center">
  <strong>A native Mac workspace for coordinating AI agents.</strong>
</p>

<p align="center">
  <a href="#get-started">Get started</a> · <a href="docs/README.md">Product guide</a> · <a href="LICENSE">Apache 2.0</a>
</p>

<p align="center">
  Apple silicon · macOS 26+ · Invited alpha
</p>

---

Chief brings Codex, Claude, Pi Agent, and OpenCode into one workspace.
Talk to the **Chief** assistant to coordinate work, then open each task's conversation
to follow the work and give it more direction.

- **Ask once, coordinate across agents.** Give Chief a task, attach files, and include the full path of any project folder Chief should use. Chief can answer directly or assign work to the agents you've enabled. [Working with Chief →](docs/working-with-moku.md)
- **See what needs you.** Overview puts task status, questions, and permission requests on cards. Filter by folder or tag, then open a conversation to step in. [Overview →](docs/overview.md)
- **Read results and keep going.** Read completed replies, revisit earlier runs, send a follow-up, or branch from an earlier run when the agent supports it. [Agent conversations →](docs/task-conversations.md)
- **Connect the work.** Optional Tag Agent groups conversations within each project folder. Super Thread Agent prepares Super Threads with links back to source conversations. Git task cards can show branch and change summaries. [Tags, Super Threads, and file changes →](docs/reports-tags-and-changes.md)
- **Give feedback beside the work.** Open a web page in a sidecard, annotate an element or area, and send the screenshot and comment to the current agent conversation. [Sidecards →](docs/sidecards.md)

The interface uses SwiftUI and AppKit, backed by a Go service. Agents run through
their externally installed tools and retain their own accounts, models, and
credentials.

---

## Get started

Chief is available as an **invited alpha** for Macs with Apple silicon and
macOS 26 or later. Get the **Chief Alpha** disk image and installation guide
from your inviter.

1. Drag **Chief Alpha.app** from the disk image into **Applications**, then open it. The alpha is not notarized; a trusted download may need the per-app **Open Anyway** exception in **System Settings → Privacy & Security**.
2. Install and configure at least one supported agent on your Mac: Codex, Claude, Pi Agent, or OpenCode. Chief checks which are ready during setup. Each service determines model access and costs.
3. Choose the agent that will serve as Chief and the agents it can assign work to. Finish setting up Tag Agent and Super Thread Agent, then click **Start using Chief**.
4. Describe your task in **Type a message…**. If the task uses a project folder, include its full path. Send the request and open its task card when Chief creates one.

No Go, Xcode, or Apple developer membership is needed to use the alpha.
Updates are manual, and alpha app data may be incompatible between versions.
Follow the accompanying installation guide when updating. Chief follows your
Mac's appearance and opens in Simplified Chinese when Chinese is the primary
system language. For all other primary languages, Chief uses English.

[Full installation and first-request guide →](docs/getting-started.md)

## Product guide

[Working with Chief](docs/working-with-moku.md) ·
[Overview](docs/overview.md) ·
[Agent conversations](docs/task-conversations.md) ·
[Tags, Super Threads, and file changes](docs/reports-tags-and-changes.md) ·
[Sidecards](docs/sidecards.md) ·
[Settings](docs/settings.md)

## License

Chief is licensed under the [Apache License 2.0](LICENSE).
Copyright 2026 hupao-creator.

Third-party materials retain their licenses and attribution notices, including
[agent skills](.agents/skills/LICENSE),
[fonts and icons](app/macos/Sources/Shared/PluginUI/Resources/), and
[Unicode data](internal/services/taglabel/UNICODE-LICENSE.txt).
