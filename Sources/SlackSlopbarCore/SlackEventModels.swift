import Foundation

public struct SlackAttachment: Decodable, Equatable, Sendable {
  public let fallback: String?
  public let pretext: String?
  public let text: String?
  public let title: String?
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
  public let attachments: [SlackAttachment]?
  // User IDs mentioned in Block Kit content, where bot and app messages
  // usually carry their text while the top-level text field stays empty.
  public let blockMentionedUserIDs: Set<String>

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
    case attachments
    case blocks
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
    attachments = try? container.decodeIfPresent(
      [SlackAttachment].self,
      forKey: .attachments
    )
    let blocks = try? container.decodeIfPresent([JSONValue].self, forKey: .blocks)
    var mentions: Set<String> = []
    for block in blocks ?? [] {
      block.collectUserMentions(into: &mentions)
    }
    blockMentionedUserIDs = mentions
  }
}

// A minimal JSON tree used to search Block Kit content for user mention
// elements without modeling Slack's full (and evolving) block schema.
private indirect enum JSONValue: Decodable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func collectUserMentions(into mentions: inout Set<String>) {
    switch self {
    case .object(let members):
      if
        case .string("user")? = members["type"],
        case .string(let userID)? = members["user_id"]
      {
        mentions.insert(userID)
      }
      for value in members.values {
        value.collectUserMentions(into: &mentions)
      }
    case .array(let values):
      for value in values {
        value.collectUserMentions(into: &mentions)
      }
    case .string, .number, .bool, .null:
      break
    }
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

public enum SlackEventClassifier {
  public static let ignoredSubtypes: Set<String> = [
    "channel_join",
    "channel_leave",
    "message_changed",
    "message_deleted",
  ]

  // Any message event worth re-checking the conversation's read state for.
  // The Slack API is the source of truth for what is unread; events only
  // decide when to ask, so this deliberately stays broad.
  public static func signalsActivity(_ event: SlackMessageEvent) -> Bool {
    guard event.type == "message", !event.channel.isEmpty else {
      return false
    }
    if event.hidden == true {
      return false
    }
    if let subtype = event.subtype, ignoredSubtypes.contains(subtype) {
      return false
    }
    return true
  }

  public static func isMention(
    _ event: SlackMessageEvent,
    authenticatedUserID: String
  ) -> Bool {
    guard
      signalsActivity(event),
      !event.timestamp.isEmpty,
      event.user != authenticatedUserID
    else {
      return false
    }
    return mentionsAuthenticatedUser(event, authenticatedUserID)
  }

  private static func mentionsAuthenticatedUser(
    _ event: SlackMessageEvent,
    _ authenticatedUserID: String
  ) -> Bool {
    if event.blockMentionedUserIDs.contains(authenticatedUserID) {
      return true
    }
    var texts = [event.text]
    for attachment in event.attachments ?? [] {
      texts.append(contentsOf: [
        attachment.fallback,
        attachment.pretext,
        attachment.text,
        attachment.title,
      ].compactMap { $0 })
    }
    return texts.contains {
      $0.contains("<@\(authenticatedUserID)>")
        || $0.contains("<@\(authenticatedUserID)|")
    }
  }
}
