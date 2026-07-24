import CryptoKit
import Foundation

struct SlackOAuthRequest: Sendable {
  let clientID: String
  let appToken: String
  let teamID: String?
  let state: String
  let codeVerifier: String

  var authorizationURL: URL? {
    let challenge = Self.base64URL(
      Data(SHA256.hash(data: Data(codeVerifier.utf8)))
    )
    var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")
    var queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "scope", value: ""),
      URLQueryItem(name: "user_scope", value: SlackOAuthClient.userScopes.joined(separator: ",")),
      URLQueryItem(name: "redirect_uri", value: SlackOAuthClient.redirectURI),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    if let teamID {
      queryItems.append(URLQueryItem(name: "team", value: teamID))
    }
    components?.queryItems = queryItems
    return components?.url
  }

  init(clientID: String, appToken: String, teamID: String?) {
    self.clientID = clientID
    self.appToken = appToken
    self.teamID = teamID
    state = Self.randomURLSafeString(length: 32)
    codeVerifier = Self.randomURLSafeString(length: 64)
  }

  private static func randomURLSafeString(length: Int) -> String {
    let characters = Array(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
    var generator = SystemRandomNumberGenerator()
    return String(
      (0..<length).map { _ in
        characters.randomElement(using: &generator)!
      }
    )
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

enum SlackOAuthClient {
  static let redirectURI = "slackmenubar://oauth"
  static let userScopes = [
    "channels:history",
    "channels:read",
    "groups:history",
    "groups:read",
    "im:history",
    "im:read",
    "mpim:history",
    "mpim:read",
    "users:read",
  ]

  static func exchange(
    code: String,
    request oauthRequest: SlackOAuthRequest
  ) async throws -> SlackCredentials {
    let response = try await tokenRequest([
      URLQueryItem(name: "client_id", value: oauthRequest.clientID),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "code_verifier", value: oauthRequest.codeVerifier),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "grant_type", value: "authorization_code"),
    ])
    return try credentials(
      from: response,
      clientID: oauthRequest.clientID,
      appToken: oauthRequest.appToken
    )
  }

  static func refresh(_ credentials: SlackCredentials) async throws -> SlackCredentials {
    guard
      let clientID = credentials.clientID,
      let refreshToken = credentials.refreshToken
    else {
      return credentials
    }

    let response = try await tokenRequest([
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "refresh_token", value: refreshToken),
      URLQueryItem(name: "grant_type", value: "refresh_token"),
    ])
    return try self.credentials(
      from: response,
      clientID: clientID,
      appToken: credentials.appToken
    )
  }

  private static func tokenRequest(
    _ formItems: [URLQueryItem]
  ) async throws -> SlackOAuthResponse {
    guard let url = URL(string: "https://slack.com/api/oauth.v2.access") else {
      throw SlackOAuthError.invalidURL
    }

    var form = URLComponents()
    form.queryItems = formItems
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw SlackOAuthError.invalidResponse
    }

    let oauthResponse: SlackOAuthResponse
    do {
      oauthResponse = try JSONDecoder().decode(SlackOAuthResponse.self, from: data)
    } catch {
      throw SlackOAuthError.decoding(error.localizedDescription)
    }
    guard oauthResponse.ok else {
      throw SlackOAuthError.api(oauthResponse.error ?? "OAuth failed")
    }
    return oauthResponse
  }

  private static func credentials(
    from response: SlackOAuthResponse,
    clientID: String,
    appToken: String
  ) throws -> SlackCredentials {
    let accessToken = response.authedUser?.accessToken ?? response.accessToken
    guard let accessToken else {
      throw SlackOAuthError.missingUserToken
    }

    let refreshToken =
      response.authedUser?.refreshToken
      ?? response.refreshToken
    let expiresIn = response.authedUser?.expiresIn ?? response.expiresIn
    if expiresIn != nil, refreshToken == nil {
      throw SlackOAuthError.missingRefreshToken
    }
    return SlackCredentials(
      clientID: clientID,
      appToken: appToken,
      userToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresIn.map {
        Date().addingTimeInterval(TimeInterval($0))
      }
    )
  }
}

private struct SlackOAuthResponse: Decodable {
  struct AuthedUser: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }

  let ok: Bool
  let error: String?
  let accessToken: String?
  let refreshToken: String?
  let expiresIn: Int?
  let authedUser: AuthedUser?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
    case authedUser = "authed_user"
  }
}

private enum SlackOAuthError: LocalizedError {
  case api(String)
  case decoding(String)
  case invalidResponse
  case invalidURL
  case missingRefreshToken
  case missingUserToken

  var errorDescription: String? {
    switch self {
    case .api(let message):
      return "Slack authorization failed: \(message)"
    case .decoding(let message):
      return "Could not read Slack's authorization response: \(message)"
    case .invalidResponse:
      return "Slack returned an invalid authorization response"
    case .invalidURL:
      return "Could not construct the Slack authorization URL"
    case .missingRefreshToken:
      return "Slack did not return the refresh token needed to stay connected"
    case .missingUserToken:
      return "Slack did not return a user access token"
    }
  }
}
