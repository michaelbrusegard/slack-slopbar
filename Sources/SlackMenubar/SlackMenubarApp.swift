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
      withTitle: "Configure Slack API…",
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
    let existingCredentials = try? SlackCredentialStore.load()

    let appTokenField = NSSecureTextField(string: existingCredentials?.appToken ?? "")
    appTokenField.placeholderString = "xapp-…"
    appTokenField.frame.size = NSSize(width: 390, height: 24)

    let userTokenField = NSSecureTextField(string: existingCredentials?.userToken ?? "")
    userTokenField.placeholderString = "xoxp-…"
    userTokenField.frame.size = NSSize(width: 390, height: 24)

    let appTokenLabel = NSTextField(labelWithString: "App-level token (xapp)")
    let userTokenLabel = NSTextField(labelWithString: "User OAuth token (xoxp)")

    let stack = NSStackView(views: [
      appTokenLabel,
      appTokenField,
      userTokenLabel,
      userTokenField,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    stack.frame = NSRect(x: 0, y: 0, width: 400, height: 104)

    let alert = NSAlert()
    alert.messageText = "Connect Slack Menubar"
    alert.informativeText =
      "Paste the tokens from the private Slack app created with SlackAppManifest.yaml. They are stored only in macOS Keychain."
    alert.alertStyle = .informational
    alert.accessoryView = stack
    alert.addButton(withTitle: "Save & Connect")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Copy App Manifest")

    NSApplication.shared.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if response == .alertThirdButtonReturn {
      copySlackAppManifest()
      configureSlack()
      return
    }
    guard response == .alertFirstButtonReturn else {
      return
    }

    let credentials = SlackCredentials(
      appToken: appTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      userToken: userTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard credentials.isPlausible else {
      showError(
        title: "Invalid Slack tokens",
        message: "The app token must begin with xapp- and the user token with xoxp-."
      )
      return
    }

    do {
      try SlackCredentialStore.save(credentials)
      setupError = nil
      apiService.connect(using: credentials)
    } catch {
      setupError = "Keychain: \(error.localizedDescription)"
      showError(title: "Could not save Slack tokens", message: error.localizedDescription)
    }
    refreshUI()
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
    guard
      let url = Bundle.main.url(
        forResource: "SlackAppManifest",
        withExtension: "yaml"
      ),
      let manifest = try? String(contentsOf: url, encoding: .utf8)
    else {
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
