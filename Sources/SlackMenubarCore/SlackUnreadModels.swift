import Foundation

public enum SlackConversationKind: String, Codable, Equatable, Sendable {
  case channel
  case privateChannel
  case directMessage
  case groupDirectMessage

  public var isDirect: Bool {
    self == .directMessage || self == .groupDirectMessage
  }
}

// One conversation with messages the user has not read, mirroring Slack's
// server-side read state rather than locally accumulated events — the server
// state stays correct across app restarts, socket gaps, and reading on
// other devices.
public struct SlackChannelUnread: Codable, Equatable, Identifiable, Sendable {
  public var id: String {
    channelID
  }

  public let teamID: String
  public let channelID: String
  public let name: String
  public let kind: SlackConversationKind
  // nil means Slack did not report a count but newer messages exist.
  public let unreadCount: Int?
  public let lastRead: String

  public init(
    teamID: String,
    channelID: String,
    name: String,
    kind: SlackConversationKind,
    unreadCount: Int?,
    lastRead: String
  ) {
    self.teamID = teamID
    self.channelID = channelID
    self.name = name
    self.kind = kind
    self.unreadCount = unreadCount
    self.lastRead = lastRead
  }
}

// A live mention observed on the event stream. Slack's read-state APIs cannot
// distinguish a mention from a plain unread, so mentions are flagged from
// events and cleared once the conversation's read marker passes them.
public struct SlackMentionMark: Codable, Equatable, Sendable {
  public let timestamp: String
  public let senderName: String

  public init(timestamp: String, senderName: String) {
    self.timestamp = timestamp
    self.senderName = senderName
  }
}

public enum SlackTimestamp {
  // Slack timestamps are decimal strings like "1700000000.000200"; string
  // comparison is wrong once second counts differ in length.
  public static func isOrdered(_ lhs: String, notAfter rhs: String) -> Bool {
    guard
      let lhsValue = Decimal(string: lhs),
      let rhsValue = Decimal(string: rhs)
    else {
      return false
    }
    return lhsValue <= rhsValue
  }
}

public enum SlackSyncPolicy {
  // conversations.info is a Tier 3 Slack method (50+ calls/minute). Polling
  // each unread conversation every 1.5 seconds per item keeps the steady
  // state below that limit, while one pending conversation still refreshes
  // quickly enough to feel immediate.
  public static func unreadRecheckInterval(
    conversationCount: Int
  ) -> TimeInterval {
    guard conversationCount > 0 else {
      return 2
    }
    return max(2, Double(conversationCount) * 1.5)
  }
}
