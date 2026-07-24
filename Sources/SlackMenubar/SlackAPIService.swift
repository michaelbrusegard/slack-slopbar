import Foundation
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

@MainActor
final class SlackAPIService {
  var onStateChange: ((SlackConnectionState) -> Void)?
  var onNotification: ((SlackMenuNotification) -> Void)?

  private var state: SlackConnectionState = .unconfigured {
    didSet {
      guard oldValue != state else {
        return
      }
      onStateChange?(state)
    }
  }

  private var credentials: SlackCredentials?
  private var identity: SlackIdentity?
  private var connectionTask: Task<Void, Never>?
  private var socket: URLSessionWebSocketTask?
  private var userNameCache: [String: String] = [:]
  private var conversationNameCache: [String: String] = [:]

  func connect(using credentials: SlackCredentials) {
    disconnect(setState: false)
    self.credentials = credentials
    identity = nil
    state = .connecting

    connectionTask = Task { [weak self] in
      await self?.runConnectionLoop()
    }
  }

  func disconnect() {
    disconnect(setState: true)
  }

  private func disconnect(setState: Bool) {
    connectionTask?.cancel()
    connectionTask = nil
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
        guard let credentials else {
          state = .unconfigured
          return
        }

        let identity: SlackIdentity
        if let existingIdentity = self.identity {
          identity = existingIdentity
        } else {
          identity = try await fetchIdentity(userToken: credentials.userToken)
        }
        self.identity = identity

        let socketURL = try await openSocketURL(appToken: credentials.appToken)
        let socket = URLSession.shared.webSocketTask(with: socketURL)
        self.socket = socket
        socket.resume()
        state = .connected(workspace: identity.workspaceName)
        retryDelay = 1

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
        try await sendPing(on: socket)
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

      let envelope = try JSONDecoder().decode(SlackSocketEnvelope.self, from: data)
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
    guard
      let kind = SlackEventClassifier.classify(
        event,
        authenticatedUserID: identity.userID
      )
    else {
      return
    }

    let senderName: String
    if let userID = event.user {
      senderName =
        (try? await resolveUserName(userID, token: identity.userToken))
        ?? userID
    } else {
      senderName = "Slack app"
    }

    let conversationName: String
    if kind == .directMessage {
      conversationName = "Direct message"
    } else {
      let resolved =
        try? await resolveConversationName(
          event.channel,
          token: identity.userToken
        )
      conversationName = resolved.map { "#\($0)" } ?? event.channel
    }

    let receivedAt =
      Double(event.timestamp).map {
        Date(timeIntervalSince1970: $0)
      } ?? Date()
    let notification = SlackMenuNotification(
      teamID: payload.teamID,
      channelID: event.channel,
      messageTimestamp: event.timestamp,
      senderName: senderName,
      conversationName: conversationName,
      kind: kind,
      receivedAt: receivedAt
    )
    onNotification?(notification)
  }

  private func acknowledge(
    _ envelopeID: String,
    on socket: URLSessionWebSocketTask
  ) async throws {
    let data = try JSONEncoder().encode(SocketAcknowledgement(envelopeID: envelopeID))
    try await socket.send(.data(data))
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
    let response: AuthTestResponse = try await request(
      method: "auth.test",
      token: userToken
    )
    guard response.ok, let userID = response.userID else {
      throw SlackAPIError.api(response.error ?? "auth.test failed")
    }
    return SlackIdentity(
      userID: userID,
      workspaceName: response.team ?? "Slack",
      userToken: userToken
    )
  }

  private func openSocketURL(appToken: String) async throws -> URL {
    let response: OpenSocketResponse = try await request(
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

    let response: UserInfoResponse = try await request(
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

  private func resolveConversationName(
    _ channelID: String,
    token: String
  ) async throws -> String {
    if let cached = conversationNameCache[channelID] {
      return cached
    }

    let response: ConversationInfoResponse = try await request(
      method: "conversations.info",
      token: token,
      queryItems: [URLQueryItem(name: "channel", value: channelID)]
    )
    guard response.ok else {
      throw SlackAPIError.api(response.error ?? "conversations.info failed")
    }

    let name = nonempty(response.channel?.name) ?? channelID
    conversationNameCache[channelID] = name
    return name
  }

  private func request<Response: Decodable>(
    method: String,
    token: String,
    httpMethod: String = "GET",
    queryItems: [URLQueryItem] = []
  ) async throws -> Response {
    var components = URLComponents(string: "https://slack.com/api/\(method)")
    components?.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components?.url else {
      throw SlackAPIError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = httpMethod
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if httpMethod == "POST" {
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data()
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SlackAPIError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw SlackAPIError.http(httpResponse.statusCode)
    }

    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw SlackAPIError.decoding(error.localizedDescription)
    }
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
  let workspaceName: String
  let userToken: String
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
  let team: String?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case ok
    case userID = "user_id"
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

private struct ConversationInfoResponse: Decodable {
  struct Conversation: Decodable {
    let name: String?
  }

  let ok: Bool
  let channel: Conversation?
  let error: String?
}

private enum SlackAPIError: LocalizedError {
  case api(String)
  case decoding(String)
  case http(Int)
  case invalidResponse
  case invalidURL
  case socketRefreshRequested

  var errorDescription: String? {
    switch self {
    case .api(let message):
      return message
    case .decoding(let message):
      return "Could not decode Slack response: \(message)"
    case .http(let status):
      return "Slack returned HTTP \(status)"
    case .invalidResponse:
      return "Slack returned an invalid response"
    case .invalidURL:
      return "Could not construct the Slack API URL"
    case .socketRefreshRequested:
      return "Slack requested a connection refresh"
    }
  }
}
