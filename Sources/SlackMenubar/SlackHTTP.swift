import Foundation

// The single HTTP transport for every Slack Web API call, shared by the API
// service and the OAuth client so request construction, status handling, and
// error mapping can only evolve in one place.
enum SlackHTTP {
  private static let decoder = JSONDecoder()

  static func request<Response: Decodable>(
    method: String,
    token: String? = nil,
    httpMethod: String = "GET",
    queryItems: [URLQueryItem] = [],
    formItems: [URLQueryItem] = []
  ) async throws -> Response {
    var components = URLComponents(string: "https://slack.com/api/\(method)")
    components?.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components?.url else {
      throw SlackAPIError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = httpMethod
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if httpMethod == "POST" {
      request.setValue(
        "application/x-www-form-urlencoded",
        forHTTPHeaderField: "Content-Type"
      )
      var form = URLComponents()
      form.queryItems = formItems.isEmpty ? nil : formItems
      request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) } ?? Data()
    }

    var attempt = 0
    while true {
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
          throw SlackAPIError.invalidResponse
        }

        if httpResponse.statusCode == 429, attempt < 3 {
          let retryAfter =
            httpResponse.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)
            ?? pow(2, Double(attempt))
          attempt += 1
          try await Task.sleep(for: .seconds(max(1, retryAfter)))
          continue
        }
        if (500..<600).contains(httpResponse.statusCode), attempt < 2 {
          let delay = pow(2, Double(attempt))
          attempt += 1
          try await Task.sleep(for: .seconds(delay))
          continue
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
          throw SlackAPIError.http(httpResponse.statusCode)
        }

        do {
          return try decoder.decode(Response.self, from: data)
        } catch {
          throw SlackAPIError.decoding(error.localizedDescription)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch is URLError where attempt < 2 {
        attempt += 1
        try await Task.sleep(for: .seconds(pow(2, Double(attempt - 1))))
      }
    }
  }
}

enum SlackAPIError: LocalizedError, Equatable {
  case api(String)
  case decoding(String)
  case http(Int)
  case invalidResponse
  case invalidURL
  case notConfigured
  case socketRefreshRequested
  case missingRefreshToken
  case missingUserToken
  case workspaceMismatch(authorized: String)

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
    case .notConfigured:
      return "Slack API setup is required"
    case .socketRefreshRequested:
      return "Slack requested a connection refresh"
    case .missingRefreshToken:
      return "Slack did not return the refresh token needed to stay connected"
    case .missingUserToken:
      return "Slack did not return a user access token"
    case .workspaceMismatch(let authorized):
      return
        "Slack authorized \(authorized) instead of the selected workspace. Sign in to the selected workspace in your browser and try again."
    }
  }
}
