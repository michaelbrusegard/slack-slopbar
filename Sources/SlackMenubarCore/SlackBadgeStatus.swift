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

  public var logDescription: String {
    switch self {
    case .noUnread:
      return "no unread notifications"
    case .unread(_, let count):
      return count.map { "unread notifications (count: \($0))" }
        ?? "unread notifications (no count)"
    case .slackUnavailable:
      return "Slack unavailable"
    case .accessibilityPermissionRequired:
      return "Accessibility permission required"
    }
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
