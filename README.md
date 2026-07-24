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

Slack Menubar includes a setup assistant. Open the menu-bar item and choose
**Slack Setup Assistant…**:

1. Select **Create Slack App**. The assistant copies the ready-made manifest
   and opens Slack's app-creation page.
2. If Slack shows its app-type chooser, select **From a manifest**, choose your
   workspace, select **YAML**, and paste. Review the configuration and create
   the app.
3. Under **Basic Information → App Credentials**, copy the **Client ID**.
4. On the same page under **App-Level Tokens**, select **Generate Token and
   Scopes**. Name it `Slack Menubar`, add `connections:write`, and copy the
   generated token beginning with `xapp-`.
5. Return to the assistant, enter those two values, and select
   **Connect with Slack**.
6. Approve the requested access on Slack's website. Slack returns directly to
   Slack Menubar and the connection starts automatically.

You never need to find or paste a user OAuth token. Slack Menubar uses PKCE,
stores its rotating access and refresh tokens only in macOS Keychain, and
refreshes them automatically. Tokens are never written to the repository,
UserDefaults, or logs.

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
