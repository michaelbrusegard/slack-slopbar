import AppKit
import ServiceManagement
import SlackMenubarCore

@main
@MainActor
final class SlackMenubarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let badgeReader = SlackDockBadgeReader()
  private var statusItem: NSStatusItem!
  private var pollTimer: Timer?
  private var currentStatus: SlackBadgeStatus = .slackUnavailable
  private var lastCheckedAt: Date?
  private var launchAtLoginError: String?

  static func main() {
    let application = NSApplication.shared
    let delegate = SlackMenubarApp()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.toolTip = "Slack notification status"

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    observeSlackLifecycle()
    refresh()

    if !badgeReader.hasAccessibilityPermission {
      badgeReader.requestAccessibilityPermission()
    }

    pollTimer = Timer.scheduledTimer(
      timeInterval: 3,
      target: self,
      selector: #selector(refreshFromTimer),
      userInfo: nil,
      repeats: true
    )
    if let pollTimer {
      RunLoop.main.add(pollTimer, forMode: .common)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    pollTimer?.invalidate()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  func menuWillOpen(_ menu: NSMenu) {
    refresh()
    rebuildMenu(menu)
  }

  @objc private func refreshFromTimer() {
    refresh()
  }

  private func refresh() {
    currentStatus = badgeReader.read()
    lastCheckedAt = Date()
    updateStatusItem()

    if let menu = statusItem.menu, menu.numberOfItems > 0 {
      rebuildMenu(menu)
    }
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else {
      return
    }

    let symbolName: String
    let accessibilityDescription: String

    switch currentStatus {
    case .unread(_, let count):
      symbolName = "bell.badge.fill"
      accessibilityDescription =
        count.map {
          "Slack has \($0) unread notifications"
        } ?? "Slack has an unread notification"
      button.title = count.map { " \($0)" } ?? ""
    case .noUnread:
      symbolName = "bell"
      accessibilityDescription = "Slack has no unread notifications"
      button.title = ""
    case .slackUnavailable:
      symbolName = "bell.slash"
      accessibilityDescription = "Slack is unavailable"
      button.title = ""
    case .accessibilityPermissionRequired:
      symbolName = "exclamationmark.triangle"
      accessibilityDescription = "Slack Menubar needs Accessibility permission"
      button.title = ""
    }

    button.image = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: accessibilityDescription
    )
    button.image?.isTemplate = true
    button.toolTip = accessibilityDescription
  }

  private func rebuildMenu(_ menu: NSMenu) {
    menu.removeAllItems()

    let status = NSMenuItem(title: statusDescription, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)

    if let lastCheckedAt {
      let checked = NSMenuItem(
        title: "Checked \(lastCheckedAt.formatted(date: .omitted, time: .standard))",
        action: nil,
        keyEquivalent: ""
      )
      checked.isEnabled = false
      menu.addItem(checked)
    }

    if let launchAtLoginError {
      let error = NSMenuItem(title: launchAtLoginError, action: nil, keyEquivalent: "")
      error.isEnabled = false
      menu.addItem(error)
    }

    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Open Slack",
      action: #selector(openSlack),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Check Now",
      action: #selector(checkNow),
      keyEquivalent: "r"
    ).target = self

    if currentStatus == .accessibilityPermissionRequired {
      menu.addItem(
        withTitle: "Grant Accessibility Permission…",
        action: #selector(requestAccessibilityPermission),
        keyEquivalent: ""
      ).target = self
      menu.addItem(
        withTitle: "Open Accessibility Settings…",
        action: #selector(openAccessibilitySettings),
        keyEquivalent: ""
      ).target = self
    }

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

  private var statusDescription: String {
    switch currentStatus {
    case .unread(let label, let count):
      if let count {
        return count == 1
          ? "Slack: 1 unread notification"
          : "Slack: \(count) unread notifications"
      }
      return "Slack: unread (\(label))"
    case .noUnread:
      return "Slack: no unread notifications"
    case .slackUnavailable:
      return "Slack: not running or absent from the Dock"
    case .accessibilityPermissionRequired:
      return "Accessibility permission required"
    }
  }

  private func observeSlackLifecycle() {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
      self,
      selector: #selector(workspaceApplicationChanged),
      name: NSWorkspace.didLaunchApplicationNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(workspaceApplicationChanged),
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil
    )
  }

  @objc private func workspaceApplicationChanged(_ notification: Notification) {
    refresh()
  }

  @objc private func openSlack() {
    guard let url = URL(string: "slack://open") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc private func checkNow() {
    refresh()
  }

  @objc private func requestAccessibilityPermission() {
    badgeReader.requestAccessibilityPermission()
    refresh()
  }

  @objc private func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc private func toggleLaunchAtLogin() {
    launchAtLoginError = nil
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      launchAtLoginError = "Launch at Login: \(error.localizedDescription)"
    }

    if let menu = statusItem.menu {
      rebuildMenu(menu)
    }
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}
