import AppKit
import SwiftUI

/// An explicit native drag target; SwiftUI hit testing must not swallow mouse-down.
struct WindowDragHandle: NSViewRepresentable {
  var onBegin: (() -> Void)? = nil

  func makeNSView(context: Context) -> DragView {
    let view = DragView()
    updateNSView(view, context: context)
    return view
  }
  func updateNSView(_ nsView: DragView, context: Context) {
    nsView.onBegin = onBegin
  }

  final class DragView: NSView {
    var onBegin: (() -> Void)?
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
      let local = convert(point, from: superview)
      // Let the two traffic-light controls receive their own mouse events.
      if local.y < 36, (9...51).contains(local.x) { return nil }
      return super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      onBegin?()
      window?.performDrag(with: event)
    }

    override func resetCursorRects() {
      addCursorRect(NSRect(x: 0, y: 0, width: 9, height: 36), cursor: .openHand)
      addCursorRect(NSRect(x: 51, y: 0, width: max(0, bounds.width - 51), height: 36), cursor: .openHand)
      addCursorRect(NSRect(x: 0, y: 36, width: bounds.width, height: max(0, bounds.height - 36)), cursor: .openHand)
    }
  }
}
