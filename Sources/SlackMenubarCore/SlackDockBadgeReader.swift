import AppKit
import ApplicationServices
import Foundation

@MainActor
public struct SlackDockBadgeReader {
  private static let slackBundleIdentifier = "com.tinyspeck.slackmacgap"
  private static let dockBundleIdentifier = "com.apple.dock"
  private static let statusLabelAttribute = "AXStatusLabel" as CFString
  private static let maximumTraversalDepth = 5
  private static let maximumElementsToInspect = 1_000

  public init() {}

  public var hasAccessibilityPermission: Bool {
    AXIsProcessTrusted()
  }

  @discardableResult
  public func requestAccessibilityPermission() -> Bool {
    let promptKey = "AXTrustedCheckOptionPrompt"
    return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
  }

  public func read() -> SlackBadgeStatus {
    guard hasAccessibilityPermission else {
      return .accessibilityPermissionRequired
    }

    guard
      let dock =
        NSRunningApplication
        .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
        .first
    else {
      return .slackUnavailable
    }

    let dockApplication = AXUIElementCreateApplication(dock.processIdentifier)
    guard let slackDockItem = findSlackDockItem(in: dockApplication) else {
      return .slackUnavailable
    }

    let statusLabel: String? = copyAttribute(
      Self.statusLabelAttribute,
      from: slackDockItem
    )
    return SlackBadgeParser.parse(statusLabel: statusLabel)
  }

  public func diagnosticReport() -> String {
    guard hasAccessibilityPermission else {
      return "Accessibility permission: not granted"
    }

    guard
      let dock =
        NSRunningApplication
        .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
        .first
    else {
      return "Dock process: unavailable"
    }

    let root = AXUIElementCreateApplication(dock.processIdentifier)
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var candidates: [String] = []
    var inspected = 0

    while !queue.isEmpty, inspected < Self.maximumElementsToInspect {
      let current = queue.removeFirst()
      inspected += 1

      if current.depth > 0, isSlackDockItem(current.element) {
        candidates.append(describe(current.element, depth: current.depth))
      }

      guard current.depth < Self.maximumTraversalDepth else {
        continue
      }

      let children: [AXUIElement]? = copyAttribute(
        kAXChildrenAttribute as CFString,
        from: current.element
      )
      for child in children ?? [] {
        queue.append((child, current.depth + 1))
      }
    }

    let heading = "Accessibility permission: granted\nInspected elements: \(inspected)"
    guard !candidates.isEmpty else {
      return "\(heading)\nSlack candidates: none"
    }
    return "\(heading)\n\(candidates.joined(separator: "\n"))"
  }

  private func findSlackDockItem(in root: AXUIElement) -> AXUIElement? {
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var inspected = 0

    while !queue.isEmpty, inspected < Self.maximumElementsToInspect {
      let current = queue.removeFirst()
      inspected += 1

      if current.depth > 0, isSlackDockItem(current.element) {
        return current.element
      }

      guard current.depth < Self.maximumTraversalDepth else {
        continue
      }

      let children: [AXUIElement]? = copyAttribute(
        kAXChildrenAttribute as CFString,
        from: current.element
      )
      for child in children ?? [] {
        queue.append((child, current.depth + 1))
      }
    }

    return nil
  }

  private func isSlackDockItem(_ element: AXUIElement) -> Bool {
    let title: String? = copyAttribute(kAXTitleAttribute as CFString, from: element)
    if title?.localizedCaseInsensitiveCompare("Slack") == .orderedSame {
      return true
    }

    let url: URL? = copyAttribute(kAXURLAttribute as CFString, from: element)
    if url?.lastPathComponent.localizedCaseInsensitiveCompare("Slack.app") == .orderedSame {
      return true
    }

    let bundleIdentifier: String? = copyAttribute(
      kAXIdentifierAttribute as CFString,
      from: element
    )
    return bundleIdentifier == Self.slackBundleIdentifier
  }

  private func copyAttribute<T>(
    _ attribute: CFString,
    from element: AXUIElement
  ) -> T? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success else {
      return nil
    }
    return value as? T
  }

  private func describe(_ element: AXUIElement, depth: Int) -> String {
    let role: String? = copyAttribute(kAXRoleAttribute as CFString, from: element)
    let subrole: String? = copyAttribute(kAXSubroleAttribute as CFString, from: element)
    let title: String? = copyAttribute(kAXTitleAttribute as CFString, from: element)
    let description: String? = copyAttribute(
      kAXDescriptionAttribute as CFString,
      from: element
    )
    let identifier: String? = copyAttribute(
      kAXIdentifierAttribute as CFString,
      from: element
    )
    let statusLabel: String? = copyAttribute(Self.statusLabelAttribute, from: element)
    let url: URL? = copyAttribute(kAXURLAttribute as CFString, from: element)
    let children: [AXUIElement]? = copyAttribute(
      kAXChildrenAttribute as CFString,
      from: element
    )

    return """
      Slack candidate (depth \(depth)):
        role=\(role ?? "nil")
        subrole=\(subrole ?? "nil")
        title=\(title ?? "nil")
        description=\(description ?? "nil")
        identifier=\(identifier ?? "nil")
        statusLabel=\(statusLabel ?? "nil")
        url=\(url?.path ?? "nil")
        children=\(children?.count ?? 0)
      """
  }
}
