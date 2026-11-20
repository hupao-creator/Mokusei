# Get started with Chief

## Install Chief Alpha

You'll need a Mac with Apple silicon running macOS 26 or later.

1. Get the Chief Alpha disk image and `READ-ME-FIRST.txt` from your inviter. Confirm the source and version.
2. Open the disk image, drag **Chief Alpha.app** into **Applications**, and eject the disk image. Open Chief Alpha from **Applications**.
3. If macOS says it can't verify the developer or check the app for malicious software, confirm that you trust this copy. In **System Settings → Privacy & Security**, find the message for Chief Alpha and click **Open Anyway**. If macOS reports malware or damage, or the app still won't open, send the full message and version to your inviter.

## Connect an agent

Chief opens in Simplified Chinese if Chinese is first in your Mac's preferred languages. For every other primary language, Chief opens in English. This guide uses the English labels. [Change appearance or language on your Mac](settings.md#change-appearance-or-language-on-your-mac)

Chief checks for Codex, Claude, Pi Agent, and OpenCode on your Mac. To set up a missing agent, click **Install** on the first setup page to open its installation instructions. Follow those instructions and sign in or set up a model as needed. Model access and costs depend on the service you use.

Return to Chief. Click **Check again** if it appears, or **Retry** next to an agent that couldn't load. You can click **Continue** once an agent that can serve as Chief is ready. Use **Back** if you want to return to the first page and check any other agents.

## Choose who does what

1. On the **Chief** page, choose the agent that will talk to you and coordinate your work. Below it, choose at least one agent it may assign tasks to. Complete any required model choices and click **Continue**.
2. On the next two pages, choose how to run **Tag Agent** and **Super Thread Agent**. For either role, choose **Agent off**, **Use Chief**, or **Configure separately**. [What each option does](settings.md#set-up-tag-agent-and-super-thread-agent)
3. Click **Start using Chief**. The setup panel shrinks into Chief's input box. If the window stays active and visible, Chief's eyes blink once as the box appears. You can start typing as soon as setup closes.

If you see a load or save error, use **Retry** next to it. If you quit partway through setup, Chief returns to the agent check and keeps the choices you've already saved.

## Send your first request

In **Type a message…**, describe what you want done and what you'd like to get back. Include your project folder's full path if you want Chief to work there.

Chief can reply directly or assign the work to an agent. When it creates a task conversation, click its card in **Overview** to check progress, read the result, or respond to a request. [Working with Chief](working-with-moku.md)

## Update Chief Alpha

Quit Chief Alpha before updating. Back up `~/Library/Application Support/Mokusei Alpha`, then replace **Chief Alpha.app** in **Applications** with the copy from the new disk image. If the installed app is named **Mokusei Alpha.app**, move it out of **Applications** before installing Chief Alpha.

Alpha updates are manual. App data may be incompatible between versions, and macOS may ask for permissions again. Alpha has its own app data and uses the project folders and agent sign-ins you already have on this Mac.

[Back to the product guide](README.md)
