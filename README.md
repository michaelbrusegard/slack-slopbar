# Slack Menubar

A small, native macOS menu-bar utility that shows whether Slack has an unread
notification.

Slack Menubar reads the accessibility label on Slack's Dock badge. It does not
need a Slack token, send data anywhere, or inspect message contents.

## Status icons

- Filled four-color Slack-style mark: Slack has at least one unread notification
- Outlined monochrome Slack-style mark: Slack has no unread notifications
- `bell.slash`: Slack is not running and does not have a visible Dock item
- `exclamationmark.triangle`: Accessibility permission is required

When macOS exposes a numeric badge value, it is displayed beside the menu-bar
icon. The unread mark deliberately opts out of the standard macOS template
tint so its notification colors remain visible in both light and dark menu
bars.

## Requirements

- macOS 13 or newer
- Slack's Dock badge enabled in Slack's notification preferences
- Accessibility permission for Slack Menubar
- Xcode Command Line Tools to build from source

## Build and install

```sh
make test
make install
```

`make install` builds an ad-hoc-signed application, installs it at
`~/Applications/Slack Menubar.app`, and opens it.

On first launch, allow Slack Menubar in **System Settings → Privacy & Security
→ Accessibility**. If it was already open when permission was granted, choose
**Check Now** from its menu.

You can also build without installing:

```sh
make app
open "build/Slack Menubar.app"
```

Open `Package.swift` in Xcode for development.

## Launch at login

Choose **Launch at Login** from the app's menu. macOS manages the login item,
and it can also be reviewed under **System Settings → General → Login Items &
Extensions**.

## How it works

Every three seconds, the app:

1. Uses the macOS Accessibility API to locate Slack's item in the Dock.
2. Reads its `AXStatusLabel`.
3. Maps an empty label to no unread notifications and any non-empty label to
   unread notifications.

The polling happens locally and only traverses the Dock accessibility tree.
Message text, workspace information, and account credentials are never read.

## Limitations

- Slack must be running or otherwise visible in the Dock.
- Slack's own badge setting is the source of truth. Muted conversations or
  Slack notification preferences can affect whether the badge appears.
- Rebuilding or moving an ad-hoc-signed app can cause macOS to request
  Accessibility permission again.
