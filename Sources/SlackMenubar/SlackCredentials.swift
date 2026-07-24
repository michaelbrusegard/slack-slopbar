import Foundation
@preconcurrency import Security

struct SlackCredentials: Equatable, Sendable {
  let appToken: String
  let userToken: String

  var isPlausible: Bool {
    appToken.hasPrefix("xapp-") && userToken.hasPrefix("xoxp-")
  }
}

@MainActor
enum SlackCredentialStore {
  private static let service = "com.michaelbrusegard.SlackMenubar.SlackAPI"
  private static let appTokenAccount = "app-token"
  private static let userTokenAccount = "user-token"

  static func load() throws -> SlackCredentials? {
    guard
      let appToken = try read(account: appTokenAccount),
      let userToken = try read(account: userTokenAccount)
    else {
      return nil
    }
    return SlackCredentials(appToken: appToken, userToken: userToken)
  }

  static func save(_ credentials: SlackCredentials) throws {
    try write(credentials.appToken, account: appTokenAccount)
    try write(credentials.userToken, account: userTokenAccount)
  }

  static func remove() throws {
    try delete(account: appTokenAccount)
    try delete(account: userTokenAccount)
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
