import AppKit
import Testing
@testable import OpenPlan

struct WindowAttachmentTests {
  @Test func appDragPreservesGapAndTopAlignmentOnEitherSide() {
    for side in [WindowAttachment.Side.left, .right] {
      let attachment = WindowAttachment(side: side)
      let size = CGSize(width: 76, height: 760)
      let app = CGRect(x: 200, y: 100, width: 900, height: 800)
      let before = attachment.railOrigin(appFrame: app, railSize: size)
      let after = attachment.railOrigin(appFrame: app.offsetBy(dx: -350, dy: 200), railSize: size)
      #expect(after.x - before.x == -350)
      #expect(after.y - before.y == 200)
      #expect(before.y + size.height == app.maxY)
      #expect(side == .left ? app.minX - before.x - size.width == 8 : before.x - app.maxX == 8)
    }
  }

  @Test func resizingKeepsRailOutsideAppAndAlignedAtTop() {
    let attachment = WindowAttachment(side: .right)
    let origin = attachment.railOrigin(appFrame: CGRect(x: -800, y: 300, width: 1200, height: 900),
                                       railSize: CGSize(width: 76, height: 760))
    #expect(origin == CGPoint(x: 408, y: 440))
  }

  @Test func quartzConversionHandlesDisplaysAboveAndLeftOfMainDisplay() {
    let frame = WindowAttachment.appKitFrame(from: CGRect(x: -1200, y: -500, width: 900, height: 700), desktopTop: 1080)
    #expect(frame == CGRect(x: -1200, y: 880, width: 900, height: 700))
    for side in [WindowAttachment.Side.left, .right] {
      let attachment = WindowAttachment(side: side)
      let size = CGSize(width: 76, height: 600)
      let rail = CGRect(origin: attachment.railOrigin(appFrame: frame, railSize: size), size: size)
      let position = attachment.appQuartzOrigin(railFrame: rail, appSize: frame.size, desktopTop: 1080)
      #expect(position == CGPoint(x: -1200, y: -500))
      let quartzRail = CGRect(x: rail.minX, y: 1080 - rail.maxY, width: rail.width, height: rail.height)
      #expect(attachment.appQuartzOrigin(fromRailQuartzFrame: quartzRail, appSize: frame.size) == position)
    }
  }
}

@MainActor
struct NativeWindowPairTests {
  @Test func settingsAndRailMoveTogetherInBothDirectionsAndDetachCleanly() {
    _ = NSApplication.shared
    let rail = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 76, height: 600),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    let settings = NSWindow(contentRect: CGRect(x: 184, y: 100, width: 600, height: 600),
                            styleMask: [.borderless], backing: .buffered, defer: false)
    let pair = WindowPairController()
    pair.railWindow = rail
    pair.attach(nativeWindow: settings)
    #expect(rail.parent === settings)
    settings.setFrameOrigin(CGPoint(x: 284, y: 200))
    #expect(rail.frame.origin == CGPoint(x: 200, y: 200))
    // The child relationship displays both windows without activating either.
    settings.orderFront(nil)
    pair.beginRailDrag()
    #expect(settings.parent === rail)
    #expect(pair.dragLeader == .rail)
    rail.setFrameOrigin(CGPoint(x: 250, y: 160))
    pair.beginApplicationDrag()
    #expect(pair.dragLeader == .application)
    #expect(rail.parent === settings)
    #expect(settings.frame.origin == CGPoint(x: 334, y: 160))
    #expect(rail.frame.origin == CGPoint(x: 250, y: 160))
    pair.detach()
    #expect(rail.parent == nil)
    settings.setFrameOrigin(CGPoint(x: 500, y: 500))
    #expect(rail.frame.origin == CGPoint(x: 250, y: 160))
    rail.orderOut(nil)
    settings.orderOut(nil)
  }
}
