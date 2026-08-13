import Foundation
import Testing

@testable import SlackSlopbarCore

@Suite("Slack event classification")
struct SlackEventClassifierTests {
  @Test("Messages signal activity")
  func messageActivity() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "text": "hello channel",
        "ts": "1700000000.000001"
      }
      """
    )

    #expect(SlackEventClassifier.signalsActivity(event))
  }

  @Test(
    "Hidden, join/leave, and edit events do not signal activity",
    arguments: [
      """
      {
        "type": "message",
        "subtype": "message_deleted",
        "hidden": true,
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL"
      }
      """,
      """
      {
        "type": "message",
        "subtype": "channel_join",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "ts": "1700000000.000002"
      }
      """,
      """
      {
        "type": "message",
        "subtype": "message_changed",
        "channel": "C123",
        "channel_type": "channel",
        "ts": "1700000000.000003"
      }
      """,
    ])
  func ignoredEvents(json: String) throws {
    let event = try decodeEvent(json)
    #expect(SlackEventClassifier.signalsActivity(event) == false)
  }

  @Test("Direct user mentions are detected")
  func directMention() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "text": "Could you check this, <@UME>?",
        "ts": "1700000000.000004"
      }
      """
    )

    #expect(SlackEventClassifier.isMention(event, authenticatedUserID: "UME"))
  }

  @Test("Legacy-format mentions are detected")
  func legacyMention() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "text": "Could you check this, <@UME|me>?",
        "ts": "1700000000.000005"
      }
      """
    )

    #expect(SlackEventClassifier.isMention(event, authenticatedUserID: "UME"))
  }

  @Test("Block Kit mentions in bot messages are detected")
  func blockMention() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "subtype": "bot_message",
        "channel": "C123",
        "channel_type": "channel",
        "bot_id": "B123",
        "ts": "1700000000.000006",
        "blocks": [
          {
            "type": "rich_text",
            "elements": [
              {
                "type": "rich_text_section",
                "elements": [
                  {"type": "user", "user_id": "UME"},
                  {"type": "text", "text": " build failed"}
                ]
              }
            ]
          }
        ]
      }
      """
    )

    #expect(SlackEventClassifier.isMention(event, authenticatedUserID: "UME"))
  }

  @Test("Attachment mentions are detected")
  func attachmentMention() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "subtype": "bot_message",
        "channel": "C123",
        "channel_type": "channel",
        "bot_id": "B123",
        "ts": "1700000000.000007",
        "attachments": [
          {"fallback": "<@UME> was assigned a ticket"}
        ]
      }
      """
    )

    #expect(SlackEventClassifier.isMention(event, authenticatedUserID: "UME"))
  }

  @Test("Own messages and other users' mentions are not mentions")
  func nonMentions() throws {
    let ownMessage = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UME",
        "text": "<@UME> talking to myself",
        "ts": "1700000000.000008"
      }
      """
    )
    let otherMention = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "text": "hey <@UANNA>",
        "ts": "1700000000.000009"
      }
      """
    )

    #expect(SlackEventClassifier.isMention(ownMessage, authenticatedUserID: "UME") == false)
    #expect(SlackEventClassifier.isMention(otherMention, authenticatedUserID: "UME") == false)
  }

  @Test("Socket Mode event envelopes decode")
  func envelopeDecoding() throws {
    let data = Data(
      """
      {
        "type": "events_api",
        "envelope_id": "env-1",
        "payload": {
          "team_id": "T123",
          "event": {
            "type": "message",
            "channel": "D123",
            "channel_type": "im",
            "user": "UJOEL",
            "text": "hello",
            "ts": "1700000000.000001"
          }
        }
      }
      """.utf8
    )

    let envelope = try JSONDecoder().decode(SlackSocketEnvelope.self, from: data)
    #expect(envelope.type == "events_api")
    #expect(envelope.envelopeID == "env-1")
    #expect(envelope.payload?.teamID == "T123")
  }

  @Test("Timestamp ordering compares numerically, not lexically")
  func timestampOrdering() {
    #expect(
      SlackTimestamp.isOrdered("1700000000.000001", notAfter: "1700000000.000002")
    )
    #expect(
      SlackTimestamp.isOrdered("1700000000.000002", notAfter: "1700000000.000002")
    )
    #expect(
      SlackTimestamp.isOrdered("1700000000.000002", notAfter: "1700000000.000001")
        == false
    )
    // Lexical comparison would order "9..." after "10..." incorrectly.
    #expect(SlackTimestamp.isOrdered("999999999.000000", notAfter: "1700000000.000000"))
    #expect(SlackTimestamp.isOrdered("garbage", notAfter: "1700000000.000000") == false)
  }

  @Test("Unread rotation stays below Slack's steady-state rate")
  func unreadRefreshInterval() {
    #expect(SlackSyncPolicy.rotatingRecheckInterval == 1.5)
  }

  @Test("Unread rotation prioritizes DMs without starving channels")
  func prioritizedUnreadRotation() {
    let channel = unread(id: "C1", kind: .channel)
    let directMessage = unread(id: "D1", kind: .directMessage)
    var rotation = SlackRecheckRotation()

    let sequence = (0..<6).compactMap { _ in
      rotation.next(
        unreads: [channel, directMessage],
        priorityChannelIDs: []
      )
    }

    #expect(sequence == ["D1", "C1", "D1", "D1", "C1", "D1"])
  }

  @Test("Promoting an unread makes it the next check")
  func promotedUnreadRotation() {
    let first = unread(id: "C1", kind: .channel)
    let second = unread(id: "C2", kind: .channel)
    var rotation = SlackRecheckRotation()
    _ = rotation.next(unreads: [first, second], priorityChannelIDs: [])

    rotation.promote("C2")

    #expect(
      rotation.next(unreads: [first, second], priorityChannelIDs: []) == "C2"
    )
  }

  private func unread(
    id: String,
    kind: SlackConversationKind
  ) -> SlackChannelUnread {
    SlackChannelUnread(
      teamID: "T1",
      channelID: id,
      name: id,
      kind: kind,
      unreadCount: 1,
      lastRead: "1700000000.000001"
    )
  }

  private func decodeEvent(_ json: String) throws -> SlackMessageEvent {
    try JSONDecoder().decode(SlackMessageEvent.self, from: Data(json.utf8))
  }
}
