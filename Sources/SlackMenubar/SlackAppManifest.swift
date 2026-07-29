import Foundation

// The Slack app manifest is generated from the same constants the OAuth flow
// uses, so the scopes the app requests and the scopes the manifest grants
// cannot drift apart, and the Copy Manifest button works in every build
// (no bundled resource to go missing).
enum SlackAppManifest {
  static let userEvents = [
    "message.channels",
    "message.groups",
    "message.im",
    "message.mpim",
  ]

  static var yaml: String {
    var lines = [
      "display_information:",
      "  name: Slack Menubar",
      "  description: Personal macOS menu-bar notifications for Slack DMs and mentions",
      "  background_color: \"#4A154B\"",
      "oauth_config:",
      "  pkce_enabled: true",
      "  redirect_urls:",
      "    - \(SlackOAuthClient.redirectURI)",
      "  scopes:",
      "    user:",
    ]
    lines += SlackOAuthClient.userScopes.map { "      - \($0)" }
    lines += [
      "settings:",
      "  event_subscriptions:",
      "    user_events:",
    ]
    lines += userEvents.map { "      - \($0)" }
    lines += [
      "  org_deploy_enabled: false",
      "  socket_mode_enabled: true",
      "  token_rotation_enabled: true",
    ]
    return lines.joined(separator: "\n") + "\n"
  }
}
