import AppKit
import SwiftUI
import Testing
@testable import OpenPlan

@MainActor
struct WindowDragHandleTests {
  @Test func pairedToolbarAlwaysUsesNativeWindowDragging() throws {
    _ = NSApplication.shared
    let handle = WindowDragHandle.DragView()
    let window = RecordingDragWindow(contentRect: CGRect(x: 0, y: 0, width: 76, height: 760),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = handle
    var events: [String] = []
    handle.onBegin = { events.append("prepare pair") }
    window.onDrag = { events.append("native drag") }
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
      clickCount: 1, pressure: 1))
    handle.mouseDown(with: event)
    #expect(events == ["prepare pair", "native drag"])
  }

  @Test func hostedRailExposesNativeDragTargets() throws {
    _ = NSApplication.shared
    let store = AppStore()
    let root = NSHostingView(rootView: ServiceRail(store: store))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 76, height: 760),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = root
    root.layoutSubtreeIfNeeded()
    let handle = try #require(findHandle(in: root))
    func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
      root.hitTest(handle.convert(NSPoint(x: x, y: y), to: root.superview))
    }
    #expect(hit(65, 18) === handle)
    #expect(hit(38, 56) === handle)
    #expect(hit(19, 18) !== handle)
    #expect(hit(40, 18) !== handle)
  }

  private func findHandle(in view: NSView) -> WindowDragHandle.DragView? {
    if let handle = view as? WindowDragHandle.DragView { return handle }
    return view.subviews.lazy.compactMap { findHandle(in: $0) }.first
  }

  @Test func toolbarDragsWithoutStealingControlClicks() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 76, height: 76))
    let handle = WindowDragHandle.DragView(frame: container.bounds)
    container.addSubview(handle)
    // Convert from the flipped handle to its parent's coordinate system.
    func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
      handle.hitTest(container.convert(NSPoint(x: x, y: y), from: handle))
    }
    #expect(hit(19, 18) == nil) // Minimize.
    #expect(hit(40, 18) == nil) // Fit.
    #expect(hit(65, 18) === handle) // Empty toolbar.
    #expect(hit(38, 56) === handle) // Logo.
    #expect(handle.acceptsFirstMouse(for: nil))
  }
}

@MainActor
private final class RecordingDragWindow: NSWindow {
  var onDrag: (() -> Void)?
  override func performDrag(with event: NSEvent) { onDrag?() }
}
