# Read and continue a task conversation

## Read a result

Click the task card in [Overview](overview.md). The conversation keeps finished replies and failure messages. When a run ends, the reading area usually shows its final answer on its own. Click **Show work** when it appears to see the reasoning and tools behind the answer. If you scroll up during a live run, use **Jump to latest** when it appears to return to the newest output.

Click the blank margin outside the conversation to return to Overview. The input bar folds as the conversation closes.

## Respond to a request or stop a run

If the agent asks a question or requests permission, respond to the prompt. The choices depend on the agent and its request.

To stop the current run, click **Stop this thread**. The button shares the **Send** position and appears when the run is active and the input box is empty. Keep any unsent draft you want before clearing the box. When the run stops, Chief receives a notification that you stopped it. You can send a new message to continue later. Closing the conversation or its **Execution** sidecard leaves the task running. [Watch a live run](sidecards.md#watch-a-run-in-progress)

## Send a follow-up or attachment

Type your follow-up in **Type a message…** and click **Send** or press Return. Use Shift+Return for a new line. If the current run accepts follow-ups, your message goes to that run. If it has ended, sending starts a new run in the same conversation. Answer any pending question or permission request first.

Click **+** and select an image or file on your Mac. It appears above your draft. Supported attachments vary by agent. If the agent rejects an attachment, remove it and try a supported type or describe it in text. You can return to finish an unsent draft after opening a different conversation.

You can start writing the next message while Chief confirms the previous send. Once the send succeeds, the next draft stays in the box. If the send is rejected, Chief puts the earlier message above your new text so you can review both before sending.

## Revisit or branch from an earlier run

When there are several runs to read, look for the short horizontal lines halfway down the left edge of the reading area. Each line in **Conversation contents** represents a run, from oldest at the top to newest at the bottom. The longer line marks the run on screen. In a narrow panel the lines shorten to fit the margin.

Hover over a line to preview the run, then click it to read. With keyboard focus on **Conversation contents**, use the Up and Down arrows to preview runs and Return to open one. Click the newest run’s line to return to it. You can then press Up to preview the previous run again. Any newer work keeps going while you read.

If you send a message from an earlier run, Chief tries to start a separate conversation from that point. The original stays intact. Branching depends on whether the agent can recover the selected run's history.

## Recover an interrupted send

If you see **Check the conversation for this interrupted send**, use **Check previous receipt** when available. If Chief asks you to check the conversation yourself, look for the earlier message. Choose **Keep next draft** if it arrived or **Restore to draft** to put it back above the new text. Review the draft before sending again.

If Chief says a branch was created but the message didn't send, choose what to keep and continue in that branch. If you see **Finish previous receipt cleanup**, click it before trying to send again.

[Back to the product guide](README.md)
