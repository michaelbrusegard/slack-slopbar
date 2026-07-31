import Foundation
import OSLog
import SlackMenubarCore

enum SlackConnectionState: Equatable {
  case unconfigured
  case connecting
  case connected(workspace: String)
  case reconnecting(message: String)
  case disconnected

  var menuDescription: String {
    switch self {
    case .unconfigured:
      return "Slack API: setup required"
    case .connecting:
      return "Slack API: connecting…"
    case .connected(let workspace):
      return "Slack API: connected to \(workspace)"
    case .reconnecting(let message):
      return "Slack API: reconnecting (\(message))"
    case .disconnected:
      return "Slack API: disconnected"
    }
  }
}

struct SlackUnreadSyncStatus: Equatable {
  var isChecking = false
  var lastSuccessfulCheck: Date?
  var failedConversationCount = 0
}

// Connects to Slack and keeps an authoritative unread snapshot.
//
// Slack's per-conversation read state (last_read / unread counts) is the
// source of truth for "what haven't I seen" — it survives app restarts,
// socket gaps, and reading on other devices. Socket Mode events are only
// triggers to re-check specific conversations quickly:
//
// - Full sweep of every member conversation at connect/reconnect and on
//   demand (system wake), catching anything missed while offline.
// - A message event re-checks just that conversation within ~1 second.
// - One unread conversation is re-checked every 1.5 seconds. DMs, mentions,
//   and conversations just opened in Slack get extra turns in a fair queue.
@MainActor
final class SlackAPIService {
  var onStateChange: ((SlackConnectionState) -> Void)?
  var onSyncStatusChange: ((SlackUnreadSyncStatus) -> Void)?
  var onTeamChange: ((String) -> Void)?
  var onUnreadsChanged: (([SlackChannelUnread]) -> Void)?
  var onMention: ((String, SlackMentionMark) -> Void)?

  private let logger = Logger(
    subsystem: "com.michaelbrusegard.SlackMenubar",
    category: "SlackAPI"
  )

  private(set) var state: SlackConnectionState = .unconfigured {
    didSet {
      guard oldValue != state else {
        return
      }
      onStateChange?(state)
    }
  }
  private(set) var syncStatus = SlackUnreadSyncStatus() {
    didSet {
      guard oldValue != syncStatus else {
        return
      }
      onSyncStatusChange?(syncStatus)
    }
  }

  private var credentials: SlackCredentials?
  private var identity: SlackIdentity?
  private var connectionTask: Task<Void, Never>?
  private var refreshTask: Task<SlackCredentials, any Error>?
  private var socket: URLSessionWebSocketTask?
  private var userNameCache: [String: String] = [:]
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  private var unreads: [String: SlackChannelUnread] = [:]
  private var sweepTask: Task<Void, Never>?
  private var recheckLoopTask: Task<Void, Never>?
  private var lastSweepAt: Date?
  private var pendingChecks: Set<String> = []
  private var pendingCheckTask: Task<Void, Never>?
  private var activeSyncCount = 0
  private var recheckRotation = SlackRecheckRotation()
  private var mentionPriorities: [String: SlackMentionMark] = [:]
  private var recentlyOpenedUntil: [String: Date] = [:]
  private var lastRotatingCheckAt: [String: Date] = [:]

  func connect(using credentials: SlackCredentials) {
    disconnect(setState: false)
    self.credentials = credentials
    identity = nil
    state = .connecting

    connectionTask = Task { [weak self] in
      await self?.runConnectionLoop()
    }
    startRecheckLoop()
  }

  func disconnect() {
    disconnect(setState: true)
  }

  func reset() {
    disconnect(setState: false)
    credentials = nil
    identity = nil
    unreads = [:]
    mentionPriorities = [:]
    recentlyOpenedUntil = [:]
    lastRotatingCheckAt = [:]
    recheckRotation.reset()
    lastSweepAt = nil
    state = .unconfigured
  }

  func refreshConnection() {
    guard let credentials else {
      return
    }
    if let socket {
      // Forces the blocked receive() to throw so the connection loop retries
      // now (typical after system sleep) instead of waiting for the next
      // keepalive to fail.
      socket.cancel(with: .abnormalClosure, reason: nil)
    } else {
      // No live socket means the loop is mid-backoff or was never started;
      // reconnecting from scratch also resets the backoff delay.
      connect(using: credentials)
    }
  }

