# Getting started with Mokusei

## Install Mokusei Alpha

You'll need a Mac with Apple silicon running macOS 26 or later.

1. Get the Mokusei Alpha disk image from your inviter and confirm its source and version.
2. Open the disk image and drag **Mokusei Alpha.app** into **Applications**. Eject the disk image, then open Mokusei Alpha from **Applications**.
3. If macOS says it can't verify the developer or check the app for malicious software, confirm that you trust the copy your inviter supplied. In **System Settings → Privacy & Security**, find the message for Mokusei Alpha, click **Open Anyway**, and follow the prompts. If macOS reports malware or a damaged app, or the app still won't open, send the full message and version to your inviter.

## Set up an agent

On a fresh install, Mokusei opens in Simplified Chinese. This guide uses the English interface labels. You can change the app's language in Settings after setup.

Mokusei works with Codex, Claude, Pi Agent, and OpenCode. Choose at least one, follow its installation instructions on this Mac, and sign in or set up a model as needed. Each service determines which models you can use and what they cost.

When you first open Mokusei, it checks for each agent. If an agent is missing, click **Install** to open its instructions. Once you've set it up, return to Mokusei and click **Check again** when that button is available. If Mokusei couldn't load an agent's settings, click **Retry** next to the error. You can click **Continue** as soon as one agent that can serve as Moku is ready. If other agents are still being checked, you can set up the ones that are ready and come back to see the rest.

## Choose who does what

1. On the **Moku** page, choose the agent that will talk to you and coordinate your work. Then choose at least one agent Moku can assign tasks to. Use the options on the page to finish choosing a model.
2. The next two pages set up the tag and report agents. Each offers **Agent off**, **Use Moku**, and **Configure separately**.
3. Click **Start using Moku**. Once your settings are saved, Moku's input box appears in the workspace. If you quit partway through setup, Mokusei opens to the agent check when you return and keeps the choices you've already saved.

If a setup page couldn't load or save your settings, click **Retry** next to the error. Fill in any missing choices, such as a model, before clicking **Continue** or **Start using Moku**. You can change these choices later. [Settings](settings.md)

## Send your first request

In the **Type a message…** box, describe what you want done and what you'd like to get back. If the work belongs to a project folder, type `@` and choose the folder before sending.

Moku can answer you directly or create an agent conversation to handle the task. Once the conversation is created, its card appears in **Overview** and Moku moves to the bottom of the window. Click the card to check progress, read the result, or respond to a request from the agent. [Working with Moku](working-with-moku.md)

## Update Mokusei Alpha

Alpha updates are manual. Quit Mokusei Alpha and back up its app data as described in the accompanying `READ-ME-FIRST.txt`. Then drag the new **Mokusei Alpha.app** into **Applications** and replace the existing copy.

App data may be incompatible between Alpha versions. macOS may also ask for file access or other permissions again after an update. Alpha keeps its own app data and uses the project folders and agent sign-ins you already have on this Mac.

[Back to the product guide](README.md)
