import Foundation
import Testing

@testable import SlackMenubarCore

@Suite("Slack event classification")
struct SlackEventClassifierTests {
  @Test("Direct messages create notifications")
  func directMessage() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "D123",
        "channel_type": "im",
        "user": "UJOEL",
        "text": "hello",
        "ts": "1700000000.000001"
      }
      """
    )

    #expect(
      SlackEventClassifier.classify(event, authenticatedUserID: "UME")
        == .directMessage
    )
  }

  @Test("Direct user mentions create notifications")
  func directMention() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "text": "Could you check this, <@UME>?",
        "ts": "1700000000.000002"
      }
      """
    )

    #expect(
      SlackEventClassifier.classify(event, authenticatedUserID: "UME")
        == .mention
    )
  }

  @Test("Unrelated channel messages are ignored")
  func unrelatedMessage() throws {
    let event = try decodeEvent(
      """
      {
        "type": "message",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "text": "hello channel",
        "ts": "1700000000.000003"
      }
      """
    )

    #expect(SlackEventClassifier.classify(event, authenticatedUserID: "UME") == nil)
  }

  @Test(
    "Own, edited, and deleted messages are ignored",
    arguments: [
      """
      {
        "type": "message",
        "channel": "D123",
        "channel_type": "im",
        "user": "UME",
        "text": "my message",
        "ts": "1700000000.000004"
      }
      """,
      """
      {
        "type": "message",
        "subtype": "message_changed",
        "channel": "C123",
        "channel_type": "channel",
        "user": "UJOEL",
        "text": "<@UME>",
        "ts": "1700000000.000005"
      }
      """,
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
    ])
  func ignoredMessages(json: String) throws {
    let event = try decodeEvent(json)
    #expect(SlackEventClassifier.classify(event, authenticatedUserID: "UME") == nil)
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

  private func decodeEvent(_ json: String) throws -> SlackMessageEvent {
    try JSONDecoder().decode(SlackMessageEvent.self, from: Data(json.utf8))
  }
}