  // Full unread sweep across every conversation the user is a member of.
  // Throttled because reconnect loops can fire it repeatedly; force is for
  // deliberate triggers like system wake.
  func requestSweep(force: Bool = false) {
    if !force, let lastSweepAt, Date().timeIntervalSince(lastSweepAt) < 120 {
      return
    }
    guard sweepTask == nil else {
      return
    }
    sweepTask = Task { [weak self] in
      await self?.performSweep()
      self?.sweepTask = nil
    }
  }

  // Puts the most useful conversation at the front and checks it now. The
  // rotating loop handles the rest without creating an API burst.
  func requestRecheck() {
    recheckRotation.reset()
    Task { [weak self] in
      await self?.recheckNextUnread()
    }
  }

  // Re-checks one conversation shortly and gives it priority for several
  // subsequent turns while Slack advances its read marker.
  func noteActivity(in channelID: String) {
    recentlyOpenedUntil[channelID] = Date().addingTimeInterval(8)
    recheckRotation.promote(channelID)
    scheduleCheck(of: channelID)
  }

  private func disconnect(setState: Bool) {
    connectionTask?.cancel()
    connectionTask = nil
    refreshTask?.cancel()
    refreshTask = nil
    sweepTask?.cancel()
    sweepTask = nil
    recheckLoopTask?.cancel()
    recheckLoopTask = nil
    pendingCheckTask?.cancel()
    pendingCheckTask = nil
    pendingChecks = []
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    if setState {
      state = credentials == nil ? .unconfigured : .disconnected
    }
  }

  private func runConnectionLoop() async {
    var retryDelay: UInt64 = 1

    while !Task.isCancelled {
      do {
        let credentials = try await currentCredentials()

        let identity: SlackIdentity
        if let existingIdentity = self.identity {
          identity = existingIdentity
        } else {
          identity = try await fetchIdentity(userToken: credentials.userToken)
        }
        self.identity = identity
        if let teamID = identity.teamID {
          onTeamChange?(teamID)
        }

        let socketURL = try await openSocketURL(appToken: credentials.appToken)
        let socket = URLSession.shared.webSocketTask(with: socketURL)
        self.socket = socket
        socket.resume()
        state = .connected(workspace: identity.workspaceName)
        retryDelay = 1

        // Anything that happened while disconnected is invisible to the
        // event stream; the sweep restores truth.
        requestSweep()

        try await receiveMessages(from: socket, identity: identity)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else {
          return
        }

        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .reconnecting(message: error.localizedDescription)

        try? await Task.sleep(for: .seconds(retryDelay))
        retryDelay = min(retryDelay * 2, 30)
      }
    }
  }

  private func receiveMessages(
    from socket: URLSessionWebSocketTask,
    identity: SlackIdentity
  ) async throws {
    let pingTask = Task {
      while !Task.isCancelled {
        try await Task.sleep(for: .seconds(20))
        do {
          try await sendPing(on: socket)
        } catch {
          // A failed keepalive means the socket may be half-dead while
          // receive() blocks forever; cancel it so receive() throws and the
          // connection loop reconnects.
          socket.cancel(with: .abnormalClosure, reason: nil)
          return
        }
      }
    }
    defer {
      pingTask.cancel()
    }

    while !Task.isCancelled {
      let message = try await socket.receive()
      let data: Data
      switch message {
      case .data(let messageData):
        data = messageData
      case .string(let string):
        data = Data(string.utf8)
      @unknown default:
        continue
      }

      let envelope = try decoder.decode(SlackSocketEnvelope.self, from: data)
      if let envelopeID = envelope.envelopeID {
        try await acknowledge(envelopeID, on: socket)
      }

      if envelope.type == "disconnect" {
        throw SlackAPIError.socketRefreshRequested
      }

      guard envelope.type == "events_api", let payload = envelope.payload else {
        continue
      }

      Task { [weak self] in
        await self?.process(payload: payload, identity: identity)
      }
    }
  }

