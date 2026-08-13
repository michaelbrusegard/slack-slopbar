import Foundation
import SlackSlopbarCore

// Holds the displayed unread state: the API service pushes authoritative
// unread snapshots in, and this store layers on the pieces Slack's API cannot
// provide — live mention marks and local dismissals — plus persistence so the
// menu is populated instantly at launch while the first sweep runs.
@MainActor
final class SlackUnreadStore {
  var onChange: (() -> Void)?

  private(set) var unreads: [SlackChannelUnread] = []
  private(set) var mentionMarks: [String: SlackMentionMark] = [:]
  private(set) var teamID: String?
  private var dismissals: [String: DismissalRecord] = [:]

  // A dismissal hides one exact unread state; any change (new message, read
  // marker moved) makes the conversation reappear.
  private struct DismissalRecord: Codable, Equatable {
    let lastRead: String
    let unreadCount: Int?
  }

  private struct PersistedState: Codable {
    let unreads: [SlackChannelUnread]
    let mentionMarks: [String: SlackMentionMark]
    let dismissals: [String: DismissalRecord]
    let teamID: String?
  }

  private let defaultsKey = "slackUnreadState"
  private let encoder = JSONEncoder()

  init() {
    let data = UserDefaults.standard.data(forKey: defaultsKey)
      ?? migrateLegacyDefaults()
    guard
      let data,
      let state = try? JSONDecoder().decode(PersistedState.self, from: data)
    else {
      return
    }
    unreads = state.unreads
    mentionMarks = state.mentionMarks
    dismissals = state.dismissals
    teamID = state.teamID
  }

  private func migrateLegacyDefaults() -> Data? {
    // Preserve the instant launch snapshot across the product/bundle rename.
    let legacy = UserDefaults(suiteName: "com.michaelbrusegard.SlackMenubar")
    guard let data = legacy?.data(forKey: defaultsKey) else {
      return nil
    }
    UserDefaults.standard.set(data, forKey: defaultsKey)
    legacy?.removeObject(forKey: defaultsKey)
    return data
  }

  var visibleUnreads: [SlackChannelUnread] {
    unreads
      .filter { unread in
        dismissals[unread.channelID]
          != DismissalRecord(
            lastRead: unread.lastRead,
            unreadCount: unread.unreadCount
          )
      }
      .sorted { lhs, rhs in
        let lhsRank = sectionRank(lhs)
        let rhsRank = sectionRank(rhs)
        if lhsRank != rhsRank {
          return lhsRank < rhsRank
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  func mentionMark(for unread: SlackChannelUnread) -> SlackMentionMark? {
    mentionMarks[unread.channelID]
  }

  // Mentions and direct messages make up the badge, matching Slack's own
  // red-badge behavior; plain channel unreads appear in the menu only.
  var badgeCount: Int {
    visibleUnreads.reduce(0) { count, unread in
      if unread.kind.isDirect {
        return count + (unread.unreadCount ?? 1)
      }
      if mentionMarks[unread.channelID] != nil {
        return count + 1
      }
      return count
    }
  }

  func apply(_ snapshot: [SlackChannelUnread]) {
    let channelIDs = Set(snapshot.map(\.channelID))
    var updatedMarks = mentionMarks
    for (channelID, mark) in mentionMarks {
      guard let unread = snapshot.first(where: { $0.channelID == channelID })
      else {
        updatedMarks[channelID] = nil
        continue
      }
      if SlackTimestamp.isOrdered(mark.timestamp, notAfter: unread.lastRead) {
        updatedMarks[channelID] = nil
      }
    }
    let updatedDismissals = dismissals.filter { channelIDs.contains($0.key) }

    guard
      snapshot != unreads
        || updatedMarks != mentionMarks
        || updatedDismissals != dismissals
    else {
      return
    }
    unreads = snapshot
    mentionMarks = updatedMarks
    dismissals = updatedDismissals
    persistAndNotify()
  }

  func markMention(channelID: String, mark: SlackMentionMark) {
    guard mentionMarks[channelID] != mark else {
      return
    }
    mentionMarks[channelID] = mark
    persistAndNotify()
  }

  func dismissAll() {
    var updated = dismissals
    for unread in unreads {
      updated[unread.channelID] = DismissalRecord(
        lastRead: unread.lastRead,
        unreadCount: unread.unreadCount
      )
    }
    guard updated != dismissals else {
      return
    }
    dismissals = updated
    persistAndNotify()
  }

  func handleTeamChange(_ newTeamID: String) {
    guard teamID != newTeamID else {
      return
    }
    let hadState = !unreads.isEmpty || !mentionMarks.isEmpty || !dismissals.isEmpty
    teamID = newTeamID
    unreads = []
    mentionMarks = [:]
    dismissals = [:]
    if hadState {
      persistAndNotify()
    } else {
      persist()
    }
  }

  func wipe() {
    teamID = nil
    unreads = []
    mentionMarks = [:]
    dismissals = [:]
    persistAndNotify()
  }

  private func sectionRank(_ unread: SlackChannelUnread) -> Int {
    if !unread.kind.isDirect, mentionMarks[unread.channelID] != nil {
      return 0
    }
    return unread.kind.isDirect ? 1 : 2
  }

  private func persistAndNotify() {
    persist()
    onChange?()
  }

  private func persist() {
    let state = PersistedState(
      unreads: unreads,
      mentionMarks: mentionMarks,
      dismissals: dismissals,
      teamID: teamID
    )
    guard let data = try? encoder.encode(state) else {
      return
    }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }
}
