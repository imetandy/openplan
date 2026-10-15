import AppKit
import ApplicationServices

/// Reads only the paired window's WindowServer geometry during a drag. AX move
/// notifications can be delayed by the other app's main thread, so they wake
/// this tracker but are not the source of live positions.
@MainActor
final class WindowGeometryTracker {
  let windowID: CGWindowID
  let processIdentifier: pid_t
  private(set) var frame: CGRect
  var onFrame: ((CGRect) -> Void)?
  var onApplicationGrabbed: (() -> Void)?
  var onUnavailable: (() -> Void)?
  private var observer: AXObserver?
  private var mouseMonitor: Any?
  private var timer: Timer?
  private var settleDeadline: TimeInterval = 0

  init?(processIdentifier: pid_t, snapshot: LiveWindowSnapshot) {
    guard let size = snapshot.size,
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let expected = CGRect(origin: snapshot.position, size: size)
    // Match AX geometry to the public WindowServer ID once, never on every frame.
    let candidates = windows.compactMap { info -> (CGWindowID, CGRect)? in
      guard info[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
        info[kCGWindowLayer as String] as? Int == 0,
        let id = info[kCGWindowNumber as String] as? CGWindowID,
        let bounds = Self.bounds(info),
        abs(bounds.minX - expected.minX) < 3, abs(bounds.minY - expected.minY) < 3,
        abs(bounds.width - expected.width) < 3, abs(bounds.height - expected.height) < 3
      else { return nil }
      return (id, bounds)
    }
    guard let match = candidates.first else { return nil }
    windowID = match.0
    frame = match.1
    self.processIdentifier = processIdentifier
  }

  func start(window: AXUIElement) {
    var observer: AXObserver?
    if AXObserverCreate(processIdentifier, { _, _, notification, context in
      guard let context else { return }
      MainActor.assumeIsolated {
        let tracker = Unmanaged<WindowGeometryTracker>.fromOpaque(context).takeUnretainedValue()
        if notification as String == kAXUIElementDestroyedNotification {
          tracker.onUnavailable?()
        } else {
          // Some apps send AXMoved before WindowServer commits the new bounds.
          // A short burst catches that commit even for keyboard/window-manager moves.
          tracker.startLiveUpdates()
          tracker.sample()
        }
      }
    }, &observer) == .success, let observer {
      self.observer = observer
      for notification in [kAXMovedNotification, kAXResizedNotification,
                           kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                           kAXWindowDeminiaturizedNotification] {
        AXObserverAddNotification(observer, window, notification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
      }
      CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
      guard let self,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == self.processIdentifier
      else { return }
      if event.type == .leftMouseDown || event.type == .leftMouseDragged,
        let point = event.cgEvent?.location, self.frame.contains(point) {
        self.onApplicationGrabbed?()
      }
      self.startLiveUpdates()
      self.sample()
    }
    sample()
    if NSEvent.pressedMouseButtons & 1 != 0 { startLiveUpdates() }
  }

  func startLiveUpdates() {
    settleDeadline = ProcessInfo.processInfo.systemUptime + 0.2
    guard timer == nil else { return }
    // Match the fastest attached screen, including ProMotion, while a mouse
    // drag is active. No repeating timer or window-list scans while idle.
    let fps = max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
    let timer = Timer(timeInterval: 1 / Double(fps), repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self else { timer.invalidate(); return }
        self.sample()
        let now = ProcessInfo.processInfo.systemUptime
        if NSEvent.pressedMouseButtons & 1 != 0 {
          self.settleDeadline = now + 0.2
        } else if now >= self.settleDeadline {
          timer.invalidate()
          self.timer = nil
        }
      }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func sample() {
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
      info[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
      let bounds = Self.bounds(info)
    else { onUnavailable?(); return }
    guard info[kCGWindowIsOnscreen as String] as? Bool != false else { onUnavailable?(); return }
    guard bounds != frame else { return }
    frame = bounds
    onFrame?(bounds)
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    mouseMonitor = nil
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    observer = nil
  }

  deinit {
    timer?.invalidate()
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
  }

  private static func bounds(_ info: [String: Any]) -> CGRect? {
    guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
  }
}
