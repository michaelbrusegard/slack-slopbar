import AppKit
import OSLog
import ServiceManagement
import SlackMenubarCore

@main
@MainActor
final class SlackMenubarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let apiService = SlackAPIService()
  private let notificationStore = SlackNotificationStore()
  private let logger = Logger(
    subsystem: "com.michaelbrusegard.SlackMenubar",
    category: "SlackAPI"
  )

  private var statusItem: NSStatusItem!
  private var connectionState: SlackConnectionState = .unconfigured
  private var setupError: String?
  private var pendingOAuthRequest: SlackOAuthRequest?

  static func main() {
    let application = NSApplication.shared
    let delegate = SlackMenubarApp()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    apiService.onStateChange = { [weak self] state in
      guard let self else {
        return
      }
      connectionState = state
      logger.notice("Connection state: \(state.menuDescription, privacy: .public)")
      refreshUI()
    }
    apiService.onNotification = { [weak self] notification in
      guard let self else {
        return
      }
      logger.notice(
        "Received \(notification.kind.rawValue, privacy: .public)"
      )
      notificationStore.add(notification)
    }
    notificationStore.onChange = { [weak self] _ in
      self?.refreshUI()
    }

    refreshUI()
    loadCredentialsAndConnect()
  }

  func applicationWillTerminate(_ notification: Notification) {
    apiService.disconnect()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let callbackURL = urls.first(where: {
      $0.scheme == "slackmenubar" && $0.host == "oauth"
    }) else {
      return
    }
    finishSlackAuthorization(callbackURL)
  }

  func menuWillOpen(_ menu: NSMenu) {
    rebuildMenu(menu)
  }

  private func loadCredentialsAndConnect() {
    do {
      if let credentials = try SlackCredentialStore.load() {
        apiService.connect(using: credentials)
      } else {
        DispatchQueue.main.async { [weak self] in
          self?.configureSlack()
        }
      }
    } catch {
      setupError = "Keychain: \(error.localizedDescription)"
      refreshUI()
    }
  }

  private func refreshUI() {
    updateStatusItem()
    if let menu = statusItem.menu, menu.numberOfItems > 0 {
      rebuildMenu(menu)
    }
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else {
      return
    }

    let count = notificationStore.notifications.count
    let hasNotifications = count > 0
    button.image = SlackStatusIcon.slackMark(filled: hasNotifications)
    button.title = hasNotifications ? " \(count)" : ""

    let description =
      hasNotifications
      ? "Slack has \(count) pending \(count == 1 ? "notification" : "notifications")"
      : "Slack has no pending notifications"
    button.setAccessibilityLabel(description)
    button.toolTip = description
  }

  private func rebuildMenu(_ menu: NSMenu) {
    menu.removeAllItems()

    let connection = NSMenuItem(
      title: connectionState.menuDescription,
      action: nil,
      keyEquivalent: ""
    )
    connection.isEnabled = false
    menu.addItem(connection)

    if let setupError {
      let error = NSMenuItem(title: setupError, action: nil, keyEquivalent: "")
      error.isEnabled = false
      menu.addItem(error)
    }

    if notificationStore.notifications.isEmpty {
      let empty = NSMenuItem(
        title: "No pending DMs or mentions",
        action: nil,
        keyEquivalent: ""
      )
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      menu.addItem(.separator())
      let heading = NSMenuItem(
        title: "Notifications",
        action: nil,
        keyEquivalent: ""
      )
      heading.isEnabled = false
      menu.addItem(heading)

      for notification in notificationStore.notifications.prefix(20) {
        let item = NSMenuItem(
          title: notificationTitle(notification),
          action: #selector(openNotification(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = notification.id
        item.toolTip = notification.receivedAt.formatted(
          date: .abbreviated,
          time: .shortened
        )
        menu.addItem(item)
      }

      if notificationStore.notifications.count > 20 {
        let remaining = notificationStore.notifications.count - 20
        let more = NSMenuItem(
          title: "…and \(remaining) more",
          action: nil,
          keyEquivalent: ""
        )
        more.isEnabled = false
        menu.addItem(more)
      }

      menu.addItem(
        withTitle: "Clear All Notifications",
        action: #selector(clearNotifications),
        keyEquivalent: ""
      ).target = self
    }

    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Open Slack",
      action: #selector(openSlack),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Slack Setup Assistant…",
      action: #selector(configureSlack),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Reconnect",
      action: #selector(reconnect),
      keyEquivalent: "r"
    ).target = self
    menu.addItem(
      withTitle: "Create or Manage Slack App…",
      action: #selector(openSlackAppManagement),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Copy Slack App Manifest",
      action: #selector(copySlackAppManifest),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Remove Slack Credentials…",
      action: #selector(removeCredentials),
      keyEquivalent: ""
    ).target = self

    let launchAtLogin = NSMenuItem(
      title: "Launch at Login",
      action: #selector(toggleLaunchAtLogin),
      keyEquivalent: ""
    )
    launchAtLogin.target = self
    launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(launchAtLogin)

    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit Slack Menubar",
      action: #selector(quit),
      keyEquivalent: "q"
    ).target = self
  }

  private func notificationTitle(_ notification: SlackMenuNotification) -> String {
    switch notification.kind {
    case .directMessage:
      return "\(notification.senderName) — direct message"
    case .mention:
      return "\(notification.senderName) mentioned you in \(notification.conversationName)"
    }
  }

  @objc private func configureSlack() {
    let alert = NSAlert()
    alert.messageText = "Set up Slack Menubar"
    alert.informativeText =
      """
      Slack Menubar uses a private Slack app in your workspace.

      1. Create the app from the manifest copied for you.
      2. Copy its Client ID and generate one Socket Mode app token.
      3. Approve access in Slack. The user token is handled automatically.
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Create Slack App")
    alert.addButton(withTitle: "Enter App Details")
    alert.addButton(withTitle: "Cancel")

    NSApplication.shared.activate(ignoringOtherApps: true)
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      openPrefilledSlackAppCreation()
      showAppDetailsForm()
    case .alertSecondButtonReturn:
      showAppDetailsForm()
    default:
      return
    }
  }

  private func showAppDetailsForm() {
    let existingCredentials = try? SlackCredentialStore.load()

    let clientIDField = NSTextField(string: existingCredentials?.clientID ?? "")
    clientIDField.placeholderString = "For example, 123456789.987654321"
    clientIDField.controlSize = .regular
    clientIDField.translatesAutoresizingMaskIntoConstraints = false

    let appTokenField = NSSecureTextField(string: existingCredentials?.appToken ?? "")
    appTokenField.placeholderString = "xapp-…"
    appTokenField.controlSize = .regular
    appTokenField.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      clientIDField.widthAnchor.constraint(equalToConstant: 420),
      appTokenField.widthAnchor.constraint(equalToConstant: 420),
    ])

    let clientIDLabel = NSTextField(labelWithString: "Client ID")
    let appTokenLabel = NSTextField(labelWithString: "App-level token (xapp)")

    let stack = NSStackView(views: [
      clientIDLabel,
      clientIDField,
      appTokenLabel,
      appTokenField,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    stack.frame = NSRect(x: 0, y: 0, width: 430, height: 112)

    let alert = NSAlert()
    alert.messageText = "Finish creating the Slack app"
    alert.informativeText =
      """
      The manifest is already on your clipboard.

      1. In Slack, choose From a manifest.
      2. Select YAML and press ⌘V.
      3. Select your workspace underneath the YAML, then choose Next.
      4. Review the configuration and choose Create.
      5. On Basic Information, copy Client ID from App Credentials.
      6. Under App-Level Tokens, choose Generate Token and Scopes.
      7. Name it Slack Menubar, add connections:write, and generate it.
      8. Paste the Client ID and xapp token below.
      """
    alert.alertStyle = .informational
    alert.accessoryView = stack
    alert.addButton(withTitle: "Connect with Slack")
    alert.addButton(withTitle: "Open Slack Apps")
    alert.addButton(withTitle: "Cancel")

    NSApplication.shared.activate(ignoringOtherApps: true)
    while true {
      let response = alert.runModal()
      if response == .alertSecondButtonReturn {
        openSlackAppManagement()
        continue
      }
      guard response == .alertFirstButtonReturn else {
        return
      }

      let clientID = clientIDField.stringValue.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      let appToken = appTokenField.stringValue.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !clientID.isEmpty, appToken.hasPrefix("xapp-") else {
        showError(
          title: "Check the app details",
          message: "Enter the Client ID and an app token beginning with xapp-."
        )
        continue
      }

      startSlackAuthorization(clientID: clientID, appToken: appToken)
      return
    }
  }

  private func startSlackAuthorization(clientID: String, appToken: String) {
    let oauthRequest = SlackOAuthRequest(clientID: clientID, appToken: appToken)
    guard let authorizationURL = oauthRequest.authorizationURL else {
      showError(
        title: "Could not start Slack authorization",
        message: "Slack Menubar could not construct the authorization URL."
      )
      return
    }
    pendingOAuthRequest = oauthRequest
    setupError = nil
    NSWorkspace.shared.open(authorizationURL)
  }

  private func finishSlackAuthorization(_ callbackURL: URL) {
    guard let oauthRequest = pendingOAuthRequest else {
      showError(
        title: "Authorization expired",
        message: "Open Slack Setup Assistant and try connecting again."
      )
      return
    }

    let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
      .queryItems
    var values: [String: String] = [:]
    for item in queryItems ?? [] {
      values[item.name] = item.value
    }
    guard values["state"] == oauthRequest.state else {
      pendingOAuthRequest = nil
      showError(
        title: "Could not verify Slack authorization",
        message: "The OAuth state did not match. Please try again."
      )
      return
    }
    if let slackError = values["error"] {
      pendingOAuthRequest = nil
      showError(
        title: "Slack authorization was not completed",
        message: slackError
      )
      return
    }
    guard let code = values["code"] else {
      pendingOAuthRequest = nil
      showError(
        title: "Slack did not return an authorization code",
        message: "Open Slack Setup Assistant and try again."
      )
      return
    }

    pendingOAuthRequest = nil
    Task {
      do {
        let credentials = try await SlackOAuthClient.exchange(
          code: code,
          request: oauthRequest
        )
        guard credentials.isPlausible else {
          throw SlackSetupError.invalidToken
        }
        try SlackCredentialStore.save(credentials)
        setupError = nil
        apiService.connect(using: credentials)
        showAuthorizationComplete()
      } catch {
        setupError = "Slack setup: \(error.localizedDescription)"
        refreshUI()
        showError(
          title: "Could not finish Slack authorization",
          message: error.localizedDescription
        )
      }
    }
  }

  private func showAuthorizationComplete() {
    let alert = NSAlert()
    alert.messageText = "Slack authorization is complete"
    alert.informativeText =
      "Slack Menubar is connecting now. The menu will show the workspace name once it is ready."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Done")
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  @objc private func reconnect() {
    do {
      guard let credentials = try SlackCredentialStore.load() else {
        configureSlack()
        return
      }
      setupError = nil
      apiService.connect(using: credentials)
    } catch {
      setupError = "Keychain: \(error.localizedDescription)"
      refreshUI()
    }
  }

  @objc private func removeCredentials() {
    let alert = NSAlert()
    alert.messageText = "Remove Slack API credentials?"
    alert.informativeText =
      "Slack Menubar will disconnect and clear its pending notifications."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")

    NSApplication.shared.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      try SlackCredentialStore.remove()
      apiService.disconnect()
      notificationStore.clear()
      connectionState = .unconfigured
      setupError = nil
    } catch {
      setupError = "Keychain: \(error.localizedDescription)"
    }
    refreshUI()
  }

  @objc private func openNotification(_ sender: NSMenuItem) {
    guard
      let notificationID = sender.representedObject as? String,
      let notification = notificationStore.notifications.first(where: {
        $0.id == notificationID
      })
    else {
      return
    }

    var components = URLComponents()
    components.scheme = "slack"
    components.host = "channel"
    components.queryItems = [
      URLQueryItem(name: "team", value: notification.teamID),
      URLQueryItem(name: "id", value: notification.channelID),
      URLQueryItem(name: "message", value: notification.messageTimestamp),
    ]
    if let url = components.url {
      NSWorkspace.shared.open(url)
    }
    notificationStore.remove(id: notificationID)
  }

  @objc private func clearNotifications() {
    notificationStore.clear()
  }

  @objc private func openSlack() {
    if let url = URL(string: "slack://open") {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func openSlackAppManagement() {
    if let url = URL(string: "https://api.slack.com/apps") {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func copySlackAppManifest() {
    guard let manifest = bundledSlackAppManifest() else {
      showError(
        title: "Manifest unavailable",
        message:
          "Build the app bundle with make app or copy SlackAppManifest.yaml from the repository."
      )
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(manifest, forType: .string)
  }

  private func openPrefilledSlackAppCreation() {
    guard let manifest = bundledSlackAppManifest() else {
      showError(
        title: "Manifest unavailable",
        message: "Slack Menubar could not load its bundled app configuration."
      )
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(manifest, forType: .string)

    guard let url = URL(string: "https://api.slack.com/apps?new_app=1") else {
      showError(
        title: "Could not open Slack app creation",
        message: "Use Copy Slack App Manifest from the menu as a fallback."
      )
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func bundledSlackAppManifest() -> String? {
    guard
      let url = Bundle.main.url(
        forResource: "SlackAppManifest",
        withExtension: "yaml"
      )
    else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  @objc private func toggleLaunchAtLogin() {
    setupError = nil
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      setupError = "Launch at Login: \(error.localizedDescription)"
    }
    refreshUI()
  }

  private func showError(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}

private enum SlackSetupError: LocalizedError {
  case invalidToken

  var errorDescription: String? {
    "Slack returned an unexpected user token."
  }
}
