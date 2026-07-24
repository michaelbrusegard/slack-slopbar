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

@MainActor
enum SlackCredentialStore {
  private static let service = "com.michaelbrusegard.SlackMenubar.SlackAPI"
  private static let clientIDAccount = "client-id"
  private static let appTokenAccount = "app-token"
  private static let userTokenAccount = "user-token"
  private static let refreshTokenAccount = "refresh-token"
  private static let expiresAtAccount = "expires-at"

  static func load() throws -> SlackCredentials? {
    guard
      let appToken = try read(account: appTokenAccount),
      let userToken = try read(account: userTokenAccount)
    else {
      return nil
    }
    let expiresAt =
      try read(account: expiresAtAccount)
      .flatMap(TimeInterval.init)
      .map(Date.init(timeIntervalSince1970:))
    return SlackCredentials(
      clientID: try read(account: clientIDAccount),
      appToken: appToken,
      userToken: userToken,
      refreshToken: try read(account: refreshTokenAccount),
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
    try delete(account: clientIDAccount)
    try delete(account: appTokenAccount)
    try delete(account: userTokenAccount)
    try delete(account: refreshTokenAccount)
    try delete(account: expiresAtAccount)
  }

  private static func read(account: String) throws -> String? {
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

  private static func delete(account: String) throws {
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
