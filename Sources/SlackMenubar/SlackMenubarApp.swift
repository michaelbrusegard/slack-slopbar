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
  private var setupWindow: NSWindow?
  private var setupClientIDField: NSTextField?
  private var setupAppTokenField: NSSecureTextField?

  static func main() {
    let application = NSApplication.shared
    let delegate = SlackMenubarApp()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureApplicationMenu()
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

  private func configureApplicationMenu() {
    let mainMenu = NSMenu()

    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "Quit Slack Menubar",
      action: #selector(quit),
      keyEquivalent: "q"
    ).target = self
    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
      withTitle: "Undo",
      action: Selector(("undo:")),
      keyEquivalent: "z"
    )
    editMenu.addItem(.separator())
    editMenu.addItem(
      withTitle: "Cut",
      action: #selector(NSText.cut(_:)),
      keyEquivalent: "x"
    )
    editMenu.addItem(
      withTitle: "Copy",
      action: #selector(NSText.copy(_:)),
      keyEquivalent: "c"
    )
    editMenu.addItem(
      withTitle: "Paste",
      action: #selector(NSText.paste(_:)),
      keyEquivalent: "v"
    )
    editMenu.addItem(
      withTitle: "Select All",
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    NSApplication.shared.mainMenu = mainMenu
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
    if let setupWindow {
      NSApplication.shared.activate(ignoringOtherApps: true)
      setupWindow.makeKeyAndOrderFront(nil)
      return
    }

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

    let title = NSTextField(labelWithString: "Connect Slack Menubar")
    title.font = .systemFont(ofSize: 24, weight: .semibold)

    let introduction = setupDescription(
      "This private Slack app sends your DMs and mentions directly to the menu bar. Complete the three steps below once."
    )

    let createTitle = setupSectionTitle("1. Create or open the Slack app")
    let createDescription = setupDescription(
      """
      Create Slack App copies the manifest and opens Slack. Choose From a manifest, select YAML, paste, select your workspace underneath, then choose Next and Create.
      """
    )
    let createButton = NSButton(
      title: "Create Slack App",
      target: self,
      action: #selector(createSlackAppFromSetupForm)
    )
    createButton.bezelStyle = .rounded
    let openButton = NSButton(
      title: "Open Existing Slack App",
      target: self,
      action: #selector(openSlackAppsFromSetupForm)
    )
    openButton.bezelStyle = .rounded
    let appButtons = NSStackView(views: [createButton, openButton])
    appButtons.orientation = .horizontal
    appButtons.spacing = 8

    let detailsTitle = setupSectionTitle("2. Enter the two app details")
    let detailsDescription = setupDescription(
      """
      On Basic Information, copy Client ID from App Credentials. Under App-Level Tokens, generate a token named Slack Menubar with the connections:write scope.
      """
    )
    let clientIDLabel = setupFieldLabel("Client ID")
    let appTokenLabel = setupFieldLabel("App-level token (xapp)")

    let authorizeTitle = setupSectionTitle("3. Authorize your Slack account")
    let authorizeDescription = setupDescription(
      "Slack will open a permission screen and return here automatically. Access and refresh tokens stay in macOS Keychain."
    )
    let connectButton = NSButton(
      title: "Connect with Slack",
      target: self,
      action: #selector(connectFromSetupForm)
    )
    connectButton.bezelStyle = .rounded
    connectButton.controlSize = .large
    connectButton.keyEquivalent = "\r"

    let stack = NSStackView(views: [
      title,
      introduction,
      setupSeparator(),
      createTitle,
      createDescription,
      appButtons,
      setupSeparator(),
      detailsTitle,
      detailsDescription,
      clientIDLabel,
      clientIDField,
      appTokenLabel,
      appTokenField,
      setupSeparator(),
      authorizeTitle,
      authorizeDescription,
      connectButton,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false

    let contentView = NSView()
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(
        lessThanOrEqualTo: contentView.trailingAnchor,
        constant: -28
      ),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: contentView.bottomAnchor,
        constant: -26
      ),
    ])

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 590),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Slack Menubar Setup"
    window.contentView = contentView
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.center()

    setupWindow = window
    setupClientIDField = clientIDField
    setupAppTokenField = appTokenField

    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(clientIDField)
  }

  private func setupSectionTitle(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 15, weight: .semibold)
    return field
  }

  private func setupDescription(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.textColor = .secondaryLabelColor
    field.preferredMaxLayoutWidth = 420
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 420).isActive = true
    return field
  }

  private func setupFieldLabel(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 12, weight: .medium)
    return field
  }

  private func setupSeparator() -> NSBox {
    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.widthAnchor.constraint(equalToConstant: 420).isActive = true
    return separator
  }

  @objc private func createSlackAppFromSetupForm() {
    openPrefilledSlackAppCreation()
  }

  @objc private func connectFromSetupForm() {
    guard
      let clientIDField = setupClientIDField,
      let appTokenField = setupAppTokenField
    else {
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
      setupWindow?.makeKeyAndOrderFront(nil)
      return
    }

    closeSetupForm()
    startSlackAuthorization(clientID: clientID, appToken: appToken)
  }

  @objc private func openSlackAppsFromSetupForm() {
    openSlackAppManagement()
  }

  private func closeSetupForm() {
    setupWindow?.close()
    setupWindow = nil
    setupClientIDField = nil
    setupAppTokenField = nil
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
