import Foundation
@preconcurrency import Security

struct SlackCredentials: Equatable, Sendable {
  let clientID: String?
  let appToken: String
  let userToken: String
  let refreshToken: String?
  let expiresAt: Date?

  var isPlausible: Bool {
    appToken.hasPrefix("xapp-")
      && (userToken.hasPrefix("xoxp-") || userToken.hasPrefix("xoxe.xoxp-"))
  }

  var canRefresh: Bool {
    clientID?.isEmpty == false && refreshToken?.isEmpty == false
  }

  var shouldRefresh: Bool {
    guard canRefresh, let expiresAt else {
      return false
    }
    return expiresAt.timeIntervalSinceNow < 300
  }
}

// Deliberately not actor-isolated: the Security framework is thread-safe, and
// keeping these synchronous keychain IPC calls off the main actor lets launch
// and token refresh run them from background tasks without beachballing.
enum SlackCredentialStore {
  private static let service = "com.michaelbrusegard.SlackSlopbar.SlackAPI"
  // One-time migration from the application's former name. Remove this after
  // every installed copy has had a chance to launch Slack Slopbar once.
  private static let legacyService = "com.michaelbrusegard.SlackMenubar.SlackAPI"
  private static let clientIDAccount = "client-id"
  private static let appTokenAccount = "app-token"
  private static let userTokenAccount = "user-token"
  private static let refreshTokenAccount = "refresh-token"
  private static let expiresAtAccount = "expires-at"

  static func load() throws -> SlackCredentials? {
    if let credentials = try load(service: service) {
      return credentials
    }
    guard let credentials = try load(service: legacyService) else {
      return nil
    }
    try save(credentials)
    // The former item's ACL may reject deletion from the renamed bundle even
    // though macOS allowed it to be read. The new copy is authoritative.
    try? remove(service: legacyService)
    return credentials
  }

  private static func load(service: String) throws -> SlackCredentials? {
    guard
      let appToken = try read(account: appTokenAccount, service: service),
      let userToken = try read(account: userTokenAccount, service: service)
    else {
      return nil
    }
    let expiresAt =
      try read(account: expiresAtAccount, service: service)
      .flatMap(TimeInterval.init)
      .map(Date.init(timeIntervalSince1970:))
    return SlackCredentials(
      clientID: try read(account: clientIDAccount, service: service),
      appToken: appToken,
      userToken: userToken,
      refreshToken: try read(account: refreshTokenAccount, service: service),
      expiresAt: expiresAt
    )
  }

  static func save(_ credentials: SlackCredentials) throws {
    try writeOptional(credentials.clientID, account: clientIDAccount)
    try write(credentials.appToken, account: appTokenAccount)
    try write(credentials.userToken, account: userTokenAccount)
    try writeOptional(credentials.refreshToken, account: refreshTokenAccount)
    try writeOptional(
      credentials.expiresAt.map { String($0.timeIntervalSince1970) },
      account: expiresAtAccount
    )
  }

  static func remove() throws {
    try remove(service: service)
    try? remove(service: legacyService)
  }

  private static func remove(service: String) throws {
    try delete(account: clientIDAccount, service: service)
    try delete(account: appTokenAccount, service: service)
    try delete(account: userTokenAccount, service: service)
    try delete(account: refreshTokenAccount, service: service)
    try delete(account: expiresAtAccount, service: service)
  }

  private static func read(account: String, service: String) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError(status)
    }
    guard
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw KeychainError(errSecDecode)
    }
    return value
  }

  private static func write(_ value: String, account: String) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let data = Data(value.utf8)
    let update: [CFString: Any] = [
      kSecValueData: data
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError(updateStatus)
    }

    var item = query
    item[kSecValueData] = data
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError(addStatus)
    }
  }

  private static func writeOptional(_ value: String?, account: String) throws {
    if let value {
      try write(value, account: account)
    } else {
      try delete(account: account)
    }
  }

  private static func delete(
    account: String,
    service: String = SlackCredentialStore.service
  ) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status)
    }
  }
}

private struct KeychainError: LocalizedError {
  let status: OSStatus

  init(_ status: OSStatus) {
    self.status = status
  }

  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String?
      ?? "Keychain error \(status)"
  }
}
