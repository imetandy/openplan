import AppKit

/// The window being dragged leads. App drags move the rail; native rail drags
/// send position-only updates to the app, with no reverse feedback during drag.
@MainActor
final class WindowPairController {
  weak var railWindow: NSWindow?
  private weak var nativeWindow: NSWindow?
  private var nativeMoveObserver: NSObjectProtocol?
  private var tracker: WindowGeometryTracker?
  private var snapshot: LiveWindowSnapshot?
  private var writer: LivePositionWriter?
  private var attachment = WindowAttachment(side: .left)
  enum DragLeader { case application, rail }
  private(set) var dragLeader = DragLeader.application
  private var railIsLeading: Bool { dragLeader == .rail }
  private var isEndingDrag = false
  private var dragEndTimer: Timer?
  private var lastRequestedPosition: CGPoint?
  private var settleDeadline: TimeInterval?
  private(set) var isAttached = false
  var onUnavailable: (() -> Void)?

  @discardableResult
  func attach(processIdentifier: pid_t, snapshot: LiveWindowSnapshot) -> Bool {
    detach()
    guard let railWindow, let tracker = WindowGeometryTracker(processIdentifier: processIdentifier, snapshot: snapshot)
    else { return false }
    self.snapshot = snapshot
    self.tracker = tracker
    let appFrame = appKitFrame(tracker.frame)
    attachment = WindowAttachment(side: railWindow.frame.midX < appFrame.midX ? .left : .right)
    isAttached = true
    tracker.onApplicationGrabbed = { [weak self] in self?.beginApplicationDrag() }
    tracker.onFrame = { [weak self] frame in self?.follow(frame) }
    tracker.onUnavailable = { [weak self] in
      self?.detach()
      self?.onUnavailable?()
    }
    follow(tracker.frame)
    tracker.start(window: snapshot.window)
    return isAttached
  }

  func attach(nativeWindow: NSWindow) {
    detach()
    guard let railWindow else { return }
    self.nativeWindow = nativeWindow
    attachment = WindowAttachment(side: railWindow.frame.midX < nativeWindow.frame.midX ? .left : .right)
    isAttached = true
    railWindow.setFrameOrigin(attachment.railOrigin(appFrame: nativeWindow.frame, railSize: railWindow.frame.size))
    // AppKit moves these two same-process windows together in the WindowServer.
    nativeWindow.addChildWindow(railWindow, ordered: .above)
    nativeMoveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: nativeWindow, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.railIsLeading, let rail = self.railWindow, let native = self.nativeWindow else { return }
        rail.setFrameOrigin(self.attachment.railOrigin(appFrame: native.frame, railSize: rail.frame.size))
      }
    }
  }

  func beginRailDrag() {
    guard isAttached, let railWindow else { return }
    writer?.cancel()
    dragEndTimer?.invalidate()
    settleDeadline = nil
    lastRequestedPosition = nil
    isEndingDrag = false
    dragLeader = .rail
    if let nativeWindow {
      // Reverse the native attachment while the rail is the grabbed window.
      nativeWindow.removeChildWindow(railWindow)
      railWindow.addChildWindow(nativeWindow, ordered: .below)
    } else if let snapshot, let appSize = tracker?.frame.size ?? snapshot.size {
      let writer = LivePositionWriter(snapshot: snapshot, railWindowID: CGWindowID(railWindow.windowNumber),
                                      attachment: attachment, appSize: appSize)
      writer.onInvalidWindow = { [weak self, weak writer] in
        guard let self, self.writer === writer else { return }
        self.detach()
        self.onUnavailable?()
      }
      self.writer = writer
      writer.start(framesPerSecond: max(120, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60))
    }
    let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self else { timer.invalidate(); return }
        if let deadline = self.settleDeadline {
          self.tracker?.sample()
          let reached = self.tracker?.frame.origin == self.lastRequestedPosition
          if reached || ProcessInfo.processInfo.systemUptime >= deadline {
            self.finishRailDrag()
          }
        } else if NSEvent.pressedMouseButtons & 1 == 0 {
          self.endRailDrag()
        }
      }
    }
    dragEndTimer = timer
    // performDrag returns immediately and may consume mouse-up; common-mode
    // tracking detects release without implementing a custom mouse drag loop.
    RunLoop.main.add(timer, forMode: .common)
  }

  /// A new mouse-down on the app wins even while the previous rail drag settles.
  /// Cancel queued writes before allowing app geometry to move the rail again.
  func beginApplicationDrag() {
    guard railIsLeading else { return }
    writer?.cancel()
    writer = nil
    finishRailDrag()
    tracker?.sample()
  }

  func endRailDrag() {
    guard railIsLeading, !isEndingDrag else { return }
    isEndingDrag = true
    guard let writer else { finishRailDrag(); return }
    writer.finish { [weak self, weak writer] position in
      guard let self, self.writer === writer else { return }
      self.lastRequestedPosition = position
      self.writer = nil
      // Keep the rail fixed until Slack commits the final position; stale
      // notifications must not pull the just-dragged toolbar backwards.
      self.settleDeadline = ProcessInfo.processInfo.systemUptime + 0.25
    }
  }

  private func finishRailDrag() {
    dragEndTimer?.invalidate()
    dragEndTimer = nil
    settleDeadline = nil
    dragLeader = .application
    isEndingDrag = false
    if let nativeWindow, let railWindow {
      railWindow.removeChildWindow(nativeWindow)
      nativeWindow.addChildWindow(railWindow, ordered: .above)
    } else if let tracker {
      follow(tracker.frame)
    }
    // Deliberately no tile/refit: preserve the side, size and gap.
  }

  func detach() {
    writer?.cancel()
    writer = nil
    dragEndTimer?.invalidate()
    dragEndTimer = nil
    dragLeader = .application
    isEndingDrag = false
    settleDeadline = nil
    lastRequestedPosition = nil
    tracker?.stop()
    tracker = nil
    snapshot = nil
    if let railWindow, let nativeWindow {
      if railWindow.parent === nativeWindow { nativeWindow.removeChildWindow(railWindow) }
      if nativeWindow.parent === railWindow { railWindow.removeChildWindow(nativeWindow) }
    }
    nativeWindow = nil
    if let nativeMoveObserver { NotificationCenter.default.removeObserver(nativeMoveObserver) }
    nativeMoveObserver = nil
    isAttached = false
  }

  private func follow(_ frame: CGRect) {
    guard !railIsLeading, let railWindow else { return }
    let origin = attachment.railOrigin(appFrame: appKitFrame(frame), railSize: railWindow.frame.size)
    if railWindow.frame.origin != origin { railWindow.setFrameOrigin(origin) }
  }

  private func appKitFrame(_ frame: CGRect) -> CGRect {
    WindowAttachment.appKitFrame(from: frame, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
  }

  deinit {
    dragEndTimer?.invalidate()
    if let nativeMoveObserver { NotificationCenter.default.removeObserver(nativeMoveObserver) }
  }
}
