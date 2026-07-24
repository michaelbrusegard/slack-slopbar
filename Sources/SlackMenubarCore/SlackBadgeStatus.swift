import Foundation

public enum SlackBadgeStatus: Equatable, Sendable {
  case noUnread
  case unread(label: String, count: Int?)
  case slackUnavailable
  case accessibilityPermissionRequired

  public var hasUnread: Bool {
    if case .unread = self {
      return true
    }
    return false
  }
}

public enum SlackBadgeParser {
  public static func parse(statusLabel: String?) -> SlackBadgeStatus {
    guard let statusLabel else {
      return .noUnread
    }

    let normalized = statusLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return .noUnread
    }

    let count =
      normalized
      .split(whereSeparator: { !$0.isNumber })
      .compactMap { Int($0) }
      .first

    return .unread(label: normalized, count: count)
  }
}
