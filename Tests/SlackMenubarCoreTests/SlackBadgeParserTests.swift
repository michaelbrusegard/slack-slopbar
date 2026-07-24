import Testing

@testable import SlackMenubarCore

@Suite("Slack Dock badge parsing")
struct SlackBadgeParserTests {
  @Test("Missing and blank labels mean no unread notifications")
  func emptyLabels() {
    #expect(SlackBadgeParser.parse(statusLabel: nil) == .noUnread)
    #expect(SlackBadgeParser.parse(statusLabel: "") == .noUnread)
    #expect(SlackBadgeParser.parse(statusLabel: " \n ") == .noUnread)
  }

  @Test("Numeric badge labels expose their count")
  func numericLabels() {
    #expect(
      SlackBadgeParser.parse(statusLabel: "3 notifications")
        == .unread(label: "3 notifications", count: 3)
    )
    #expect(
      SlackBadgeParser.parse(statusLabel: "1")
        == .unread(label: "1", count: 1)
    )
  }

  @Test("Dot-style badges still count as unread")
  func dotBadge() {
    #expect(
      SlackBadgeParser.parse(statusLabel: "New notifications")
        == .unread(label: "New notifications", count: nil)
    )
  }
}
