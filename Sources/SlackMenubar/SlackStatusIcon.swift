import AppKit

@MainActor
enum SlackStatusIcon {
  private struct Segment {
    let rect: NSRect
    let color: NSColor
  }

  // The two marks are cached: the drawing handler re-runs on every status-item
  // refresh otherwise, and there are only these two states.
  private static let filledMark = makeSlackMark(filled: true)
  private static let outlineMark = makeSlackMark(filled: false)

  static func slackMark(filled: Bool) -> NSImage {
    filled ? filledMark : outlineMark
  }

  private static func makeSlackMark(filled: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSGraphicsContext.current?.shouldAntialias = true

      for segment in segments {
        let path = NSBezierPath(
          roundedRect: segment.rect,
          xRadius: segment.rect.width / 2,
          yRadius: segment.rect.height / 2
        )

        if filled {
          segment.color.setFill()
          path.fill()
        } else {
          NSColor.black.setStroke()
          path.lineWidth = 1.1
          path.stroke()
        }
      }

      return true
    }

    // Template images follow the menu-bar tint and appearance. The unread mark
    // opts out so its four notification colors remain visible.
    image.isTemplate = !filled
    return image
  }

  private static let segments: [Segment] = [
    // Cyan: the upper-left vertical arm and its left dot.
    Segment(
      rect: NSRect(x: 5.1, y: 9, width: 3.2, height: 7.5),
      color: NSColor(srgbRed: 0.21, green: 0.77, blue: 0.94, alpha: 1)
    ),
    Segment(
      rect: NSRect(x: 1.5, y: 9, width: 3.2, height: 3.2),
      color: NSColor(srgbRed: 0.21, green: 0.77, blue: 0.94, alpha: 1)
    ),

    // Green: the upper-right horizontal arm and its top dot.
    Segment(
      rect: NSRect(x: 9, y: 9, width: 7.5, height: 3.2),
      color: NSColor(srgbRed: 0.18, green: 0.71, blue: 0.49, alpha: 1)
    ),
    Segment(
      rect: NSRect(x: 9, y: 13.3, width: 3.2, height: 3.2),
      color: NSColor(srgbRed: 0.18, green: 0.71, blue: 0.49, alpha: 1)
    ),

    // Yellow: the lower-right vertical arm and its right dot.
    Segment(
      rect: NSRect(x: 9, y: 1.5, width: 3.2, height: 7.5),
      color: NSColor(srgbRed: 0.93, green: 0.70, blue: 0.08, alpha: 1)
    ),
    Segment(
      rect: NSRect(x: 13.3, y: 5.8, width: 3.2, height: 3.2),
      color: NSColor(srgbRed: 0.93, green: 0.70, blue: 0.08, alpha: 1)
    ),

    // Red: the lower-left horizontal arm and its bottom dot.
    Segment(
      rect: NSRect(x: 1.5, y: 5.8, width: 7.5, height: 3.2),
      color: NSColor(srgbRed: 0.88, green: 0.16, blue: 0.36, alpha: 1)
    ),
    Segment(
      rect: NSRect(x: 5.8, y: 1.5, width: 3.2, height: 3.2),
      color: NSColor(srgbRed: 0.88, green: 0.16, blue: 0.36, alpha: 1)
    ),
  ]
}