  private func process(payload: SlackEventsPayload, identity: SlackIdentity) async {
    let event = payload.event
    guard SlackEventClassifier.signalsActivity(event) else {
      return
    }

    if SlackEventClassifier.isMention(event, authenticatedUserID: identity.userID) {
      let senderName: String
      if
        let userID = event.user,
        let token = try? await currentCredentials().userToken
      {
        senderName = (try? await resolveUserName(userID, token: token)) ?? userID
      } else {
        senderName = event.user ?? "Someone"
      }
      let mark = SlackMentionMark(
        timestamp: event.timestamp,
        senderName: senderName
      )
      mentionPriorities[event.channel] = mark
      recheckRotation.promote(event.channel)
      onMention?(event.channel, mark)
    }

    scheduleCheck(of: event.channel)
  }

  private func scheduleCheck(of channelID: String) {
    pendingChecks.insert(channelID)
    guard pendingCheckTask == nil else {
      return
    }
    pendingCheckTask = Task { [weak self] in
      // A short debounce coalesces message bursts into one check per channel.
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else {
        return
      }
      pendingCheckTask = nil
      let channelIDs = Array(pendingChecks)
      pendingChecks = []
      guard let context = await syncContext() else {
        return
      }
      await checkConversations(channelIDs, context: context)
    }
  }

  private func recheckNextUnread() async {
    guard
      let channelID = nextUnreadChannelID(),
      let context = await syncContext()
    else {
      return
    }
    lastRotatingCheckAt[channelID] = Date()
    await checkConversations([channelID], context: context)
  }

  private func nextUnreadChannelID() -> String? {
    let now = Date()
    let liveIDs = Set(unreads.keys)
    mentionPriorities = mentionPriorities.filter { liveIDs.contains($0.key) }
    recentlyOpenedUntil = recentlyOpenedUntil.filter {
      liveIDs.contains($0.key) && $0.value > now
    }
    lastRotatingCheckAt = lastRotatingCheckAt.filter {
      liveIDs.contains($0.key)
    }

    // Recently opened conversations are checked repeatedly for a short
    // window. If several were opened, the least recently checked goes first.
    if let recentlyOpened = recentlyOpenedUntil.keys.min(by: { lhs, rhs in
      let lhsDate = lastRotatingCheckAt[lhs] ?? .distantPast
      let rhsDate = lastRotatingCheckAt[rhs] ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate < rhsDate
      }
      return lhs < rhs
    }) {
      return recentlyOpened
    }

