import Foundation

public enum SlackNotificationKind: String, Codable, Equatable, Sendable {
  case directMessage
  case mention
}

public struct SlackMessageEvent: Decodable, Equatable, Sendable {
  public let type: String
  public let subtype: String?
  public let channel: String
  public let channelType: String?
  public let user: String?
  public let botID: String?
  public let text: String
  public let timestamp: String
  public let hidden: Bool?

  enum CodingKeys: String, CodingKey {
    case type
    case subtype
    case channel
    case channelType = "channel_type"
    case user
    case botID = "bot_id"
    case text
    case timestamp = "ts"
    case hidden
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
    channel = try container.decodeIfPresent(String.self, forKey: .channel) ?? ""
    channelType = try container.decodeIfPresent(String.self, forKey: .channelType)
    user = try container.decodeIfPresent(String.self, forKey: .user)
    botID = try container.decodeIfPresent(String.self, forKey: .botID)
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
    hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
  }
}

public struct SlackEventsPayload: Decodable, Equatable, Sendable {
  public let teamID: String
  public let event: SlackMessageEvent

  enum CodingKeys: String, CodingKey {
    case teamID = "team_id"
    case event
  }
}

public struct SlackSocketEnvelope: Decodable, Equatable, Sendable {
  public let type: String
  public let envelopeID: String?
  public let payload: SlackEventsPayload?

  enum CodingKeys: String, CodingKey {
    case type
    case envelopeID = "envelope_id"
    case payload
  }
}

public struct SlackMenuNotification: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let teamID: String
  public let channelID: String
  public let messageTimestamp: String
  public let senderName: String
  public let conversationName: String
  public let kind: SlackNotificationKind
  public let receivedAt: Date

  public init(
    teamID: String,
    channelID: String,
    messageTimestamp: String,
    senderName: String,
    conversationName: String,
    kind: SlackNotificationKind,
    receivedAt: Date
  ) {
    id = "\(teamID):\(channelID):\(messageTimestamp)"
    self.teamID = teamID
    self.channelID = channelID
    self.messageTimestamp = messageTimestamp
    self.senderName = senderName
    self.conversationName = conversationName
    self.kind = kind
    self.receivedAt = receivedAt
  }
}

public enum SlackEventClassifier {
  private static let supportedSubtypes: Set<String> = [
    "bot_message",
    "file_share",
    "me_message",
    "thread_broadcast",
  ]

  public static func classify(
    _ event: SlackMessageEvent,
    authenticatedUserID: String
  ) -> SlackNotificationKind? {
    guard
      event.type == "message",
      event.hidden != true,
      !event.channel.isEmpty,
      !event.timestamp.isEmpty
    else {
      return nil
    }

    if let subtype = event.subtype, !supportedSubtypes.contains(subtype) {
      return nil
    }

    if event.user == authenticatedUserID {
      return nil
    }

    if event.channelType == "im" || event.channel.hasPrefix("D") {
      return .directMessage
    }

    if event.text.contains("<@\(authenticatedUserID)>") {
      return .mention
    }

    return nil
  }
}
