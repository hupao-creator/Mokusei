# Find related work and check file changes

## Group tasks with tags

**Tag Agent** uses conversation titles to group unarchived tasks within each project folder. Each folder can have up to five tags, and Inbox has its own set. Select a folder or tag in [Overview](overview.md#find-a-task-by-folder-or-tag). Existing tags stay available while Tag Agent is off, and sorting resumes when you turn it back on. [Set up Tag Agent](settings.md#set-up-tag-agent-and-super-thread-agent)

## See the work behind a Super Thread

A **Super Thread** is a report that **Super Thread Agent** puts together from completed work in the same project folder. Its card shows up to three lines of the introduction, including when you browse a collection. Click the card to read the report, then open **Related executions** if the list is closed.

A Super Thread can cite one run per source conversation. Each related card shows that run's title, a reply excerpt, and its duration when available. The status tells you how the source conversation is doing now.

Click the related card to open the source conversation's latest run beside the Super Thread. It may be newer than the cited run or still in progress. Use **Conversation contents** on the left edge of the source conversation to switch between its current run and earlier runs. The Super Thread stays open beside it. When you follow a link from Chief Note, a collection containing the Super Thread turns to its page before it opens. The side panel opens at the top of the run named in the note, even if the related card cites a different run. If a related card fails to open, click it again to retry. The list shows when a conversation or run is unavailable.

Use the input below the source conversation to write a follow-up for the run you’re viewing. If you switch runs before sending, select the same run again to pick up your draft. Click **Back to related executions** to return to the list. If you came from Chief Note, the report’s **×** takes you straight to Overview with the note closed while the source conversation is open. To resume the note, first return to the list, then click **Back to Chief Note** on the report.

## Browse Super Threads in a collection

A collection shows one Super Thread at a time and can turn pages automatically. To choose a Super Thread, move the pointer over the card and use the arrows or the page menu between them. Collections of up to seven Super Threads also show a clickable marker for each page. Click the card to read the displayed Super Thread. Use **Close Super Thread** in the reader to return to Overview.

To browse all members, click the page count in the upper-right corner of the collection card. Scroll the grid and click a Super Thread. The reader expands from the card you chose, just as it does on Overview. With macOS **Reduce motion** enabled, the reader switches directly. It may show a loading indicator while the report loads.

Click the reader’s upper-left arrow, **Back to Super Thread Collection**, to return to your place in the grid. You can read another member from there. The grid’s **Close** button stays in the upper-left corner as you scroll. At high window zoom, the cards fit in one column below it. Click **Close** or press **Esc** in the grid to return to Overview. Any regrouping caused by reading those members takes effect when you close the grid.

After a quick look at a Super Thread, its cover stays selected if it is still in the collection. Spending time reading a Super Thread or its source conversations, or returning to it within a day, gives it a better chance of appearing as an individual card. The available space also affects which Super Threads stay grouped.

## Archive a Super Thread

Right-click a Super Thread card and choose **Archive Super Thread**. In the list of all reports in a collection, you can also click the archive button on the card’s upper-right corner.

The Super Thread and its linked task conversations disappear from Overview. Their records stay saved and any work already running continues.

When archiving leaves the collection open, the archived card briefly fades away. With macOS **Reduce motion** enabled, it disappears immediately. If fewer than two Super Threads remain in the collection, the panel closes and any remaining Super Threads appear as individual cards in Overview.

## Check Git changes on a task card

For tasks in projects that use Git, the card can show the branch, number of changed files, and lines added or removed. These figures describe the working folder the task uses. Several tasks using the same folder can show the same changes. The summary is hidden when both line counts are zero. If files changed but Chief couldn't count the lines, the card shows that the count is unavailable.

Click the card to open the conversation and ask the agent about its changes.

[Back to the product guide](README.md)
