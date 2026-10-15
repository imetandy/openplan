import Foundation

/// Geometry shared by both drag directions. Dragging never refits or flips sides.
struct WindowAttachment: Sendable {
  enum Side: Sendable { case left, right }
  let side: Side
  var gap: CGFloat = 8

  func railOrigin(appFrame: CGRect, railSize: CGSize) -> CGPoint {
    CGPoint(
      x: side == .left ? appFrame.minX - gap - railSize.width : appFrame.maxX + gap,
      y: appFrame.maxY - railSize.height
    )
  }

  static func appKitFrame(from quartzFrame: CGRect, desktopTop: CGFloat) -> CGRect {
    CGRect(x: quartzFrame.minX, y: desktopTop - quartzFrame.maxY,
           width: quartzFrame.width, height: quartzFrame.height)
  }

  func appQuartzOrigin(fromRailQuartzFrame frame: CGRect, appSize: CGSize) -> CGPoint {
    CGPoint(x: side == .left ? frame.maxX + gap : frame.minX - gap - appSize.width,
            y: frame.minY)
  }

  func appQuartzOrigin(railFrame: CGRect, appSize: CGSize, desktopTop: CGFloat) -> CGPoint {
    CGPoint(
      x: side == .left ? railFrame.maxX + gap : railFrame.minX - gap - appSize.width,
      y: desktopTop - railFrame.maxY
    )
  }
}