    return recheckRotation.next(
      unreads: Array(unreads.values),
      priorityChannelIDs: Set(mentionPriorities.keys)
    )
  }

  private func startRecheckLoop() {
    recheckLoopTask?.cancel()
    recheckLoopTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(
            for: .seconds(SlackSyncPolicy.rotatingRecheckInterval)
          )
        } catch {
          return
        }
        await self?.recheckNextUnread()
      }
    }
  }

  private func performSweep() async {
    guard let context = await syncContext() else {
      return
    }
    lastSweepAt = Date()
    do {
      let channelIDs = try await fetchMemberConversationIDs(token: context.token)
      await checkConversations(channelIDs, context: context, replaceAll: true)
    } catch {
      recordSyncFailure()
      logger.error(
        "Unread sweep failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private struct SyncContext {
    let token: String
    let teamID: String
    let userID: String
  }

  private func syncContext() async -> SyncContext? {
    guard
      let identity,
      let token = try? await currentCredentials().userToken
    else {
      return nil
    }
    return SyncContext(
      token: token,
      teamID: identity.teamID ?? "",
      userID: identity.userID
    )
  }

  private func fetchMemberConversationIDs(token: String) async throws -> [String] {
    var channelIDs: [String] = []
    var cursor: String?
    repeat {
      var queryItems = [
        URLQueryItem(
          name: "types",
          value: "public_channel,private_channel,mpim,im"
        ),
        URLQueryItem(name: "exclude_archived", value: "true"),
        URLQueryItem(name: "limit", value: "200"),
      ]
      if let cursor {
        queryItems.append(URLQueryItem(name: "cursor", value: cursor))
      }
      let response: ConversationListResponse = try await SlackHTTP.request(
        method: "users.conversations",
        token: token,
        queryItems: queryItems
      )
      guard response.ok else {
        throw SlackAPIError.api(response.error ?? "users.conversations failed")
      }
      channelIDs += (response.channels ?? []).map(\.id)
      cursor = response.responseMetadata?.nextCursor
      if cursor?.isEmpty == true {
        cursor = nil
      }
    } while cursor != nil
    return channelIDs
  }

  // Checks conversations in small concurrent chunks to stay within Slack's
  // rate tiers, then publishes the updated snapshot. A conversation whose
  // check fails keeps its previous state rather than flickering away.
  private func checkConversations(
    _ channelIDs: [String],
    context: SyncContext,
    replaceAll: Bool = false
  ) async {
    let channelIDs = Array(Set(channelIDs))
    guard !channelIDs.isEmpty else {
      if replaceAll {
        unreads = [:]
        onUnreadsChanged?([])
      }
      return
    }

    beginSync()
    defer {
      activeSyncCount -= 1
      syncStatus.isChecking = activeSyncCount > 0
    }

    let previousUnreadIDs = Set(unreads.keys)
    var results: [String: SlackChannelUnread] = [:]
    var checked: Set<String> = []
    for chunkStart in stride(from: 0, to: channelIDs.count, by: 5) {
      guard !Task.isCancelled else {
        return
      }
      let chunk = channelIDs[chunkStart..<min(chunkStart + 5, channelIDs.count)]
      await withTaskGroup(of: ConversationCheckResult.self) { group in
        for channelID in chunk {
          group.addTask {
            do {
              let unread = try await self.unreadState(
                of: channelID,
                context: context
              )
              return ConversationCheckResult(
                channelID: channelID,
                unread: unread,
                errorDescription: nil
              )
            } catch {
              return ConversationCheckResult(
                channelID: channelID,
                unread: nil,
                errorDescription: error.localizedDescription
              )
            }
          }
        }
        for await entry in group {
          if let errorDescription = entry.errorDescription {
            logger.warning(
              "Could not refresh \(entry.channelID, privacy: .public): \(errorDescription, privacy: .public)"
            )
          } else {
            checked.insert(entry.channelID)
            results[entry.channelID] = entry.unread
          }
        }
      }
    }

    if replaceAll {
      // Drop conversations no longer returned by users.conversations, but
      // preserve the previous state for any requested conversation whose
      // lookup failed. A transient error must never create a false "all read".
      let requested = Set(channelIDs)
      unreads = unreads.filter { requested.contains($0.key) }
    }
    for channelID in checked {
      unreads[channelID] = results[channelID] ?? nil
    }

    let liveIDs = Set(unreads.keys)
    mentionPriorities = mentionPriorities.filter { channelID, mark in
      guard let unread = unreads[channelID] else {
        return false
      }
      return !SlackTimestamp.isOrdered(mark.timestamp, notAfter: unread.lastRead)
    }
    recentlyOpenedUntil = recentlyOpenedUntil.filter {
      liveIDs.contains($0.key)
    }
    lastRotatingCheckAt = lastRotatingCheckAt.filter {
      liveIDs.contains($0.key)
    }

    // A newly discovered DM or mention should not wait behind an existing
    // rotation. Promotion changes ordering only; event delivery already
    // triggered the lookup that discovered it.
    for channelID in liveIDs.subtracting(previousUnreadIDs) {
      guard
        unreads[channelID]?.kind.isDirect == true
          || mentionPriorities[channelID] != nil
      else {
        continue
      }
      recheckRotation.promote(channelID)
    }

    let failureCount = channelIDs.count - checked.count
    if !checked.isEmpty {
      syncStatus.lastSuccessfulCheck = Date()
    }
    syncStatus.failedConversationCount = failureCount
    onUnreadsChanged?(Array(unreads.values))
  }

  private struct ConversationCheckResult: Sendable {
    let channelID: String
    let unread: SlackChannelUnread?
    let errorDescription: String?
  }

  private func beginSync() {
    activeSyncCount += 1
    syncStatus.isChecking = true
  }

  private func recordSyncFailure() {
    syncStatus.failedConversationCount = max(
      syncStatus.failedConversationCount,
      1
    )
  }

  // Double optional by design: .some(nil) means "confirmed read", nil from a
  // thrown error means "unknown, keep previous state".
  private func unreadState(
    of channelID: String,
    context: SyncContext
  ) async throws -> SlackChannelUnread? {
    let response: ConversationInfoResponse = try await SlackHTTP.request(
      method: "conversations.info",
      token: context.token,
      queryItems: [URLQueryItem(name: "channel", value: channelID)]
    )
    guard response.ok, let conversation = response.channel else {
      throw SlackAPIError.api(response.error ?? "conversations.info failed")
    }
    guard let lastRead = conversation.lastRead, !lastRead.isEmpty else {
      // No read marker means the conversation was never opened; flagging its
      // entire history as unread would be noise.
      return nil
    }

    let unreadCount: Int?
    if let display = conversation.unreadCountDisplay {
      guard display > 0 else {
        return nil
      }
      unreadCount = display
    } else {
      // Some conversation types omit the count; probe history for messages
      // beyond the read marker instead.
      let probed = try await unreadProbe(
        channelID,
        newerThan: lastRead,
        context: context
      )
      guard probed > 0 else {
        return nil
      }
      unreadCount = probed >= 10 ? nil : probed
    }

    let kind = conversationKind(of: conversation)
    let name = await displayName(of: conversation, kind: kind, context: context)
    return SlackChannelUnread(
      teamID: context.teamID,
      channelID: channelID,
      name: name,
      kind: kind,
      unreadCount: unreadCount,
      lastRead: lastRead
    )
  }

  private func unreadProbe(
    _ channelID: String,
    newerThan lastRead: String,
    context: SyncContext
  ) async throws -> Int {
    let response: ConversationHistoryResponse = try await SlackHTTP.request(
      method: "conversations.history",
      token: context.token,
      queryItems: [
        URLQueryItem(name: "channel", value: channelID),
        URLQueryItem(name: "oldest", value: lastRead),
        URLQueryItem(name: "limit", value: "10"),
      ]
    )
    guard response.ok else {
      throw SlackAPIError.api(response.error ?? "conversations.history failed")
    }
    return (response.messages ?? [])
      .filter { message in
        guard message.user != context.userID else {
          return false
        }
        guard let subtype = message.subtype else {
          return true
        }
        return !SlackEventClassifier.ignoredSubtypes.contains(subtype)
      }
      .count
  }

  private func conversationKind(
    of conversation: ConversationInfoResponse.Conversation
  ) -> SlackConversationKind {
    if conversation.isIM == true {
      return .directMessage
    }
    if conversation.isMPIM == true {
      return .groupDirectMessage
    }
    if conversation.isPrivate == true {
      return .privateChannel
    }
    return .channel
  }

  private func displayName(
    of conversation: ConversationInfoResponse.Conversation,
    kind: SlackConversationKind,
    context: SyncContext
  ) async -> String {
    switch kind {
    case .directMessage:
      guard let userID = conversation.user else {
        return "Direct message"
      }
      return (try? await resolveUserName(userID, token: context.token)) ?? userID
    case .groupDirectMessage:
      guard let name = nonempty(conversation.name) else {
        return "Group message"
      }
      // Slack names group DMs "mpdm-alice--bob--carol-1".
      let trimmed = name
        .replacingOccurrences(of: "mpdm-", with: "")
        .replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
      return trimmed
        .components(separatedBy: "--")
        .joined(separator: ", ")
    case .channel, .privateChannel:
      guard let name = nonempty(conversation.name) else {
        return "Unknown channel"
      }
      return "#\(name)"
    }
  }

  private func acknowledge(
    _ envelopeID: String,
    on socket: URLSessionWebSocketTask
  ) async throws {
    let data = try encoder.encode(SocketAcknowledgement(envelopeID: envelopeID))
    // Slack Socket Mode expects acknowledgements as JSON text frames; binary
    // frames are ignored, causing event redelivery and forced disconnects.
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }

  private func sendPing(on socket: URLSessionWebSocketTask) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      socket.sendPing { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func fetchIdentity(userToken: String) async throws -> SlackIdentity {
    let response: AuthTestResponse = try await SlackHTTP.request(
      method: "auth.test",
      token: userToken
    )
    guard response.ok, let userID = response.userID else {
      throw SlackAPIError.api(response.error ?? "auth.test failed")
    }
    return SlackIdentity(
      userID: userID,
      teamID: response.teamID,
      workspaceName: response.team ?? "Slack"
    )
  }

  private func currentCredentials() async throws -> SlackCredentials {
    guard let credentials else {
      throw SlackAPIError.notConfigured
    }
    guard credentials.shouldRefresh else {
      return credentials
    }

    if let refreshTask {
      return try await refreshTask.value
    }

    let task = Task<SlackCredentials, any Error> {
      try await SlackOAuthClient.refresh(credentials)
    }
    refreshTask = task
    defer {
      refreshTask = nil
    }
    let refreshed = try await task.value
    // Keep the rotated tokens even if persisting fails: Slack has already
    // consumed the old refresh token, so discarding these would permanently
    // break auth until the user redoes setup.
    self.credentials = refreshed
    do {
      try await Task.detached {
        try SlackCredentialStore.save(refreshed)
      }.value
    } catch {
      logger.error(
        "Could not persist refreshed credentials: \(error.localizedDescription, privacy: .public)"
      )
    }
    return refreshed
  }

  private func openSocketURL(appToken: String) async throws -> URL {
    let response: OpenSocketResponse = try await SlackHTTP.request(
      method: "apps.connections.open",
      token: appToken,
      httpMethod: "POST"
    )
    guard response.ok, let urlString = response.url, let url = URL(string: urlString) else {
      throw SlackAPIError.api(response.error ?? "apps.connections.open failed")
    }
    return url
  }

  private func resolveUserName(_ userID: String, token: String) async throws -> String {
    if let cached = userNameCache[userID] {
      return cached
    }

    let response: UserInfoResponse = try await SlackHTTP.request(
      method: "users.info",
      token: token,
      queryItems: [URLQueryItem(name: "user", value: userID)]
    )
    guard response.ok, let user = response.user else {
      throw SlackAPIError.api(response.error ?? "users.info failed")
    }

    let name =
      nonempty(user.profile?.displayName)
      ?? nonempty(user.profile?.realName)
      ?? nonempty(user.realName)
      ?? nonempty(user.name)
      ?? userID
    userNameCache[userID] = name
    return name
  }

  private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
      return nil
    }
    return value
  }
}

