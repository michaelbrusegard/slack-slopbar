# Slack Menubar

A native macOS menu-bar utility that shows everything you have not read in
Slack: unread channels, direct messages, group DMs, and mentions.

Slack Menubar connects directly to Slack using a private Slack app. Slack's
own per-conversation read state is the source of truth, so the menu matches
Slack exactly — it survives app restarts, network drops, and reading on other
devices. Socket Mode events only make updates instant.

## Behavior

- A filled four-color Slack-style mark means unread conversations exist; an
  outlined monochrome mark means everything is read.
- The count beside the icon tracks Slack's red badge: direct messages and
  mentions. Plain channel unreads fill the icon without a number.
- The menu groups unreads into **Mentions**, **Direct Messages**, and
  **Channels**, with per-conversation unread counts.
- Selecting an item opens the conversation in Slack; reading it there clears
  the item automatically (anywhere — desktop, mobile, web).
- **Dismiss All** hides current unreads locally; a conversation reappears as
  soon as it gets new messages.

How it stays correct:

- A full unread sweep of every conversation you are a member of runs at
  connect, after reconnects, and on wake from sleep — nothing that happened
  while the app was closed is missed.
- Live Socket Mode messages re-check just the affected conversation within
  about a second.
- Conversations currently unread are re-checked adaptively: about every two
  seconds when one conversation is pending, scaling with the number of
  conversations to stay within Slack's API rate limit. Opening the menu also
  triggers an immediate check.
- The connection line shows when unread state was last checked and visibly
  reports retries instead of silently treating a failed request as current.

The unread list persists across restarts and refreshes as soon as the first
sweep completes. In workspaces with very many channels the initial sweep can
take a few minutes because Slack rate-limits per-conversation lookups; the
menu fills in progressively afterward.

## Slack app setup

Slack Menubar includes a setup assistant. Open the menu-bar item and choose
**Slack Setup Assistant…**:

1. Select **Copy Manifest**, then **Create Slack App**. The assistant opens
   Slack's app-creation page.
2. If Slack shows its app-type chooser, select **From a manifest**, select
   **YAML**, and paste. Select your workspace underneath the YAML, choose
   **Next**, review the configuration, and create the app.
3. Under **Basic Information → App Credentials**, copy the **Client ID**.
4. On the same page under **App-Level Tokens**, select **Generate Token and
   Scopes**. Name it `Slack Menubar`, add `connections:write`, and copy the
   generated token beginning with `xapp-`.
5. Return to the assistant, enter those two values, and select
   the target workspace detected from Slack desktop. Select **Connect with
   Slack**.
6. Confirm the same workspace on Slack's permission page and approve the
   requested access. Slack returns directly to Slack Menubar and the connection
   starts automatically.

You never need to find or paste a user OAuth token. Slack Menubar uses PKCE,
stores its rotating access and refresh tokens only in macOS Keychain, and
refreshes them automatically. Tokens are never written to the repository,
UserDefaults, or logs.

For convenience, the assistant reads workspace names and IDs from Slack
desktop's local state. It does not read or retain Slack session tokens or
message data.

Your workspace may require an administrator to approve the app installation.

## Permissions and privacy

Slack requires message-history scopes to deliver user-level message events.
The manifest requests access to public channels, private channels, DMs, and
group DMs that the authorizing user can already access, plus basic user names.

Slack Menubar tracks unread state for every conversation you are a member of
and detects mentions of your Slack user ID in live messages, including
mentions inside bot messages' Block Kit content and legacy attachments.

Message bodies are inspected in memory only for mention matching. The app
stores conversation names, unread counts, read markers, and Slack IDs; it
does not persist message text.

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

Choose **Launch at Login** from the app menu. The app catches up on everything
it missed whenever it reconnects, but only a running app updates instantly.

## Known limitations

- Muted channels still count as unread — Slack's public API does not expose
  mute preferences, so the menu may show conversations Slack itself would not
  badge.
- Mentions are flagged from the live event stream, so a mention that arrives
  while the app is offline shows up as a plain unread rather than under
  **Mentions** until a newer mention arrives.
- Keyword notifications, followed-thread replies, user-group mentions,
  `@here`, and `@channel` are not distinguished from plain unreads.
