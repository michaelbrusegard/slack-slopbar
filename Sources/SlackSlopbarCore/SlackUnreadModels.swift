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
  // conversations.info is a Tier 3 Slack method (50+ calls/minute). One
  // rotating check every 1.5 seconds uses 40 calls/minute, leaving headroom
  // for event-triggered and foreground checks.
  public static let rotatingRecheckInterval: TimeInterval = 1.5
}

// A weighted, fair rotation for unread polling. Priority conversations occur
// twice per cycle, but every ordinary conversation still receives a turn.
public struct SlackRecheckRotation: Sendable {
  private var queue: [String] = []

  public init() {}

  public mutating func reset() {
    queue = []
  }

  public mutating func promote(_ channelID: String) {
    queue.removeAll { $0 == channelID }
    queue.insert(channelID, at: 0)
  }

  public mutating func next(
    unreads: [SlackChannelUnread],
    priorityChannelIDs: Set<String>
  ) -> String? {
    let liveIDs = Set(unreads.map(\.channelID))
    queue.removeAll { !liveIDs.contains($0) }

    if queue.isEmpty {
      let all = unreads.sorted(by: stableOrder).map(\.channelID)
      let priority = unreads
        .filter {
          $0.kind.isDirect || priorityChannelIDs.contains($0.channelID)
        }
        .sorted(by: stableOrder)
        .map(\.channelID)
      queue = priority + all
    }

    guard !queue.isEmpty else {
      return nil
    }
    return queue.removeFirst()
  }

  private func stableOrder(
    _ lhs: SlackChannelUnread,
    _ rhs: SlackChannelUnread
  ) -> Bool {
    lhs.channelID < rhs.channelID
  }
}