private struct SlackIdentity {
  let userID: String
  let teamID: String?
  let workspaceName: String
}

private struct SocketAcknowledgement: Encodable {
  let envelopeID: String

  enum CodingKeys: String, CodingKey {
    case envelopeID = "envelope_id"
  }
}

private struct AuthTestResponse: Decodable {
  let ok: Bool
  let userID: String?
  let teamID: String?
  let team: String?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case ok
    case userID = "user_id"
    case teamID = "team_id"
    case team
    case error
  }
}

private struct OpenSocketResponse: Decodable {
  let ok: Bool
  let url: String?
  let error: String?
}

private struct UserInfoResponse: Decodable {
  struct User: Decodable {
    struct Profile: Decodable {
      let displayName: String?
      let realName: String?

      enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case realName = "real_name"
      }
    }

    let name: String?
    let realName: String?
    let profile: Profile?

    enum CodingKeys: String, CodingKey {
      case name
      case realName = "real_name"
      case profile
    }
  }

  let ok: Bool
  let user: User?
  let error: String?
}

private struct ConversationListResponse: Decodable {
  struct Entry: Decodable {
    let id: String
  }

  struct Metadata: Decodable {
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
      case nextCursor = "next_cursor"
    }
  }

  let ok: Bool
  let channels: [Entry]?
  let error: String?
  let responseMetadata: Metadata?

  enum CodingKeys: String, CodingKey {
    case ok
    case channels
    case error
    case responseMetadata = "response_metadata"
  }
}

private struct ConversationInfoResponse: Decodable {
  struct Conversation: Decodable {
    let name: String?
    let lastRead: String?
    let unreadCountDisplay: Int?
    let isIM: Bool?
    let isMPIM: Bool?
    let isPrivate: Bool?
    let user: String?

    enum CodingKeys: String, CodingKey {
      case name
      case lastRead = "last_read"
      case unreadCountDisplay = "unread_count_display"
      case isIM = "is_im"
      case isMPIM = "is_mpim"
      case isPrivate = "is_private"
      case user
    }
  }

  let ok: Bool
  let channel: Conversation?
  let error: String?
}

private struct ConversationHistoryResponse: Decodable {
  struct Message: Decodable {
    let user: String?
    let subtype: String?
  }

  let ok: Bool
  let messages: [Message]?
  let error: String?
}
