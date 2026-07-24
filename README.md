# Slack Menubar

A native macOS menu-bar utility that keeps direct messages and personal Slack
mentions visible until you acknowledge them.

Slack Menubar connects directly to Slack using a private Slack app and Socket
Mode. It does not rely on Slack's unreliable macOS Dock badge and does not need
a hosted server.

## Behavior

- A filled four-color Slack-style mark means notifications are pending.
- An outlined monochrome mark means the notification list is clear.
- The pending count appears beside the icon.
- The menu identifies the sender and whether the event was a DM or mention.
- Selecting an item opens its Slack conversation and removes the item.
- **Clear All Notifications** acknowledges everything without opening Slack.

Pending items persist across app restarts. Slack auto-marking a visible
conversation as read does not remove them.

## Slack app setup

Slack Menubar needs one private Slack app for your workspace:

1. Open [Slack app management](https://api.slack.com/apps).
2. Select **Create New App → From an app manifest**.
3. Choose your workspace, select **YAML**, and paste the contents of
   [`SlackAppManifest.yaml`](SlackAppManifest.yaml).
4. Create the app.
5. Under **Basic Information → App-Level Tokens**, select **Generate Token and
   Scopes**. Name it `Slack Menubar`, add `connections:write`, generate it, and
   copy the token beginning with `xapp-`.
6. Under **OAuth & Permissions**, select **Install to Workspace** (or
   **Reinstall to Workspace**) and approve the requested user permissions.
7. On the same page, copy the **User OAuth Token** beginning with `xoxp-`.
8. Open Slack Menubar's menu, choose **Configure Slack API…**, and paste both
   tokens.

The tokens are stored only in macOS Keychain. They are never written to the
repository, UserDefaults, or logs.

Your workspace may require an administrator to approve the app installation.

## Permissions and privacy

Slack requires message-history scopes to deliver user-level message events.
The manifest requests access to public channels, private channels, DMs, and
group DMs that the authorizing user can already access, plus basic user names.

Slack Menubar filters the live event stream to:

- Messages in one-to-one DMs.
- Channel, private-channel, and group-DM messages containing a direct mention
  of your Slack user ID.

Message bodies are inspected in memory only for mention matching. The app
stores sender name, conversation name, message timestamp, and Slack IDs for
pending notifications; it does not persist message text.

## Build and install

Requirements:

- macOS 13 or newer
- Xcode Command Line Tools

```sh
make test
make install
```

`make install` builds a signed application, installs it at
`~/Applications/Slack Menubar.app`, and opens it.

When an Apple Development signing identity is available, the build uses it.
Otherwise, it falls back to ad-hoc signing.

You can build without installing:

```sh
make app
open "build/Slack Menubar.app"
```

Open `Package.swift` in Xcode for development.

## Launch at login

Choose **Launch at Login** from the app menu. Keeping the app running matters:
Socket Mode delivers live events and the app does not currently backfill events
missed while it was offline.

## Current notification coverage

Slack Menubar intentionally does not notify for every channel message. It also
does not yet reproduce Slack's keyword notifications, followed-thread replies,
user-group mentions, `@here`, or `@channel`. These can be added later, but they
require more preference and membership data to match Slack's behavior.
