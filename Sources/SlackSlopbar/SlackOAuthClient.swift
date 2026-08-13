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
    // base64url of 24/48 random bytes gives 32/64 URL-safe characters; the
    // verifier length satisfies RFC 7636's 43-128 requirement.
    state = Self.base64URL(Self.randomData(count: 24))
    codeVerifier = Self.base64URL(Self.randomData(count: 48))
  }

  private static func randomData(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data(
      (0..<count).map { _ in
        UInt8.random(in: .min ... .max, using: &generator)
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
  static let redirectURI = "slackslopbar://oauth"
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
    // The `team` parameter on the authorization URL only pre-selects a
    // workspace; Slack can still complete the flow for whichever workspace
    // the browser is signed into, so the granted team must be checked here.
    if
      let expectedTeamID = oauthRequest.teamID,
      let authorizedTeamID = response.team?.id,
      authorizedTeamID != expectedTeamID
    {
      throw SlackAPIError.workspaceMismatch(
        authorized: response.team?.name ?? authorizedTeamID
      )
    }
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
    let response: SlackOAuthResponse = try await SlackHTTP.request(
      method: "oauth.v2.access",
      httpMethod: "POST",
      formItems: formItems
    )
    guard response.ok else {
      throw SlackAPIError.api(response.error ?? "OAuth failed")
    }
    return response
  }

  private static func credentials(
    from response: SlackOAuthResponse,
    clientID: String,
    appToken: String
  ) throws -> SlackCredentials {
    let accessToken = response.authedUser?.accessToken ?? response.accessToken
    guard let accessToken else {
      throw SlackAPIError.missingUserToken
    }

    let refreshToken =
      response.authedUser?.refreshToken
      ?? response.refreshToken
    let expiresIn = response.authedUser?.expiresIn ?? response.expiresIn
    if expiresIn != nil, refreshToken == nil {
      throw SlackAPIError.missingRefreshToken
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

  struct Team: Decodable {
    let id: String?
    let name: String?
  }

  let ok: Bool
  let error: String?
  let accessToken: String?
  let refreshToken: String?
  let expiresIn: Int?
  let authedUser: AuthedUser?
  let team: Team?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
    case authedUser = "authed_user"
    case team
  }
}
