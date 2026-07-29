import AppKit
import OSLog
import ServiceManagement
import SlackMenubarCore

@main
@MainActor
final class SlackMenubarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let apiService = SlackAPIService()
  private let unreadStore = SlackUnreadStore()
  private let logger = Logger(
    subsystem: "com.michaelbrusegard.SlackMenubar",
    category: "SlackAPI"
  )

  private var statusItem: NSStatusItem!
  private var setupError: String?
  private var pendingOAuthRequest: SlackOAuthRequest?
  private var setupWindow: NSWindow?
  private var setupClientIDField: NSTextField?
  private var setupAppTokenField: NSSecureTextField?
  private var setupWorkspacePopup: NSPopUpButton?
  private var isMenuOpen = false

  // NSApplication.delegate is unretained; without a strong reference the
  // delegate could be deallocated once main()'s local goes out of scope.
  private static var sharedDelegate: SlackMenubarApp?

  static func main() {
    let application = NSApplication.shared
    let delegate = SlackMenubarApp()
    sharedDelegate = delegate
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
      logger.notice("Connection state: \(state.menuDescription, privacy: .public)")
      refreshUI()
    }
    apiService.onSyncStatusChange = { [weak self] _ in
      self?.refreshUI()
    }
    apiService.onUnreadsChanged = { [weak self] unreads in
      self?.unreadStore.apply(unreads)
    }
    apiService.onMention = { [weak self] channelID, mark in
      self?.unreadStore.markMention(channelID: channelID, mark: mark)
    }
    apiService.onTeamChange = { [weak self] teamID in
      // After re-authorizing to a different workspace, old-team unread state
      // is meaningless under the new token.
      self?.unreadStore.handleTeamChange(teamID)
    }
    unreadStore.onChange = { [weak self] in
      self?.refreshUI()
    }

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(systemDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    refreshUI()
    loadCredentialsAndConnect()
  }

  @objc private func systemDidWake() {
    // The socket is usually half-dead after sleep; reconnect immediately
    // instead of waiting for the keepalive to notice, and re-sweep to pick
    // up whatever happened while asleep.
    apiService.refreshConnection()
    apiService.requestSweep(force: true)
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
    isMenuOpen = true
    rebuildMenu(menu)
    apiService.requestRecheck()
  }

  func menuDidClose(_ menu: NSMenu) {
    isMenuOpen = false
  }

  private func configureApplicationMenu() {
    let mainMenu = NSMenu()

    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(makeQuitMenuItem())
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
    // Keychain IPC can stall (locked keychain, slow securityd right after
    // login); loading off the main actor keeps launch responsive.
    Task { [weak self] in
      do {
        let credentials = try await Task.detached {
          try SlackCredentialStore.load()
        }.value
        guard let self else {
          return
        }
        if let credentials {
          apiService.connect(using: credentials)
        } else {
          configureSlack()
        }
      } catch {
        guard let self else {
          return
        }
        setupError = "Keychain: \(error.localizedDescription)"
        refreshUI()
      }
    }
  }

  private func refreshUI() {
    updateStatusItem()
    // menuWillOpen rebuilds anyway, so rebuilding a closed menu is wasted
    // work; only an open menu needs live updates.
    if isMenuOpen, let menu = statusItem.menu {
      rebuildMenu(menu)
    }
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else {
      return
    }

    let unreadCount = unreadStore.visibleUnreads.count
    let badge = unreadStore.badgeCount
    button.image = SlackStatusIcon.slackMark(filled: unreadCount > 0)
    // The number tracks Slack's red badge (DMs and mentions); plain channel
    // unreads fill the icon but do not count.
    button.title = badge > 0 ? " \(badge)" : ""

    let description =
      unreadCount > 0
      ? "Slack has \(unreadCount) unread \(unreadCount == 1 ? "conversation" : "conversations")"
      : "Slack has no unread conversations"
    button.setAccessibilityLabel(description)
    button.toolTip = description
  }

  private func rebuildMenu(_ menu: NSMenu) {
    menu.removeAllItems()

    let connection = NSMenuItem(
      title: connectionMenuDescription,
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

    let visible = unreadStore.visibleUnreads
    if visible.isEmpty {
      let empty = NSMenuItem(
        title: "No unread conversations",
        action: nil,
        keyEquivalent: ""
      )
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      let mentions = visible.filter {
        !$0.kind.isDirect && unreadStore.mentionMark(for: $0) != nil
      }
      let directMessages = visible.filter(\.kind.isDirect)
      let channels = visible.filter {
        !$0.kind.isDirect && unreadStore.mentionMark(for: $0) == nil
      }

      let maximumItems = 20
      var shownCount = 0
      func addSection(_ title: String, _ unreads: [SlackChannelUnread]) {
        guard !unreads.isEmpty, shownCount < maximumItems else {
          return
        }
        menu.addItem(.separator())
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for unread in unreads.prefix(maximumItems - shownCount) {
          let item = NSMenuItem(
            title: unreadTitle(unread),
            action: #selector(openConversation(_:)),
            keyEquivalent: ""
          )
          item.target = self
          item.representedObject = unread.channelID
          menu.addItem(item)
          shownCount += 1
        }
      }

      addSection("Mentions", mentions)
      addSection("Direct Messages", directMessages)
      addSection("Channels", channels)

      if visible.count > shownCount {
        let more = NSMenuItem(
          title: "…and \(visible.count - shownCount) more",
          action: nil,
          keyEquivalent: ""
        )
        more.isEnabled = false
        menu.addItem(more)
      }

      menu.addItem(
        withTitle: "Dismiss All",
        action: #selector(dismissAll),
        keyEquivalent: ""
      ).target = self
    }

    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Open Slack",
      action: #selector(openSlack),
      keyEquivalent: ""
    ).target = self
    var showReconnect = setupError != nil
    if case .disconnected = apiService.state {
      showReconnect = true
    }
    if case .reconnecting = apiService.state {
      showReconnect = true
    }
    if showReconnect {
      menu.addItem(
        withTitle: "Reconnect",
        action: #selector(reconnect),
        keyEquivalent: ""
      ).target = self
    }

    menu.addItem(
      withTitle: "Slack Setup Assistant…",
      action: #selector(configureSlack),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Sign Out of Slack…",
      action: #selector(signOut),
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
    menu.addItem(makeQuitMenuItem())
  }

  private var connectionMenuDescription: String {
    let base = apiService.state.menuDescription
    guard case .connected = apiService.state else {
      return base
    }

    let sync = apiService.syncStatus
    if sync.isChecking {
      return "\(base) · checking unread state…"
    }
    if sync.failedConversationCount > 0 {
      if let lastCheck = sync.lastSuccessfulCheck {
        return "\(base) · read sync retrying (last success \(relativeAge(of: lastCheck)))"
      }
      return "\(base) · read sync retrying"
    }
    if let lastCheck = sync.lastSuccessfulCheck {
      return "\(base) · read state synced \(relativeAge(of: lastCheck))"
    }
    return "\(base) · unread sync pending"
  }

  private func relativeAge(of date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 3 {
      return "now"
    }
    if seconds < 60 {
      return "\(seconds)s ago"
    }
    return "\(seconds / 60)m ago"
  }

  private func makeQuitMenuItem() -> NSMenuItem {
    let item = NSMenuItem(
      title: "Quit Slack Menubar",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    item.target = self
    return item
  }

  private func unreadTitle(_ unread: SlackChannelUnread) -> String {
    if !unread.kind.isDirect, let mark = unreadStore.mentionMark(for: unread) {
      return "\(unread.name) — \(mark.senderName) mentioned you"
    }
    if let count = unread.unreadCount {
      return "\(unread.name) — \(count) unread"
    }
    return "\(unread.name) — unread"
  }

  @objc private func configureSlack() {
    if let setupWindow {
      NSApplication.shared.activate(ignoringOtherApps: true)
      setupWindow.makeKeyAndOrderFront(nil)
      return
    }

    let existingCredentials = try? SlackCredentialStore.load()
    let workspaceSelection = SlackWorkspaceDiscovery.load()

    let clientIDField = NSTextField(string: existingCredentials?.clientID ?? "")
    clientIDField.placeholderString = "For example, 123456789.987654321"
    clientIDField.controlSize = .regular
    clientIDField.translatesAutoresizingMaskIntoConstraints = false

    let appTokenField = NSSecureTextField(string: existingCredentials?.appToken ?? "")
    appTokenField.placeholderString = "xapp-…"
    appTokenField.controlSize = .regular
    appTokenField.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: "Connect Slack Menubar")
    title.font = .systemFont(ofSize: 24, weight: .semibold)

    let introduction = setupDescription(
      "This private Slack app sends your DMs and mentions directly to the menu bar. Complete the three steps below once."
    )

    let createTitle = setupSectionTitle("1. Create or open the Slack app")
    let createDescription = setupDescription(
      """
      Copy the manifest, then open Slack. Choose From a manifest, select YAML, paste, select your workspace underneath, then choose Next and Create.
      """
    )
    let copyButton = NSButton(
      title: "Copy Manifest",
      target: self,
      action: #selector(copyManifestFromSetupForm(_:))
    )
    copyButton.bezelStyle = .rounded
    let createButton = NSButton(
      title: "Create Slack App",
      target: self,
      action: #selector(createSlackAppFromSetupForm)
    )
    createButton.bezelStyle = .rounded
    let createButtons = NSStackView(views: [copyButton, createButton])
    createButtons.orientation = .horizontal
    createButtons.spacing = 8
    let openButton = NSButton(
      title: "Open Existing Slack App",
      target: self,
      action: #selector(openSlackAppsFromSetupForm)
    )
    openButton.bezelStyle = .rounded

    let detailsTitle = setupSectionTitle("2. Choose the workspace and enter app details")
    let detailsDescription = setupDescription(
      """
      Select the same workspace used during app creation. Then, on Basic Information, copy Client ID from App Credentials. Under App-Level Tokens, generate a token named Slack Menubar with the connections:write scope.
      """
    )
    let workspaceLabel = setupFieldLabel("Target workspace")
    let workspacePopup = NSPopUpButton()
    workspacePopup.translatesAutoresizingMaskIntoConstraints = false
    for workspace in workspaceSelection.workspaces {
      workspacePopup.addItem(withTitle: workspace.name)
      workspacePopup.lastItem?.representedObject = workspace.id
    }
    if
      let selectedID = workspaceSelection.selectedWorkspaceID,
      let index = workspacePopup.itemArray.firstIndex(where: {
        $0.representedObject as? String == selectedID
      })
    {
      workspacePopup.selectItem(at: index)
    }
    if workspacePopup.numberOfItems == 0 {
      workspacePopup.addItem(withTitle: "Choose on Slack's authorization page")
      workspacePopup.lastItem?.representedObject = nil
    }
    let clientIDLabel = setupFieldLabel("Client ID")
    let appTokenLabel = setupFieldLabel("App-level token (xapp)")

    let authorizeTitle = setupSectionTitle("3. Authorize your Slack account")
    let authorizeDescription = setupDescription(
      """
      The selected workspace is pinned in the authorization request. Confirm that Slack shows the same workspace before choosing Allow. Slack then returns here automatically.
      """
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
      createButtons,
      openButton,
      setupSeparator(),
      detailsTitle,
      detailsDescription,
      workspaceLabel,
      workspacePopup,
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

    // One width contract: the stack defines the form width and every
    // full-width control follows it, instead of each view carrying its own
    // hard-coded width.
    let fullWidthViews: [NSView] =
      [
        introduction,
        createDescription,
        detailsDescription,
        authorizeDescription,
        workspacePopup,
        clientIDField,
        appTokenField,
      ] + stack.arrangedSubviews.filter { $0 is NSBox }
    NSLayoutConstraint.activate(
      [stack.widthAnchor.constraint(equalToConstant: Self.setupFormWidth)]
        + fullWidthViews.map {
          $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        }
    )

    let contentView = NSView()
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor,
        constant: -28
      ),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
      stack.bottomAnchor.constraint(
        equalTo: contentView.bottomAnchor,
        constant: -26
      ),
    ])

    let window = NSWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Slack Menubar Setup"
    window.contentView = contentView
    // Sizing from the layout means added steps or longer text can never be
    // clipped by a hard-coded window height.
    window.setContentSize(contentView.fittingSize)
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.center()

    setupWindow = window
    setupClientIDField = clientIDField
    setupAppTokenField = appTokenField
    setupWorkspacePopup = workspacePopup

    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(clientIDField)
  }

  private func setupSectionTitle(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 15, weight: .semibold)
    return field
  }

  private static let setupFormWidth: CGFloat = 420

  private func setupDescription(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.textColor = .secondaryLabelColor
    field.preferredMaxLayoutWidth = Self.setupFormWidth
    field.translatesAutoresizingMaskIntoConstraints = false
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
    return separator
  }

  @objc private func createSlackAppFromSetupForm() {
    openSlackAppCreation()
  }

  @objc private func copyManifestFromSetupForm(_ sender: NSButton) {
    copySlackAppManifest()
    sender.title = "Manifest Copied"
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
    let teamID = setupWorkspacePopup?.selectedItem?.representedObject as? String
    guard !clientID.isEmpty, appToken.hasPrefix("xapp-") else {
      showError(
        title: "Check the app details",
        message: "Enter the Client ID and an app token beginning with xapp-."
      )
      setupWindow?.makeKeyAndOrderFront(nil)
      return
    }

    closeSetupForm()
    startSlackAuthorization(
      clientID: clientID,
      appToken: appToken,
      teamID: teamID
    )
  }

  @objc private func openSlackAppsFromSetupForm() {
    openSlackAppManagement()
  }

  private func closeSetupForm() {
    setupWindow?.close()
    setupWindow = nil
    setupClientIDField = nil
    setupAppTokenField = nil
    setupWorkspacePopup = nil
  }

  private func startSlackAuthorization(
    clientID: String,
    appToken: String,
    teamID: String?
  ) {
    let oauthRequest = SlackOAuthRequest(
      clientID: clientID,
      appToken: appToken,
      teamID: teamID
    )
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
    let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
      .queryItems
    var values: [String: String] = [:]
    for item in queryItems ?? [] {
      values[item.name] = item.value
    }

    guard
      let oauthRequest = pendingOAuthRequest,
      values["state"] == oauthRequest.state
    else {
      // A callback from an abandoned earlier attempt must not invalidate an
      // in-flight request, so only surface errors here — never clear it.
      if let slackError = values["error"] {
        showError(
          title: "Slack authorization was not completed",
          message: slackError
        )
      } else if pendingOAuthRequest == nil {
        showError(
          title: "Authorization expired",
          message: "Open Slack Setup Assistant and try connecting again."
        )
      }
      return
    }
    pendingOAuthRequest = nil

    if let slackError = values["error"] {
      showError(
        title: "Slack authorization was not completed",
        message: slackError
      )
      return
    }
    guard let code = values["code"] else {
      showError(
        title: "Slack did not return an authorization code",
        message: "Open Slack Setup Assistant and try again."
      )
      return
    }

    Task {
      do {
        let credentials = try await SlackOAuthClient.exchange(
          code: code,
          request: oauthRequest
        )
        guard credentials.isPlausible else {
          throw SlackSetupError.invalidToken
        }
        try await Task.detached {
          try SlackCredentialStore.save(credentials)
        }.value
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

  @objc private func signOut() {
    let alert = NSAlert()
    alert.messageText = "Sign out of Slack?"
    alert.informativeText =
      "Slack Menubar will disconnect, remove its Slack tokens from the Keychain, and clear pending notifications."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Sign Out")
    alert.addButton(withTitle: "Cancel")

    NSApplication.shared.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      try SlackCredentialStore.remove()
      apiService.reset()
      unreadStore.wipe()
      setupError = nil
    } catch {
      setupError = "Keychain: \(error.localizedDescription)"
    }
    refreshUI()
  }

  @objc private func openConversation(_ sender: NSMenuItem) {
    guard
      let channelID = sender.representedObject as? String,
      let unread = unreadStore.visibleUnreads.first(where: {
        $0.channelID == channelID
      })
    else {
      return
    }

    var components = URLComponents()
    components.scheme = "slack"
    components.host = "channel"
    var queryItems = [URLQueryItem(name: "id", value: unread.channelID)]
    if !unread.teamID.isEmpty {
      queryItems.insert(URLQueryItem(name: "team", value: unread.teamID), at: 0)
    }
    components.queryItems = queryItems
    if let url = components.url {
      NSWorkspace.shared.open(url)
    }

    // Reading the conversation in Slack advances its read marker; a quick
    // re-check clears the menu item without waiting for the 30-second loop.
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      self?.apiService.requestRecheck()
    }
  }

  @objc private func dismissAll() {
    unreadStore.dismissAll()
  }

  @objc private func reconnect() {
    setupError = nil
    apiService.refreshConnection()
    if apiService.state == .unconfigured {
      // No credentials in memory (for example after a launch-time Keychain
      // failure) — retry the full load instead of forcing a new setup run.
      loadCredentialsAndConnect()
    }
    refreshUI()
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
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(SlackAppManifest.yaml, forType: .string)
  }

  private func openSlackAppCreation() {
    guard let url = URL(string: "https://api.slack.com/apps?new_app=1") else {
      showError(
        title: "Could not open Slack app creation",
        message: "Open https://api.slack.com/apps in a browser."
      )
      return
    }
    NSWorkspace.shared.open(url)
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
