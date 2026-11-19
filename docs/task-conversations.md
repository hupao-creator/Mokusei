# Read and continue agent conversations

## Read the result or respond to a request

In Overview, click a task card. The conversation shows replies the agent has finished and keeps any failure messages. The full text of a reply appears when the agent finishes writing it. When a run ends, the reading area usually shows the final answer on its own and folds earlier replies into the details of that run. Click **Show work** to see a summary of the agent's reasoning and tool use. [Overview](overview.md)

If the agent asks you to make a choice or grant permission, respond to the prompt. The options depend on the agent and its request. While a run is active and the input box has nothing waiting to send, the **Stop this thread** button is available. Click it to stop the current run. You can send a new message to continue later. The task keeps running if you close the conversation or collapse its sidecard.

## Send follow-ups and attachments

Type your follow-up at the bottom of the conversation and click **Send**. If the current run accepts follow-ups, your message goes to that run. If the run has ended, your message starts a new run in the same conversation. Respond to any pending request first.

After you send, you can immediately type your next message in the same box. **Send** becomes available again when the previous send finishes. Your next message stays in the box until you send it. If a send fails, Chief shows the reason and restores the failed message above any new text. Review the draft before sending it again.

If you reopen a conversation and see **Check the conversation for this interrupted send**, click **Check previous receipt** if it is available. While the host is still confirming the message, your next draft stays editable. Confirmation keeps the next draft. A rejection restores the earlier message above it. If Chief offers local recovery, look for the earlier message in the conversation. Choose **Keep next draft** if it arrived, or **Restore to draft** to put the earlier message above what you typed next. Both choices leave the text in the input box for you to review. Only **Send** or Return submits it.

If Chief says the fork exists and the message was not sent, choose what to keep and open the created branch to continue there. If **Finish previous receipt cleanup** appears, click it to release the settled receipt and send your next draft.

Click **+** to add an image or file. Supported attachments vary by agent. If an agent rejects an attachment type, remove the attachment and try a supported type or describe it in text. If you switch conversations, you can come back to finish editing your unsent message.

## Revisit an earlier run

When the conversation has multiple runs or includes history from an earlier conversation, use **Conversation contents** in the reading area to choose a run. Hover over an entry to see its title. If it has no title, look for the original request or the time. Use the back button in the reading area to leave the earlier run.

Sending from the latest run continues the same conversation. Sending from an earlier run tries to start a separate conversation from that point and keeps the original conversation. Reading an earlier run leaves newer work running. To use **Stop this thread**, return to the active run. You can also ask Chief to stop tasks by name. [Working with Chief](working-with-moku.md)

[Back to the product guide](README.md)
