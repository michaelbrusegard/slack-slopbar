import Foundation
import SlackMenubarCore

@MainActor
final class SlackNotificationStore {
  var onChange: (([SlackMenuNotification]) -> Void)?

  private(set) var notifications: [SlackMenuNotification] = [] {
    didSet {
      persist()
      onChange?(notifications)
    }
  }

  private let defaultsKey = "slackMenuNotifications"
  private let maximumStoredNotifications = 100

  init() {
    guard
      let data = UserDefaults.standard.data(forKey: defaultsKey),
      let stored = try? JSONDecoder().decode([SlackMenuNotification].self, from: data)
    else {
      return
    }
    notifications = stored.sorted { $0.receivedAt > $1.receivedAt }
  }

  func add(_ notification: SlackMenuNotification) {
    guard !notifications.contains(where: { $0.id == notification.id }) else {
      return
    }

    notifications.insert(notification, at: 0)
    if notifications.count > maximumStoredNotifications {
      notifications.removeLast(notifications.count - maximumStoredNotifications)
    }
  }

  func remove(id: String) {
    notifications.removeAll { $0.id == id }
  }

  func removeRead(in channelID: String, through lastRead: String) {
    notifications.removeAll { notification in
      SlackReadMarker.includes(
        notification,
        channelID: channelID,
        lastRead: lastRead
      )
    }
  }

  func clear() {
    notifications.removeAll()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(notifications) else {
      return
    }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }
}
